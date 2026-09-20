// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for USB2_top (USB 2.0 High-Speed device)
// Host model drives dp/dm at bit level (NRZI + bit stuffing + EOP) and
// decodes device responses at bit level.
// Checks:
//   1. reset state (irq low, hs_mode low, device not driving the bus)
//   2. HS chirp handshake: host chirp K -> device answers 3 K/J chirp
//      pairs (level timing measured), hs_mode raised
//   3. microframe SOF: 8 SOF tokens -> frame_no register compare,
//      uframe counter increments each SOF; bad-CRC5 SOF -> irq
//   4. GET_DESCRIPTOR control read: SETUP->ACK + 8x8 regfile write-back
//      compare, IN->DATA1 descriptor payload+CRC16 compare, host ACK
//   5. EP1 interrupt IN x2 back-to-back: payload counter increments,
//      DATA0/DATA1 toggle alternates
//   6. DATA toggle misorder injection: SETUP with DATA1 -> ACK but
//      register file NOT written (duplicate discarded)
//   7. lost-ACK retransmission: IN without ACK -> same DATA payload/toggle
//      re-sent on next IN
//   8. bad CRC5 token injection: no device response + irq raised,
//      next good token clears irq
//   9. bad CRC16 data injection: no handshake + irq raised
//  10. IN to illegal endpoint -> STALL handshake
// ============================================================================
`timescale 1ns/1ps
module USB2_tb;
  localparam int BIT_CLKS = 4;
  localparam int CHIRP_LEN = 32;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // USB bus: weak pull-up on D+ (device pull-up), weak pull-down on D- (host)
  tri1 dp;
  tri0 dm;
  logic host_oe = 0, host_dp = 1, host_dm = 0;
  assign dp = host_oe ? host_dp : 1'bz;
  assign dm = host_oe ? host_dm : 1'bz;

  wire irq;
  wire hs_mode;
  wire [10:0] frame_no;
  wire [2:0]  uframe;
  int  errors = 0;

  USB2_top #(.DW(32), .AW(32), .BIT_CLKS(BIT_CLKS)) dut (
    .clk(clk), .rst_n(rst_n), .dp(dp), .dm(dm), .irq(irq),
    .hs_mode(hs_mode), .frame_no(frame_no), .uframe(uframe)
  );

  // ------------------------------------------------------------------
  // check helper
  // ------------------------------------------------------------------
  task automatic check(input bit cond, input string msg);
    begin
      if (cond) $display("[OK]   %s", msg);
      else begin
        errors++;
        $display("[FAIL] %s", msg);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // CRC models (mirror of DUT, verified against USB spec vectors)
  // ------------------------------------------------------------------
  function automatic logic [4:0] crc5_token(input logic [6:0] a, input logic [3:0] e);
    logic [4:0] c; logic fb; logic b;
    begin
      c = 5'h1F;
      for (int i = 0; i < 11; i++) begin
        b  = (i < 7) ? a[i] : e[i-7];
        fb = c[0] ^ b;
        c  = fb ? (c >> 1) ^ 5'h14 : (c >> 1);
      end
      crc5_token = ~c;
    end
  endfunction

  function automatic logic [15:0] crc16_upd(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] r;
    begin
      r = c;
      for (int k = 0; k < 8; k++)
        r = (r[0] ^ d[k]) ? (r >> 1) ^ 16'hA001 : (r >> 1);
      crc16_upd = r;
    end
  endfunction

  // ------------------------------------------------------------------
  // host bit-level transmit (NRZI + stuffing), driven on negedge
  // payload passed through global h_pl[] (iverilog: no array task ports)
  // ------------------------------------------------------------------
  logic       h_lvl;   // current NRZI level (1=J, 0=K)
  int         h_ones;
  logic [7:0] h_pl [0:7];

  task automatic h_bit(input logic b);
    begin
      if (!b) h_lvl = ~h_lvl;
      host_oe = 1; host_dp = h_lvl; host_dm = ~h_lvl;
      repeat (BIT_CLKS) @(negedge clk);
    end
  endtask

  task automatic h_raw_bit(input logic b);   // with bit-stuff accounting
    begin
      h_bit(b);
      if (b) begin
        h_ones = h_ones + 1;
        if (h_ones == 6) begin h_bit(1'b0); h_ones = 0; end
      end else h_ones = 0;
    end
  endtask

  task automatic h_byte(input logic [7:0] d);
    for (int i = 0; i < 8; i++) h_raw_bit(d[i]);
  endtask

  task automatic h_sop_sync;
    begin
      h_ones = 0; h_lvl = 1'b1;
      host_oe = 1; host_dp = 1; host_dm = 0;   // idle J
      @(negedge clk);
      h_byte(8'h80);                            // SYNC: KJKJKJKK
      h_ones = 0;                               // stuffing starts after SYNC
    end
  endtask

  task automatic h_eop;
    begin
      host_oe = 1; host_dp = 0; host_dm = 0;
      repeat (2*BIT_CLKS) @(negedge clk);       // SE0 x2 bit times
      host_dp = 1; host_dm = 0;
      repeat (BIT_CLKS) @(negedge clk);         // J x1 bit time
      host_oe = 0;                              // release bus
      @(negedge clk);
    end
  endtask

  task automatic h_token(input logic [3:0] pid, input logic [6:0] addr,
                         input logic [3:0] endp, input bit corrupt);
    logic [4:0]  c5;
    logic [15:0] tf;
    begin
      c5 = crc5_token(addr, endp) ^ (corrupt ? 5'h1F : 5'h00);
      tf = {c5, endp, addr};
      h_sop_sync;
      h_byte({~pid, pid});
      for (int i = 0; i < 16; i++) h_raw_bit(tf[i]);
      h_eop;
    end
  endtask

  task automatic h_data(input logic [3:0] pid, input int len, input bit corrupt);
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      h_sop_sync;
      h_byte({~pid, pid});
      for (int i = 0; i < len; i++) begin
        h_byte(h_pl[i]);
        c = crc16_upd(c, h_pl[i]);
      end
      c = ~c ^ (corrupt ? 16'hFFFF : 16'h0000);
      h_byte(c[7:0]);
      h_byte(c[15:8]);
      h_eop;
    end
  endtask

  task automatic h_handshake(input logic [3:0] pid);
    begin
      h_sop_sync;
      h_byte({~pid, pid});
      h_eop;
    end
  endtask

  // ------------------------------------------------------------------
  // host bit-level receive (samples at bit centers on negedge)
  //   fills rbuf/rlen; rto=1 if no SOP within timeout
  // ------------------------------------------------------------------
  logic [7:0] rbuf [0:15];
  int         rlen;
  bit         rto;

  task automatic h_recv(input int to_clks);
    int  to;
    logic prev, raw;
    int  ones;
    logic [7:0] sh;
    int  bc;
    int  guard;
    bit  done;
    bit  got_sync;
    begin : recv_blk
      rto = 0; rlen = 0;
      host_oe = 0;                               // release while device talks
      to = 0;
      while (!(dp === 1'b0 && dm === 1'b1)) begin   // wait SOP (J->K)
        @(negedge clk);
        to = to + 1;
        if (to > to_clks) begin rto = 1; disable recv_blk; end
      end
      repeat (BIT_CLKS/2) @(negedge clk);        // to center of first bit
      prev = 1'b1;                               // idle J before SOP
      ones = 0; bc = 0; sh = 8'h00; guard = 0; done = 0; got_sync = 0;
      while (!done) begin
        if (dp === 1'b0 && dm === 1'b0) done = 1;   // EOP (SE0)
        else begin
          raw = (dp === prev);
          prev = dp;
          if (ones == 6) begin                   // stuffed bit, drop
            ones = 0;
          end else begin
            sh = {raw, sh[7:1]};
            bc = bc + 1;
            if (raw) ones = ones + 1; else ones = 0;
            if (bc == 8) begin
              bc = 0;
              if (!got_sync) begin               // first byte is SYNC, drop it
                got_sync = 1;
                ones = 0;                        // stuffing starts after SYNC
              end else if (rlen < 16) begin
                rbuf[rlen] = sh; rlen = rlen + 1;
              end
            end
          end
          guard = guard + 1;
          if (guard > 400) done = 1;
          else repeat (BIT_CLKS) @(negedge clk);
        end
      end
      repeat (3*BIT_CLKS) @(negedge clk);        // let device finish EOP
    end
  endtask

  // ------------------------------------------------------------------
  // PID constants / expected descriptor
  // ------------------------------------------------------------------
  localparam logic [3:0] P_OUT=4'h1, P_IN=4'h9, P_SETUP=4'hD, P_SOF=4'h5,
                         P_DATA0=4'h3, P_DATA1=4'hB,
                         P_ACK=4'h2, P_NAK=4'hA, P_STALL=4'hE;
  localparam logic [7:0] B_ACK   = 8'hD2, B_STALL = 8'h1E,
                         B_DATA0 = 8'hC3, B_DATA1 = 8'h4B;

  function automatic logic [7:0] desc_byte(input int i);
    begin
      case (i)
        0:       desc_byte = 8'h12;
        1:       desc_byte = 8'h01;
        2:       desc_byte = 8'h00;
        3:       desc_byte = 8'h02;
        4:       desc_byte = 8'h00;
        5:       desc_byte = 8'h00;
        6:       desc_byte = 8'h00;
        default: desc_byte = 8'h08;
      endcase
    end
  endfunction

  // decode + verify a received data packet against expected payload exp_pl[]
  logic [7:0] exp_pl [0:7];

  task automatic expect_data_pkt(input logic [7:0] pid_byte,
                                 input int len, input string tag);
    logic [15:0] c;
    bit ok;
    begin
      h_recv(600);
      check(!rto, {tag, ": device responded (no timeout)"});
      if (!rto) begin
        check(rlen == len+3, {tag, ": byte count = payload+PID+CRC16"});
        check(rbuf[0] === pid_byte, {tag, ": PID byte as expected"});
        ok = 1'b1;
        for (int i = 0; i < len; i++)
          if (rbuf[i+1] !== exp_pl[i]) begin
            ok = 0;
            $display("       mismatch byte %0d: got %02x exp %02x", i, rbuf[i+1], exp_pl[i]);
          end
        check(ok, {tag, ": payload compare"});
        c = 16'hFFFF;
        for (int i = 0; i < len; i++) c = crc16_upd(c, rbuf[i+1]);
        c = ~c;
        check(rbuf[len+1] === c[7:0] && rbuf[len+2] === c[15:8],
              {tag, ": CRC16 valid"});
      end
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int USB2_FSM_TOTAL = 19;  // ch(4) + rs(7) + ts(5) + cs(3)
  logic [18:0] fsm_seen = '0;          // visited-state bitmap
  wire  [1:0]  dut_ch = dut.ch;        // hierarchical FSM probes
  wire  [2:0]  dut_rs = dut.rs;
  wire  [2:0]  dut_ts = dut.ts;
  wire  [1:0]  dut_cs = dut.cs;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: sample all four DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_ch]       <= 1'b1;
    fsm_seen[4 + dut_rs]   <= 1'b1;
    fsm_seen[11 + dut_ts]  <= 1'b1;
    fsm_seen[16 + dut_cs]  <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(irq === 1'b0 && dut.tx_oe === 1'b0 && dut.ch_oe === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: state registers hold legal enum encodings
      sva_check(dut_rs <= 3'd6 && dut_ts <= 3'd4 && dut_cs <= 2'd2,
                "A2 state encodings legal");
      // A3: no illegal SE1 on the bus
      sva_check({dp, dm} !== 2'b11, "A3 no SE1 on bus");
      // A4: irq never X
      sva_check(irq !== 1'bx, "A4 irq not X");
      // A5: bus rests at idle J whenever neither side drives
      sva_check(host_oe || dut.tx_oe || dut.ch_oe || ({dp, dm} === 2'b10),
                "A5 idle J when undriven");
      // A6: host and device never drive simultaneously
      sva_check(!(host_oe && (dut.tx_oe || dut.ch_oe)),
                "A6 no drive contention");
      // A7: device drives only while its TX/chirp FSM is active
      sva_check((!dut.tx_oe || (dut_ts != 3'd0)) &&
                (!dut.ch_oe || (dut_ch == 2'd2)),
                "A7 drive implies FSM active");
    end
  end

  // ---- constrained-random transaction tasks ---------------------------
  int          ep1_cnt_model;           // EP1 payload counter model
  bit          ep1_tgl_model;           // EP1 next DATA toggle model
  logic [7:0]  setup_model [0:7];       // shadow of DUT setup_q
  int          uframe_model;            // microframe counter model
  logic [10:0] frame_model;             // frame number model

  // EP1 interrupt IN, model-checked; optionally ACK (advance) or drop ACK
  task automatic crv_ep1_in(input bit do_ack);
    begin
      set_exp_count(ep1_cnt_model[7:0]);
      h_token(P_IN, 7'd0, 4'd1, 1'b0);
      expect_data_pkt(ep1_tgl_model ? B_DATA1 : B_DATA0, 4, "CRV EP1 IN");
      if (do_ack) begin
        h_handshake(P_ACK);
        repeat (2) @(negedge clk);
        ep1_cnt_model = ep1_cnt_model + 1;
        ep1_tgl_model = ~ep1_tgl_model;
      end else begin
        repeat (100) @(negedge clk);    // lost ACK: let the DUT time out
      end
    end
  endtask

  // SETUP with random request bytes + EP0 IN descriptor + ACK
  task automatic crv_setup_in;
    begin
      for (int i = 0; i < 8; i++) h_pl[i] = $urandom_range(0, 255);
      h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
      h_data(P_DATA0, 8, 1'b0);
      h_recv(600);
      check(!rto && rlen == 1 && rbuf[0] === B_ACK, "CRV SETUP data ACKed");
      for (int i = 0; i < 8; i++) begin
        if (dut.setup_q[i] !== h_pl[i]) begin
          errors++;
          $display("ERROR: CRV setup_q[%0d] got=%h exp=%h", i, dut.setup_q[i], h_pl[i]);
        end
        setup_model[i] = h_pl[i];
      end
      check(dut.ep0in_tgl === 1'b1, "CRV SETUP resets EP0 IN toggle");
      h_token(P_IN, 7'd0, 4'd0, 1'b0);
      for (int i = 0; i < 8; i++) exp_pl[i] = desc_byte(i);
      expect_data_pkt(B_DATA1, 8, "CRV EP0 IN descriptor");
      h_handshake(P_ACK);
      repeat (4) @(negedge clk);
      check(dut.ep0in_tgl === 1'b0, "CRV EP0 IN toggle flips after ACK");
    end
  endtask

  // IN to an illegal endpoint -> STALL
  task automatic crv_stall;
    logic [3:0] ep;
    begin
      ep = $urandom_range(2, 15);
      h_token(P_IN, 7'd0, ep, 1'b0);
      h_recv(600);
      check(!rto && rlen == 1 && rbuf[0] === B_STALL,
            "CRV IN illegal endpoint -> STALL");
    end
  endtask

  // bad CRC5 token: no response + irq; a valid token clears irq
  task automatic crv_badcrc5;
    logic [3:0] pid, ep; logic [6:0] ad;
    begin
      pid = ($urandom_range(0, 2) == 0) ? P_OUT :
            ($urandom_range(0, 1) == 0) ? P_IN : P_SETUP;
      ad  = $urandom_range(0, 127);
      ep  = $urandom_range(0, 15);
      h_token(pid, ad, ep, 1'b1);
      h_recv(300);
      check(rto, "CRV bad CRC5 token: no device response");
      check(irq === 1'b1, "CRV bad CRC5 token: irq raised");
      crv_ep1_in(1'b1);
      check(irq === 1'b0, "CRV irq cleared by next valid token");
    end
  endtask

  // bad CRC16 SETUP data: no handshake + irq, setup_q untouched
  task automatic crv_badcrc16;
    begin
      for (int i = 0; i < 8; i++) h_pl[i] = $urandom_range(0, 255);
      h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
      h_data(P_DATA0, 8, 1'b1);
      h_recv(300);
      check(rto, "CRV bad CRC16 data: no handshake");
      check(irq === 1'b1, "CRV bad CRC16 data: irq raised");
      for (int i = 0; i < 8; i++)
        if (dut.setup_q[i] !== setup_model[i]) begin
          errors++;
          $display("ERROR: CRV setup_q[%0d] clobbered by bad-CRC data", i);
        end
      crv_ep1_in(1'b1);
      check(irq === 1'b0, "CRV irq cleared after bad CRC16");
    end
  endtask

  // token to a foreign address (device addr is 0): ignored
  task automatic crv_wrong_addr;
    logic [6:0] ad;
    begin
      ad = $urandom_range(1, 127);
      h_token(P_IN, ad, 4'd1, 1'b0);
      h_recv(300);
      check(rto, "CRV wrong-address token ignored");
    end
  endtask

  // SETUP with wrong data toggle: ACKed but register file not written
  task automatic crv_misorder;
    begin
      for (int i = 0; i < 8; i++) h_pl[i] = $urandom_range(0, 255);
      h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
      h_data(P_DATA1, 8, 1'b0);
      h_recv(600);
      check(!rto && rlen == 1 && rbuf[0] === B_ACK,
            "CRV misordered SETUP data ACKed");
      for (int i = 0; i < 8; i++)
        if (dut.setup_q[i] !== setup_model[i]) begin
          errors++;
          $display("ERROR: CRV setup_q[%0d] overwritten by misordered data", i);
        end
    end
  endtask

  // microframe SOF: random 11-bit frame number; 25% bad CRC5 -> irq,
  // uframe/frame_no frozen; RTL does not clear irq on a good SOF, so an
  // EP1 IN is used to clear it (mirrors CS_IDLE PID_SOF/PID_IN arms)
  task automatic crv_sof;
    logic [10:0] fn;
    bit          bad;
    begin
      fn  = $urandom_range(0, 2047);
      bad = ($urandom_range(0, 3) == 0);
      h_token(P_SOF, fn[6:0], fn[10:7], bad);
      repeat (10) @(negedge clk);
      if (bad) begin
        check(irq === 1'b1, "CRV bad-CRC5 SOF: irq raised");
        check(uframe === uframe_model[2:0], "CRV bad SOF: uframe frozen");
        check(frame_no === frame_model, "CRV bad SOF: frame_no frozen");
        h_token(P_SOF, fn[6:0], fn[10:7], 1'b0);
        repeat (10) @(negedge clk);
        check(frame_no === fn, "CRV good SOF after bad: frame_no updated");
        uframe_model = (uframe_model + 1) % 8;
        frame_model  = fn;
        check(uframe === uframe_model[2:0], "CRV good SOF: uframe advances");
        crv_ep1_in(1'b1);
        check(irq === 1'b0, "CRV irq cleared by valid IN token");
      end else begin
        check(frame_no === fn, "CRV SOF: frame number register updated");
        uframe_model = (uframe_model + 1) % 8;
        frame_model  = fn;
        check(uframe === uframe_model[2:0], "CRV SOF: uframe increments");
      end
    end
  endtask

  // chirp re-handshake: reset the DUT, optionally try a too-short host
  // chirp K (< CHIRP_DET: must be ignored), then a full chirp with random
  // K duration; re-measure the 3 K/J answer pairs; all models re-seeded
  task automatic crv_chirp;
    int klen, to, len, n;
    bit ok, done, short_first;
    logic [1:0] lv;
    begin : crv_chirp_blk
      rst_n = 0;
      repeat ($urandom_range(4, 8)) @(negedge clk);
      rst_n = 1;
      repeat (4) @(negedge clk);
      short_first = ($urandom_range(0, 1) == 1);
      if (short_first) begin
        // sub-threshold chirp K: device must stay in CH_WAITK, no answer
        host_oe = 1; host_dp = 0; host_dm = 1;
        repeat ($urandom_range(8, 40)) @(negedge clk);
        host_oe = 0;
        repeat (80) @(negedge clk);
        check(hs_mode === 1'b0, "CRV short chirp K ignored (hs_mode low)");
        check(dut.ch_oe === 1'b0, "CRV short chirp K: device never drove");
      end
      // full host chirp K, random sustained length >= CHIRP_DET
      klen = $urandom_range(50, 140);
      host_oe = 1; host_dp = 0; host_dm = 1;
      repeat (klen) @(negedge clk);
      host_oe = 0;
      to = 0;
      while (!(dp === 1'b0 && dm === 1'b1)) begin
        @(negedge clk);
        to = to + 1;
        if (to > 400) begin
          errors++;
          $display("[FAIL] CRV chirp: device did not answer host chirp K");
          disable crv_chirp_blk;
        end
      end
      n = 0; ok = 1; lv = 2'b01;
      while (n < 6) begin
        if ({dp, dm} !== lv) ok = 0;
        len = 0; done = 0;
        while (!done) begin
          if ({dp, dm} === lv) begin
            @(negedge clk);
            len = len + 1;
            if (len > 4*CHIRP_LEN) done = 1;
          end else done = 1;
        end
        if (n == 5) begin
          if (len < CHIRP_LEN-2) begin
            ok = 0;
            $display("       CRV chirp %0d length %0d too short", n, len);
          end
        end else if (len < CHIRP_LEN-2 || len > CHIRP_LEN+2) begin
          ok = 0;
          $display("       CRV chirp %0d length %0d out of range", n, len);
        end
        n = n + 1;
        lv = (lv == 2'b01) ? 2'b10 : 2'b01;
      end
      check(ok, "CRV chirp: 3 K/J pairs with correct timing re-measured");
      repeat (4) @(negedge clk);
      check(hs_mode === 1'b1, "CRV chirp: hs_mode re-acquired");
      // re-seed all models to the post-reset DUT state
      ep1_cnt_model = 0;
      ep1_tgl_model = 1'b0;
      uframe_model  = 0;
      frame_model   = 11'd0;
      for (int i = 0; i < 8; i++) setup_model[i] = 8'h00;
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // HS chirp: host drives chirp K, device must answer 3 K/J chirp pairs
  // ------------------------------------------------------------------
  task automatic chirp_observe;
    int to;
    int len;
    int n;
    bit ok;
    bit done;
    logic [1:0] lv;
    begin : chirp_blk
      // host chirp K (long)
      host_oe = 1; host_dp = 0; host_dm = 1;
      repeat (100) @(negedge clk);
      host_oe = 0;                              // release -> idle J via pull-up
      // wait for first device chirp K
      to = 0;
      while (!(dp === 1'b0 && dm === 1'b1)) begin
        @(negedge clk);
        to = to + 1;
        if (to > 400) begin
          errors++;
          $display("[FAIL] chirp: device did not answer host chirp K");
          disable chirp_blk;
        end
      end
      // measure 6 alternating chirp levels
      n = 0; ok = 1; lv = 2'b01;               // first chirp must be K
      while (n < 6) begin
        if ({dp, dm} !== lv) ok = 0;           // wrong level/order
        len = 0; done = 0;
        while (!done) begin
          if ({dp, dm} === lv) begin
            @(negedge clk);
            len = len + 1;
            if (len > 4*CHIRP_LEN) done = 1;   // stuck guard
          end else done = 1;
        end
        if (n == 5) begin
          // final chirp J merges with following idle J: lower bound only
          if (len < CHIRP_LEN-2) begin
            ok = 0;
            $display("       chirp %0d length %0d too short", n, len);
          end
        end else if (len < CHIRP_LEN-2 || len > CHIRP_LEN+2) begin
          ok = 0;
          $display("       chirp %0d length %0d out of range", n, len);
        end
        n = n + 1;
        lv = (lv == 2'b01) ? 2'b10 : 2'b01;    // alternate K/J
      end
      check(ok, "chirp: device answered 3 K/J chirp pairs with correct timing");
      repeat (4) @(negedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  logic [7:0] saved_rf [0:7];
  bit         same;

  task automatic set_exp_count(input logic [7:0] v);
    begin
      for (int i = 0; i < 8; i++) exp_pl[i] = 8'h00;
      exp_pl[0] = v;
    end
  endtask

  initial begin
    // ---------------- 1. reset ----------------
    rst_n = 0;
    repeat (8) @(negedge clk);
    check(irq === 1'b0, "reset: irq low");
    check(hs_mode === 1'b0, "reset: hs_mode low");
    check(dp === 1'b1 && dm === 1'b0, "reset: device not driving bus (idle J via pull-up)");
    rst_n = 1;
    repeat (4) @(negedge clk);

    // ---------------- 2. HS chirp handshake ----------------
    $display("-- HS chirp handshake --");
    chirp_observe;
    check(hs_mode === 1'b1, "chirp: hs_mode raised after 3 chirp pairs");

    // ---------------- 3. microframe SOF ----------------
    $display("-- microframe SOF tracking --");
    check(uframe === 3'd0, "SOF: uframe starts at 0");
    for (int i = 0; i < 8; i++) begin
      h_token(P_SOF, 7'h55, 4'h2, 1'b0);       // frame number 11'h155
      repeat (10) @(negedge clk);
      check(frame_no === 11'h155, "SOF: frame number register updated");
      check(uframe === (i+1)%8, "SOF: microframe counter increments");
    end
    h_token(P_SOF, 7'h00, 4'h0, 1'b1);              // bad CRC5 SOF
    repeat (10) @(negedge clk);
    check(irq === 1'b1, "SOF: bad CRC5 raises irq");
    check(uframe === 3'd0, "SOF: bad SOF does not advance uframe");
    h_token(P_SOF, 7'h00, 4'h0, 1'b0);              // good SOF
    repeat (10) @(negedge clk);
    check(frame_no === 11'h000, "SOF: frame number follows new SOF");
    check(uframe === 3'd1, "SOF: good SOF advances uframe");

    // ---------------- 2. GET_DESCRIPTOR ----------------
    $display("-- GET_DESCRIPTOR control read on EP0 --");
    h_pl[0]=8'h80; h_pl[1]=8'h06; h_pl[2]=8'h00; h_pl[3]=8'h01;
    h_pl[4]=8'h00; h_pl[5]=8'h00; h_pl[6]=8'h08; h_pl[7]=8'h00;
    h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
    h_data(P_DATA0, 8, 1'b0);
    h_recv(600);
    check(!rto && rlen == 1 && rbuf[0] === B_ACK, "SETUP data stage ACKed");
    same = 1'b1;
    for (int i = 0; i < 8; i++) begin
      if (dut.setup_q[i] !== h_pl[i]) same = 0;
      saved_rf[i] = dut.setup_q[i];
    end
    check(same, "SETUP 8x8 register file written with request bytes");
    check(dut.ep0in_tgl === 1'b1, "SETUP resets EP0 IN toggle to DATA1");

    h_token(P_IN, 7'd0, 4'd0, 1'b0);
    for (int i = 0; i < 8; i++) exp_pl[i] = desc_byte(i);
    expect_data_pkt(B_DATA1, 8, "GET_DESCRIPTOR IN");
    h_handshake(P_ACK);
    repeat (4) @(negedge clk);
    check(dut.ep0in_tgl === 1'b0, "EP0 IN toggle flips after ACK");

    // ---------------- 3. EP1 interrupt IN x2 (back-to-back) ----------------
    $display("-- EP1 interrupt IN x2 --");
    set_exp_count(8'h00);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA0, 4, "EP1 IN #1 (count=0)");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);
    set_exp_count(8'h01);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA1, 4, "EP1 IN #2 (count=1)");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);

    // ---------------- 4. toggle misorder injection ----------------
    $display("-- SETUP with wrong toggle (DATA1) injected --");
    h_pl[0]=8'hAA; h_pl[1]=8'hBB; h_pl[2]=8'hCC; h_pl[3]=8'hDD;
    h_pl[4]=8'h11; h_pl[5]=8'h22; h_pl[6]=8'h33; h_pl[7]=8'h44;
    h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
    h_data(P_DATA1, 8, 1'b0);                   // wrong: SETUP expects DATA0
    h_recv(600);
    check(!rto && rlen == 1 && rbuf[0] === B_ACK,
          "misordered SETUP data still ACKed (duplicate discarded)");
    same = 1'b1;
    for (int i = 0; i < 8; i++)
      if (dut.setup_q[i] !== saved_rf[i]) same = 0;
    check(same, "register file NOT overwritten by misordered data");

    // ---------------- 5. lost-ACK retransmission ----------------
    $display("-- IN without ACK -> device retransmits --");
    set_exp_count(8'h02);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA0, 4, "EP1 IN #3 (count=2)");
    repeat (100) @(negedge clk);                // no ACK: let DUT time out
    h_token(P_IN, 7'd0, 4'd1, 1'b0);            // retry
    expect_data_pkt(B_DATA0, 4, "EP1 IN retry: same toggle+payload re-sent");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);
    set_exp_count(8'h03);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA1, 4, "EP1 IN #4 advances after ACK (count=3)");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);

    // ---------------- 6. bad CRC5 token ----------------
    $display("-- bad CRC5 token injected --");
    h_token(P_IN, 7'd0, 4'd0, 1'b1);
    h_recv(300);
    check(rto, "bad CRC5 token: no device response");
    check(irq === 1'b1, "bad CRC5 token: irq raised");
    set_exp_count(8'h04);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);            // good token clears irq
    expect_data_pkt(B_DATA0, 4, "recovery IN after bad CRC5 (count=4)");
    h_handshake(P_ACK);
    check(irq === 1'b0, "irq cleared by next valid token");

    // ---------------- 7. bad CRC16 data ----------------
    $display("-- bad CRC16 data injected --");
    h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
    h_data(P_DATA0, 8, 1'b1);
    h_recv(300);
    check(rto, "bad CRC16 data: no handshake from device");
    check(irq === 1'b1, "bad CRC16 data: irq raised");

    // ---------------- 8. illegal endpoint STALL ----------------
    $display("-- IN to illegal endpoint --");
    h_token(P_IN, 7'd0, 4'd2, 1'b0);
    h_recv(600);
    check(!rto && rlen == 1 && rbuf[0] === B_STALL, "IN ep2 -> STALL handshake");
    check(irq === 1'b0, "irq cleared by valid token");

`ifdef VERILATOR
    // ---------------- v2.5 CRV random phase (directed above untouched) --
    begin : crv_phase
      int n_in = 0, n_lost = 0, n_su = 0, n_st = 0, n_c5 = 0, n_c16 = 0,
          n_wa = 0, n_mo = 0, n_sof = 0, n_ch = 0;
      int roll;
      // models start from the directed-test end state
      ep1_cnt_model = 5;
      ep1_tgl_model = 1'b1;
      uframe_model  = 1;
      frame_model   = 11'h000;
      for (int i = 0; i < 8; i++) setup_model[i] = saved_rf[i];
      for (int t = 0; t < 100; t++) begin
        roll = $urandom_range(0, 99);
        if (roll < 25) begin
          n_in++;   crv_ep1_in(1'b1);
        end else if (roll < 35) begin
          n_lost++; crv_ep1_in(1'b0); crv_ep1_in(1'b1);  // lost ACK + retry
        end else if (roll < 53) begin
          n_su++;   crv_setup_in;
        end else if (roll < 61) begin
          n_st++;   crv_stall;
        end else if (roll < 69) begin
          n_c5++;   crv_badcrc5;
        end else if (roll < 77) begin
          n_c16++;  crv_badcrc16;
        end else if (roll < 82) begin
          n_wa++;   crv_wrong_addr;
        end else if (roll < 87) begin
          n_mo++;   crv_misorder;
        end else if (roll < 96) begin
          n_sof++;  crv_sof;
        end else begin
          n_ch++;   crv_chirp;
        end
      end
      $display("CRV: 100 txns (ep1_in=%0d lost_ack=%0d setup_in=%0d stall=%0d bad_crc5=%0d bad_crc16=%0d wrong_addr=%0d misorder=%0d sof=%0d chirp=%0d)",
               n_in, n_lost, n_su, n_st, n_c5, n_c16, n_wa, n_mo, n_sof, n_ch);
    end
`endif
    // ---------------- summary ----------------
    repeat (20) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: USB2");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < USB2_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, USB2_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // CRV phase adds ~1.5 ms of bus traffic: extend the guard. The timeout
  // is chunked into 1-us delays: with Verilator 5.006 a single long-pending
  // #delay event corrupts the --timing delay heap (docs/COVERAGE.md note 1).
  initial begin
    repeat (12000) #1000;   // 12 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #5000000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
