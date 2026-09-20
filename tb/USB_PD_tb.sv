// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for USB_PD_top -- SystemVerilog
// TB plays the USB-PD source (DFP): drives BMC-encoded frames onto the CC
// wire, decodes the sink's GoodCRC/Request replies, checks the full
// Source_Capabilities -> Request(9V) -> Accept -> PS_RDY negotiation,
// bad-CRC injection (no GoodCRC + irq) and HardReset recovery.
// IP design implementation v1.0 -- Apache-2.0
`timescale 1ns/1ps
module USB_PD_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic cc_rxd;                 // CC wire level into the DUT
  logic cc_txd, cc_tx_en;       // DUT BMC drive
  logic vbus_ok, irq;
  logic src_drv = 1'b0;         // source-side line driver
  logic line    = 1'b0;         // BMC encoder state (TB side)

  int errors = 0;

  // CC wire: sink owns it while transmitting, source otherwise
  assign cc_rxd = cc_tx_en ? cc_txd : src_drv;

  USB_PD_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .cc_rxd(cc_rxd), .cc_txd(cc_txd), .cc_tx_en(cc_tx_en),
    .vbus_ok(vbus_ok), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // constants (mirror of DUT)
  // ------------------------------------------------------------------
  localparam logic [4:0] K_SYNC1 = 5'b11000;
  localparam logic [4:0] K_SYNC2 = 5'b10001;
  localparam logic [4:0] K_RST1  = 5'b00111;
  localparam logic [4:0] K_RST2  = 5'b11001;
  localparam logic [4:0] K_EOP   = 5'b01101;

  localparam logic [4:0] MT_GOODCRC = 5'h01;
  localparam logic [4:0] MT_ACCEPT  = 5'h03;
  localparam logic [4:0] MT_PSRDY   = 5'h06;
  localparam logic [4:0] MT_SRCCAP  = 5'h01;
  localparam logic [4:0] MT_REQUEST = 5'h02;

  // fixed-supply PDOs: [19:10]=V/50mV, [9:0]=I/10mA
  localparam logic [31:0] PDO_5V = 32'h0001_9096; // 5V/1.5A
  localparam logic [31:0] PDO_9V = 32'h0002_D0C8; // 9V/2A

  function automatic logic [31:0] crc32_bit(input logic [31:0] c,
                                            input logic        b);
    logic fb;
    begin
      fb        = c[0] ^ b;
      crc32_bit = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0);
    end
  endfunction

  // source header: powerrole=1 (source), datarole=1 (DFP), specrev=2'b10
  function automatic logic [15:0] mk_hdr(input logic [4:0] mtype,
                                         input logic [2:0] msgid,
                                         input logic [2:0] nobj);
    mk_hdr = {1'b0, nobj, msgid, 1'b1, 2'b10, 1'b1, mtype};
  endfunction

  // ------------------------------------------------------------------
  // BMC source tasks (drive on negedge so DUT samples a stable level)
  // ------------------------------------------------------------------
  task automatic bmc_bit(input logic b);
    begin
      if (b) line = ~line;
      src_drv = line;
      @(negedge clk);
    end
  endtask

  task automatic send_sym(input logic [4:0] s);
    for (int i = 4; i >= 0; i--) bmc_bit(s[i]);
  endtask

  task automatic send_hrst;
    begin
      send_sym(K_RST1); send_sym(K_RST1); send_sym(K_RST1); send_sym(K_RST2);
      repeat (4) @(negedge clk);
    end
  endtask

  // full message: preamble + SOP + header + objects + CRC32 (+opt corrupt)
  task automatic send_msg(input logic [15:0] hdr,
                          input logic [31:0] o0, o1,
                          input logic        corrupt);
    logic [31:0] crc, cf;
    int nobj;
    begin
      crc  = 32'hFFFF_FFFF;
      nobj = hdr[14:12];
      for (int i = 0; i < 16; i++) bmc_bit(i[0]);        // preamble 0101..
      send_sym(K_SYNC1); send_sym(K_SYNC1);
      send_sym(K_SYNC1); send_sym(K_SYNC2);              // SOP
      for (int i = 0; i < 16; i++) begin
        bmc_bit(hdr[i]); crc = crc32_bit(crc, hdr[i]);
      end
      if (nobj >= 1) for (int i = 0; i < 32; i++) begin
        bmc_bit(o0[i]); crc = crc32_bit(crc, o0[i]);
      end
      if (nobj >= 2) for (int i = 0; i < 32; i++) begin
        bmc_bit(o1[i]); crc = crc32_bit(crc, o1[i]);
      end
      cf = crc ^ 32'hFFFF_FFFF;
      if (corrupt) cf = cf ^ 32'h0000_0001;              // error injection
      for (int i = 0; i < 32; i++) bmc_bit(cf[i]);
      send_sym(K_EOP);
      repeat (2) @(negedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // sink-message decoder (BMC + K-code comma lock, mirrors DUT RX)
  // ------------------------------------------------------------------
  task automatic recv_msg(output logic [15:0] hdr,
                          output logic [31:0] o0, o1,
                          output logic        got,
                          output logic        crc_ok,
                          input  int          max_wait);
    logic prev, cur, b;
    logic [4:0] win;
    logic [15:0] hsr, hf;
    logic [31:0] osr, crc;
    int skip, w, bitcnt, nobj, oc, st, sopc;
    int done;
    begin
      got = 0; crc_ok = 0; hdr = '0; o0 = '0; o1 = '0;
      w = 0;
      while (cc_tx_en === 1'b1 && w < 4) begin    // previous frame tail
        @(negedge clk); w = w + 1;
      end
      w = 0;
      while (cc_tx_en !== 1'b1 && w < max_wait) begin
        @(negedge clk); w = w + 1;
      end
      if (cc_tx_en === 1'b1) begin
        if (w > 20) begin
          errors++;
          $display("ERROR: reply latency %0d clk > 20 (GoodCRC timing)", w);
        end
        prev = src_drv; st = 0; win = '0; skip = 0; sopc = 0;
        bitcnt = 0; crc = 32'hFFFF_FFFF; nobj = 0; oc = 0; hsr = '0; osr = '0;
        done = 0;
        while (!done) begin
          @(negedge clk);
          if (cc_tx_en !== 1'b1) done = 1;    // aborted frame
          else begin
            cur = cc_txd; b = cur ^ prev; prev = cur;
            case (st)
          0: begin                          // hunt SOP
            win = {win[3:0], b};
            if (skip > 0) skip = skip - 1;
            else if (win == K_SYNC1) begin
              sopc = sopc + 1; skip = 4;
            end else if (win == K_SYNC2 && sopc > 0) begin
              st = 1; bitcnt = 0; hsr = '0; crc = 32'hFFFF_FFFF;
            end else sopc = 0;
          end
          1: begin                          // header
            hf = {b, hsr[15:1]}; hsr = hf; crc = crc32_bit(crc, b);
            if (bitcnt == 15) begin
              hdr = hf; nobj = hf[14:12]; bitcnt = 0;
              st = (nobj > 0) ? 2 : 3;
            end else bitcnt = bitcnt + 1;
          end
          2: begin                          // data objects
            osr = {b, osr[31:1]}; crc = crc32_bit(crc, b);
            if (bitcnt == 31) begin
              if (oc == 0) o0 = osr;
              else         o1 = osr;
              bitcnt = 0;
              if (oc == nobj-1) st = 3; else oc = oc + 1;
            end else bitcnt = bitcnt + 1;
          end
          3: begin                          // CRC
            crc = crc32_bit(crc, b);
            if (bitcnt == 31) begin bitcnt = 0; st = 4; win = '0; end
            else bitcnt = bitcnt + 1;
          end
          4: begin                          // EOP
            win = {win[3:0], b};
            if (bitcnt == 4) begin
              if (win == K_EOP) begin
                got    = 1;
                crc_ok = (crc == 32'hDEBB_20E3);
              end
              done = 1;
            end else bitcnt = bitcnt + 1;
          end
            endcase
          end
        end
      end
    end
  endtask

  // expect a GoodCRC echoing exp_id
  task automatic expect_goodcrc(input logic [2:0] exp_id);
    logic [15:0] h; logic [31:0] a, b2; logic g, cok;
    begin
      recv_msg(h, a, b2, g, cok, 200);
      if (!g) begin
        errors++; $display("ERROR: no GoodCRC reply (exp id %0d)", exp_id);
      end else begin
        if (!cok) begin
          errors++; $display("ERROR: GoodCRC bad CRC32 residue");
        end
        if (h[14:12] !== 3'd0 || h[4:0] !== MT_GOODCRC) begin
          errors++;
          $display("ERROR: exp GoodCRC ctrl msg, got hdr=%h", h);
        end
        if (h[11:9] !== exp_id) begin
          errors++;
          $display("ERROR: GoodCRC msgid=%0d exp %0d", h[11:9], exp_id);
        end
      end
    end
  endtask

  // expect the sink Request message selecting the 9V PDO
  task automatic expect_request_9v;
    logic [15:0] h; logic [31:0] a, b2; logic g, cok;
    begin
      recv_msg(h, a, b2, g, cok, 300);
      if (!g) begin
        errors++; $display("ERROR: no Request message from sink");
      end else begin
        if (!cok) begin
          errors++; $display("ERROR: Request bad CRC32 residue");
        end
        if (h[4:0] !== MT_REQUEST || h[14:12] !== 3'd1) begin
          errors++;
          $display("ERROR: exp Request/1obj, got hdr=%h", h);
        end
        if (a[31:28] !== 4'd2) begin
          errors++;
          $display("ERROR: RDO objpos=%0d exp 2 (9V PDO)", a[31:28]);
        end
        if (a[19:10] !== 10'd200 || a[9:0] !== 10'd200) begin
          errors++;
          $display("ERROR: RDO current op=%0d max=%0d exp 200/200",
                   a[19:10], a[9:0]);
        end
      end
    end
  endtask

  // full negotiation run with given source message-id base
  task automatic negotiate(input logic [2:0] id0);
    begin
      send_msg(mk_hdr(MT_SRCCAP, id0, 3'd2), PDO_5V, PDO_9V, 1'b0);
      expect_goodcrc(id0);
      expect_request_9v();
      send_msg(mk_hdr(MT_GOODCRC, 3'd0, 3'd0), 0, 0, 1'b0); // ack Request
      send_msg(mk_hdr(MT_ACCEPT, id0 + 3'd1, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd1);
      send_msg(mk_hdr(MT_PSRDY, id0 + 3'd2, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd2);
      repeat (4) @(negedge clk);
      if (vbus_ok !== 1'b1) begin
        errors++; $display("ERROR: vbus_ok not set after PS_RDY");
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
  localparam int PD_FSM_TOTAL = 18;    // rx_st(5) + tx_st(8) + pe_st(5)
  logic [17:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_rx_st = dut.rx_st;   // hierarchical FSM probes
  wire  [3:0] dut_tx_st = dut.tx_st;
  wire  [2:0] dut_pe_st = dut.pe_st;

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

  // FSM coverage: sample all three DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_rx_st]       <= 1'b1;
    fsm_seen[5 + dut_tx_st]   <= 1'b1;
    fsm_seen[13 + dut_pe_st]  <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic txb_q = 0, rxd_q = 0, hrst_q = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(vbus_ok === 1'b0 && cc_tx_en === 1'b0 && irq === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: state registers hold legal enum encodings
      sva_check(dut_rx_st <= 3'd4 && dut_tx_st <= 4'd7 && dut_pe_st <= 3'd4,
                "A2 state encodings legal");
      // A3: cc_tx_en window: drive only while TX engine is active; engine
      // is idle or in the inter-frame gap whenever the wire is released
      sva_check((cc_tx_en === 1'b1) ? (dut_tx_st != 4'd0)
                                    : ((dut_tx_st == 4'd0) || (dut_tx_st == 4'd7)),
                "A3 cc_tx_en window");
      // A4: receiver is forced to RX_SYNC while the TX engine owns the wire
      sva_check(!txb_q || (dut_rx_st == 3'd0), "A4 rx hunted to SYNC during tx");
      // A5: vbus_ok only in PE_CONTRACT
      sva_check(!vbus_ok || (dut_pe_st == 3'd4), "A5 vbus_ok implies PE_CONTRACT");
      // A6: rx_done / hrst_det are single-cycle pulses
      sva_check(!(dut.rx_done && rxd_q) && !(dut.hrst_det && hrst_q),
                "A6 event pulses single-cycle");
      // A7: cc_txd never X
      sva_check(cc_txd !== 1'bx, "A7 cc_txd not X");
    end
    txb_q  <= (dut_tx_st != 4'd0);
    rxd_q  <= dut.rx_done;
    hrst_q <= dut.hrst_det;
  end

  // ---- constrained-random message scenarios ---------------------------
  // random safe message (mtype 7..31: no policy-engine effect) -> GoodCRC
  task automatic crv_ping;
    logic [4:0] mt; logic [2:0] mid, nob; logic [31:0] o0, o1;
    logic [15:0] hh;
    logic        ext_r, pr_r, dr_r;   // typed: concat width safety
    logic [1:0]  sr_r;
    begin
      mt  = $urandom_range(7, 31);
      mid = $urandom_range(0, 7);
      nob = $urandom_range(0, 2);
      o0  = $urandom; o1 = $urandom;
      // randomize the header template fields the sink does not inspect
      // (ext/powerrole/specrev/datarole) for toggle closure
      ext_r = $urandom_range(0, 1); pr_r = $urandom_range(0, 1);
      dr_r  = $urandom_range(0, 1); sr_r = $urandom_range(0, 3);
      hh  = {ext_r, nob, mid, pr_r, sr_r, dr_r, mt};
      send_msg(hh, o0, o1, 1'b0);
      expect_goodcrc(mid);
    end
  endtask

  // corrupt CRC32 -> no reply + irq; next valid message clears irq
  task automatic crv_badcrc;
    logic [2:0] mid;
    begin
      mid = $urandom_range(0, 7);
      send_msg(mk_hdr($urandom_range(7, 31), mid, $urandom_range(0, 2)),
               $urandom, $urandom, 1'b1);
      tx_seen = 1'b0;
      for (i = 0; i < 60; i++) begin
        @(negedge clk);
        if (cc_tx_en === 1'b1) tx_seen = 1'b1;
      end
      if (tx_seen) begin
        errors++; $display("ERROR: CRV sink replied to bad-CRC message");
      end
      if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq not asserted after bad CRC");
      end
      crv_ping;                              // recovery clears irq
      if (irq !== 1'b0) begin
        errors++; $display("ERROR: CRV irq not cleared by valid message");
      end
    end
  endtask

  // numobj > 2 -> protocol error: no reply + irq; recovery clears.
  // The frame is cut after the header (DUT aborts there): holding the line
  // at a constant level afterwards cannot form any K-code, so the hunting
  // receiver can never false-lock on a random tail.
  task automatic crv_badnobj;
    logic [2:0]  mid;
    logic [15:0] hh;
    begin
      mid = $urandom_range(0, 7);
      hh  = mk_hdr($urandom_range(7, 31), mid, $urandom_range(3, 7));
      for (int i = 0; i < 16; i++) bmc_bit(i[0]);         // preamble
      send_sym(K_SYNC1); send_sym(K_SYNC1);
      send_sym(K_SYNC1); send_sym(K_SYNC2);               // SOP
      for (int i = 0; i < 16; i++) bmc_bit(hh[i]);        // header (numobj>2)
      repeat (50) @(negedge clk);                         // truncated frame
      tx_seen = 1'b0;
      for (i = 0; i < 60; i++) begin
        @(negedge clk);
        if (cc_tx_en === 1'b1) tx_seen = 1'b1;
      end
      if (tx_seen) begin
        errors++; $display("ERROR: CRV sink replied to numobj>2 message");
      end
      if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq not asserted after numobj>2");
      end
      crv_ping;
      if (irq !== 1'b0) begin
        errors++; $display("ERROR: CRV irq not cleared after numobj>2 recovery");
      end
    end
  endtask

  // HardReset drops any contract, then a fresh negotiation re-establishes
  task automatic crv_hrst_negs;
    begin
      send_hrst();
      repeat (8) @(negedge clk);
      if (vbus_ok !== 1'b0) begin
        errors++; $display("ERROR: CRV vbus_ok still set after HardReset");
      end
      negotiate($urandom_range(0, 5));
      if (vbus_ok !== 1'b1) begin
        errors++; $display("ERROR: CRV no contract after post-reset negotiation");
      end
    end
  endtask

  // GoodCRC with wrong msgid after the sink Request -> irq, PE stalls;
  // the correct GoodCRC then completes the contract
  task automatic crv_gcrc_mismatch;
    logic [2:0] id0;
    begin
      id0 = $urandom_range(0, 5);
      send_msg(mk_hdr(MT_SRCCAP, id0, 3'd2), PDO_5V, PDO_9V, 1'b0);
      expect_goodcrc(id0);
      expect_request_9v();
      send_msg(mk_hdr(MT_GOODCRC, 3'd1, 3'd0), 0, 0, 1'b0); // wrong msgid
      repeat (4) @(negedge clk);
      if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq not set on GoodCRC msgid mismatch");
      end
      if (vbus_ok !== 1'b0) begin
        errors++; $display("ERROR: CRV vbus_ok premature (PE not stalled)");
      end
      send_msg(mk_hdr(MT_GOODCRC, 3'd0, 3'd0), 0, 0, 1'b0); // correct msgid
      repeat (2) @(negedge clk);
      if (irq !== 1'b0) begin
        errors++; $display("ERROR: CRV irq not cleared by matching GoodCRC");
      end
      send_msg(mk_hdr(MT_ACCEPT, id0 + 3'd1, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd1);
      send_msg(mk_hdr(MT_PSRDY, id0 + 3'd2, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd2);
      repeat (4) @(negedge clk);
      if (vbus_ok !== 1'b1) begin
        errors++; $display("ERROR: CRV no contract after mismatch recovery");
      end
    end
  endtask

  // single-PDO (5V-only) capabilities -> Request must select obj pos 1
  task automatic expect_request_5v;
    logic [15:0] h; logic [31:0] a, b2; logic g, cok;
    begin
      recv_msg(h, a, b2, g, cok, 300);
      if (!g) begin
        errors++; $display("ERROR: CRV no Request message from sink (5V)");
      end else begin
        if (!cok) begin
          errors++; $display("ERROR: CRV Request bad CRC32 residue (5V)");
        end
        if (h[4:0] !== MT_REQUEST || h[14:12] !== 3'd1) begin
          errors++; $display("ERROR: CRV exp Request/1obj, got hdr=%h", h);
        end
        if (a[31:28] !== 4'd1) begin
          errors++; $display("ERROR: CRV RDO objpos=%0d exp 1 (5V PDO)", a[31:28]);
        end
        if (a[19:10] !== 10'd150 || a[9:0] !== 10'd150) begin
          errors++; $display("ERROR: CRV RDO current op=%0d max=%0d exp 150/150",
                             a[19:10], a[9:0]);
        end
      end
    end
  endtask

  task automatic crv_negotiate5v;
    logic [2:0] id0;
    begin
      id0 = $urandom_range(0, 5);
      send_msg(mk_hdr(MT_SRCCAP, id0, 3'd1), PDO_5V, 0, 1'b0);
      expect_goodcrc(id0);
      expect_request_5v();
      send_msg(mk_hdr(MT_GOODCRC, 3'd0, 3'd0), 0, 0, 1'b0);
      send_msg(mk_hdr(MT_ACCEPT, id0 + 3'd1, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd1);
      send_msg(mk_hdr(MT_PSRDY, id0 + 3'd2, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd2);
      repeat (4) @(negedge clk);
      if (vbus_ok !== 1'b1) begin
        errors++; $display("ERROR: CRV vbus_ok not set after 5V negotiation");
      end
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  int i;
  logic tx_seen;
  initial begin
    rst_n = 0; repeat (4) @(posedge clk);
    rst_n = 1; repeat (2) @(posedge clk);

    // CHECK 1: reset state
    if (vbus_ok !== 1'b0 || cc_tx_en !== 1'b0 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: reset state vbus_ok=%b tx_en=%b irq=%b",
               vbus_ok, cc_tx_en, irq);
    end else $display("CHECK 1 PASS: reset state");

    // CHECK 2: full negotiation, per-message compare (incl. GoodCRC timing)
    negotiate(3'd0);
    $display("CHECK 2 done: negotiation #1 (errors=%0d)", errors);

    // CHECK 3: bad-CRC injection -> no GoodCRC, irq asserted
    send_msg(mk_hdr(MT_SRCCAP, 3'd4, 3'd2), PDO_5V, PDO_9V, 1'b1);
    tx_seen = 1'b0;
    for (i = 0; i < 60; i++) begin
      @(negedge clk);
      if (cc_tx_en === 1'b1) tx_seen = 1'b1;
    end
    if (tx_seen) begin
      errors++; $display("ERROR: sink replied to bad-CRC message");
    end
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not asserted after bad CRC");
    end else $display("CHECK 3 PASS: bad CRC -> no reply + irq");

    // CHECK 4: recovery + consecutive negotiation #2 (back-to-back traffic)
    negotiate(3'd1);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq not cleared by valid message");
    end
    $display("CHECK 4 done: negotiation #2 (errors=%0d)", errors);

    // CHECK 5: HardReset ordered set -> back to initial state
    send_hrst();
    repeat (8) @(negedge clk);
    if (vbus_ok !== 1'b0) begin
      errors++; $display("ERROR: vbus_ok still set after HardReset");
    end else $display("CHECK 5 PASS: HardReset drops contract");

    // CHECK 6: negotiation #3 after HardReset
    negotiate(3'd0);
    $display("CHECK 6 done: post-HardReset negotiation (errors=%0d)", errors);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    begin : crv_phase
      int n_ping = 0, n_neg = 0, n_badcrc = 0, n_badnobj = 0,
          n_hrst = 0, n_mis = 0, n_5v = 0;
      int roll;
      for (int t = 0; t < 100; t++) begin
        roll = $urandom_range(0, 99);
        if (roll < 30) begin
          n_ping++;    crv_ping;
        end else if (roll < 45) begin
          n_neg++;     negotiate($urandom_range(0, 5));  // incl. re-negotiation in CONTRACT
        end else if (roll < 60) begin
          n_badcrc++;  crv_badcrc;
        end else if (roll < 70) begin
          n_badnobj++; crv_badnobj;
        end else if (roll < 80) begin
          n_hrst++;    crv_hrst_negs;
        end else if (roll < 90) begin
          n_mis++;     crv_gcrc_mismatch;
        end else begin
          n_5v++;      crv_negotiate5v;
        end
      end
      $display("CRV: 100 txns (ping=%0d neg9v=%0d badcrc=%0d badnobj=%0d hrst=%0d gcrc_mismatch=%0d neg5v=%0d)",
               n_ping, n_neg, n_badcrc, n_badnobj, n_hrst, n_mis, n_5v);
    end
`endif
    if (errors == 0) $display("TEST PASSED: USB-PD");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < PD_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, PD_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // CRV phase adds ~0.6 ms of CC traffic: extend the guard. The timeout is
  // chunked into 1-us delays: with Verilator 5.006 a single long-pending
  // #delay event corrupts the --timing delay heap (docs/COVERAGE.md note 1).
  initial begin
    repeat (3000) #1000;    // 3 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #500000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
