// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for UniPro_top -- UniPro 1.x data link layer.
// TB plays the peer UniPro device: symbol-level serial rx/tx with ESC_DL
// escape + COF framing + CRC16, PACP get/set, ACK/NAC handshake.
// Checks: reset / data frame TX with hdr+payload+CRC compare / TC1 strict
// priority over TC0 / NAC retransmit <=3 then drop+irq / CPort0 uplink to
// message buffer (payload incl. escaped 7E/9D bytes) / duplicate seq ACK
// without re-accept / out-of-seq NAC / PACP set+get both directions /
// bad-CRC frame dropped + irq / recovery after error.
`timescale 1ns/1ps
module UniPro_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [7:0] COF    = 8'h7E;
  localparam logic [7:0] ESC_DL = 8'h9D;
  localparam logic [3:0] CPORT_CTL = 4'hF;
  localparam logic [7:0] CC_GET    = 8'd0;
  localparam logic [7:0] CC_SET    = 8'd1;
  localparam logic [7:0] CC_GETRSP = 8'd2;
  localparam logic [7:0] CC_SETCNF = 8'd3;
  localparam logic [7:0] CC_ACK    = 8'd4;
  localparam logic [7:0] CC_NAC    = 8'd5;

  logic clk = 0, rst_n = 0;
  logic        rx_bit;
  logic        tx_bit;
  logic        cpu_we, cpu_re;
  logic [2:0]  cpu_addr;
  logic [31:0] cpu_wdata;
  logic [31:0] cpu_rdata;
  logic        irq;

  int errors = 0;
  reg [7:0] txc [0:31];   // frame content build buffer
  reg [7:0] rxc [0:31];   // frame content receive buffer

  UniPro_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .tx_bit(tx_bit),
    .cpu_we(cpu_we), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .irq(irq)
  );

  always #5 clk = ~clk;

  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    begin
      c = crc ^ {data, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      return c;
    end
  endfunction

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions. fork/join timing coroutines lose wakeups / resume ~10us
  // late against the free-running DUT clock (W3 finding on C_PHY/D_PHY),
  // so the whole receive side is a PASSIVE RECORDER (clocked always
  // blocks) and every check is post-hoc from the main coroutine.
  // =====================================================================
  localparam int UNI_FSM_TOTAL = 12; // rxs 3 (RX_IDLE..RX_STOP) + fstate 9
  logic [11:0] fsm_seen = '0;        // visited-state bitmap
  wire  [1:0] dut_rxs    = dut.rxs;     // hierarchical FSM probes
  wire  [3:0] dut_fstate = dut.fstate;

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

  // FSM coverage: sample both DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_rxs]        <= 1'b1;
    fsm_seen[3 + dut_fstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit   first_cycle = 1;  // skip the first posedge (DUT reset values land
                          // in that NBA region)
  logic irq_q = 1'b0;
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(tx_bit === 1'b1 && irq === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: irq is a one-cycle event pulse (OR of pulse sources)
      sva_check(!(irq === 1'b1 && irq_q === 1'b1), "A2 irq is a pulse");
      // A3: queue / FIFO / buffer counts within capacity
      sva_check(dut.q0_cnt <= 4'd8 && dut.q1_cnt <= 4'd8 &&
                dut.cf_cnt <= 3'd4 && dut.m_cnt <= 6'd32,
                "A3 counts within capacity");
      // A4: the outstanding frame always carries the current tx_seq
      sva_check(!dut.awaiting || (dut.cur_seq == dut.tx_seq),
                "A4 awaiting frame seq == tx_seq");
      // A5: bit/byte counters within their envelope
      sva_check(dut.rbitcnt <= 3'd7 && dut.ser_cnt <= 4'd8 &&
                dut.pay_cnt <= 3'd3 && dut.flen <= 6'd32,
                "A5 counters within bounds");
      // A6: ACK timer bounded by the retransmit threshold
      sva_check(!dut.awaiting || dut.ack_timer <= 10'd601,
                "A6 ack_timer bounded");
      // A7: TX frame FSM only takes legal encodings
      sva_check(dut_fstate <= 4'd8, "A7 fstate legal");
      // A8: line idles high whenever nothing is being framed/serialized
      sva_check((dut_fstate != 4'd0) || dut.ser_busy || (tx_bit === 1'b1),
                "A8 idle line high");
    end
    irq_q <= irq;
  end

  // ---- passive recorder: tx_bit -> symbols -> frames ------------------
  // Replaces recv_sym/recv_frame on the Verilator path (see header note).
  // Same de-framing + CRC16 residue check as the task-based receiver.
  int         rec_st = 0;       // 0=idle 1=data bits 2=stop bit
  int         rec_bitcnt = 0;
  logic [7:0] rec_sh = 8'h00;
  logic [7:0] rec_b;
  logic [7:0] rc [0:31];
  int         rc_n = 0;
  logic       rec_esc = 1'b0;
  logic [15:0] rec_c;
  logic        fr_tc   [0:511];
  logic [3:0]  fr_cport[0:511];
  logic [3:0]  fr_seq  [0:511];
  logic [7:0]  fr_len  [0:511];
  logic [7:0]  fr_pay  [0:511][0:15];
  int          n_frames = 0;

  always @(posedge clk) begin
    if (!rst_n) begin
      // The simulator zero-initialises tx_bit, which would otherwise look like
      // a false start bit before the DUT's reset values land.
      rec_st = 0; rec_bitcnt = 0; rc_n = 0; rec_esc = 1'b0;
    end else
    case (rec_st)
      0: if (tx_bit === 1'b0) begin rec_st = 1; rec_bitcnt = 0; end
      1: begin
        rec_sh[rec_bitcnt] = tx_bit;
        if (rec_bitcnt == 7) rec_st = 2;
        else                 rec_bitcnt = rec_bitcnt + 1;
      end
      default: begin                       // stop-bit sample
        rec_st = 0;
        if (tx_bit === 1'b1) begin
          rec_b = rec_sh;
          if (rec_b == 8'h7E) begin        // COF: frame boundary
            if (rc_n > 0) begin
              rec_c = 16'hFFFF;
              for (int i = 0; i < rc_n; i++) rec_c = crc16_byte(rec_c, rc[i]);
              if (rec_c !== 16'h0000) begin
                errors++;
                $display("ERROR: recorder: DUT frame %0d bad CRC residue %h",
                         n_frames, rec_c);
              end
              if (rc_n < 5) begin
                errors++;
                $display("ERROR: recorder: DUT frame %0d too short (%0d)",
                         n_frames, rc_n);
              end else if (n_frames < 512) begin
                fr_tc[n_frames]    = rc[0][7];
                fr_cport[n_frames] = rc[0][3:0];
                fr_seq[n_frames]   = rc[1][3:0];
                fr_len[n_frames]   = rc[2];
                for (int i = 0; i < 16; i++)
                  fr_pay[n_frames][i] =
                    ((i < rc[2]) && ((3 + i) < rc_n)) ? rc[3+i] : 8'h00;
                n_frames = n_frames + 1;
              end
            end
            rc_n = 0; rec_esc = 1'b0;
          end else if (rec_esc) begin
            if (rc_n < 32) begin rc[rc_n] = rec_b ^ 8'h20; rc_n = rc_n + 1; end
            else begin
              errors++; $display("ERROR: recorder: frame overflow"); rc_n = 0;
            end
            rec_esc = 1'b0;
          end else if (rec_b == 8'h9D) begin
            rec_esc = 1'b1;
          end else begin
            if (rc_n < 32) begin rc[rc_n] = rec_b; rc_n = rc_n + 1; end
            else begin
              errors++; $display("ERROR: recorder: frame overflow"); rc_n = 0;
            end
          end
        end else begin
          errors++;
          $display("ERROR: recorder: bad stop bit on DUT symbol");
        end
      end
    endcase
  end

  // sticky event flags (drive the post-hoc checks; cleared by stimulus)
  logic v_irq_seen  = 1'b0;
  logic v_serb_seen = 1'b0;
  always @(posedge clk) begin
    if (irq)           v_irq_seen  = 1'b1;
    if (dut.ser_busy)  v_serb_seen = 1'b1;
  end

  // ---- post-hoc frame checks (no timing: safe task calls) -------------
  task automatic chk_data(input int idx, input logic etc,
                          input logic [3:0] ecport, input logic [3:0] eseq,
                          input logic [127:0] epay, input string tag);
    begin
      if (fr_cport[idx] === 4'hF) begin
        errors++;
        $display("ERROR: UniPro %s: got control frame cmd=%0d", tag,
                 fr_pay[idx][0]);
      end else begin
        if (fr_tc[idx] !== etc || fr_cport[idx] !== ecport ||
            fr_seq[idx] !== eseq || fr_len[idx] !== 8'd4) begin
          errors++;
          $display("ERROR: UniPro %s: hdr tc=%b cport=%h seq=%h len=%0d exp tc=%b cport=%h seq=%h len=4",
                   tag, fr_tc[idx], fr_cport[idx], fr_seq[idx], fr_len[idx],
                   etc, ecport, eseq);
        end
        for (int i = 0; i < 4; i++)
          if (fr_pay[idx][i] !== epay[127-8*i -: 8]) begin
            errors++;
            $display("ERROR: UniPro %s: pay[%0d]=%h exp=%h", tag, i,
                     fr_pay[idx][i], epay[127-8*i -: 8]);
          end
      end
    end
  endtask

  task automatic chk_ctl(input int idx, input logic [7:0] ecmd,
                         input logic [7:0] earg1, input logic [7:0] earg2,
                         input string tag);
    begin
      if (fr_cport[idx] !== 4'hF || fr_len[idx] !== 8'd3 ||
          fr_pay[idx][0] !== ecmd || fr_pay[idx][1] !== earg1 ||
          fr_pay[idx][2] !== earg2) begin
        errors++;
        $display("ERROR: UniPro %s: ctl cport=%h len=%0d cmd=%h a1=%h a2=%h exp cmd=%h a1=%h a2=%h",
                 tag, fr_cport[idx], fr_len[idx], fr_pay[idx][0],
                 fr_pay[idx][1], fr_pay[idx][2], ecmd, earg1, earg2);
      end
    end
  endtask

  // ---- inlined stimulus macros (single coroutine, plain awaits only) --
  `define UNI_SEND_SYM(b) \
    begin \
      sb = (b); \
      @(negedge clk); rx_bit <= 1'b0; \
      for (sb_i = 0; sb_i < 8; sb_i = sb_i + 1) begin \
        @(negedge clk); rx_bit <= sb[sb_i]; \
      end \
      @(negedge clk); rx_bit <= 1'b1; \
    end
  `define UNI_SEND_FRAME(ftc, fcport, fseq, fpay, fplen, fbad) \
    begin \
      sf_txc[0] = {ftc, 3'b000, fcport}; \
      sf_txc[1] = {4'b0000, fseq}; \
      sf_txc[2] = 8'(fplen); \
      for (sf_i = 0; sf_i < fplen; sf_i = sf_i + 1) \
        sf_txc[3+sf_i] = fpay[127-8*sf_i -: 8]; \
      sf_c = 16'hFFFF; \
      for (sf_i = 0; sf_i < 3 + fplen; sf_i = sf_i + 1) \
        sf_c = crc16_byte(sf_c, sf_txc[sf_i]); \
      if (fbad) sf_c = sf_c ^ 16'h00FF; \
      sf_txc[3+fplen] = sf_c[15:8]; \
      sf_txc[4+fplen] = sf_c[7:0]; \
      sf_n = 5 + fplen; \
      `UNI_SEND_SYM(8'h7E) \
      for (sf_i = 0; sf_i < sf_n; sf_i = sf_i + 1) begin \
        sf_b = sf_txc[sf_i]; \
        if (sf_b == 8'h7E || sf_b == 8'h9D) begin \
          `UNI_SEND_SYM(8'h9D) \
          `UNI_SEND_SYM(sf_b ^ 8'h20) \
        end else begin \
          `UNI_SEND_SYM(sf_b) \
        end \
      end \
      `UNI_SEND_SYM(8'h7E) \
    end
  `define UNI_SEND_ACK(s) \
    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, {8'd4, 4'b0000, s, 8'h00, 104'h0}, 3, 1'b0)
  `define UNI_SEND_NAC(s) \
    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, {8'd5, 4'b0000, s, 8'h00, 104'h0}, 3, 1'b0)
  `define UNI_CPU_WR(a, d) \
    @(negedge clk); cpu_we <= 1'b1; cpu_addr <= (a); cpu_wdata <= (d); \
    @(negedge clk); cpu_we <= 1'b0;
  `define UNI_CPU_RD(a, d) \
    @(negedge clk); cpu_addr <= (a); cpu_re <= 1'b1; \
    #1; d = cpu_rdata; \
    @(negedge clk); cpu_re <= 1'b0;
  `define UNI_WAIT_FRAMES(n) \
    begin \
      wf_to = 0; \
      while ((n_frames < (n)) && (wf_to < 20000)) begin \
        @(posedge clk); wf_to = wf_to + 1; \
      end \
      if (n_frames < (n)) begin \
        errors++; \
        $display("ERROR: UniPro timeout waiting frame count %0d (have %0d)", \
                 (n), n_frames); \
      end \
    end
  `define UNI_WAIT_CLK(n) \
    begin \
      for (wf_to = 0; wf_to < (n); wf_to = wf_to + 1) @(posedge clk); \
    end
`endif

  // ------------------------------------------------------------------
  // symbol layer (peer model)
  // ------------------------------------------------------------------
  task automatic send_sym(input logic [7:0] b);
    begin
      @(negedge clk); rx_bit <= 1'b0;            // start
      for (int i = 0; i < 8; i++) begin
        @(negedge clk); rx_bit <= b[i];          // LSB first
      end
      @(negedge clk); rx_bit <= 1'b1;            // stop
    end
  endtask

  task automatic recv_sym(output logic [7:0] b, output int st);
    int to;
    begin
      st = 0; to = 0; b = '0;
      while (tx_bit == 1'b1 && to < 4000) begin @(posedge clk); to++; end
      if (tx_bit == 1'b1) begin
        st = 1;
      end else begin
        for (int i = 0; i < 8; i++) begin
          @(posedge clk); b[i] = tx_bit;
        end
        @(posedge clk);                          // stop bit
      end
    end
  endtask

  // ------------------------------------------------------------------
  // frame layer
  // ------------------------------------------------------------------
  // send L2 frame; payload bytes in pay[127:120].. big-endian
  task automatic send_frame(input logic tc, input logic [3:0] cport,
                            input logic [3:0] seq, input logic [127:0] pay,
                            input int plen, input logic bad_crc);
    logic [15:0] c;
    int n;
    logic [7:0] b;
    begin
      txc[0] = {tc, 3'b000, cport};
      txc[1] = {4'b0000, seq};
      txc[2] = plen[7:0];
      for (int i = 0; i < plen; i++) txc[3+i] = pay[127 - 8*i -: 8];
      c = 16'hFFFF;
      for (int i = 0; i < 3 + plen; i++) c = crc16_byte(c, txc[i]);
      if (bad_crc) c = c ^ 16'h00FF;
      txc[3+plen] = c[15:8];
      txc[4+plen] = c[7:0];
      n = 5 + plen;
      send_sym(COF);
      for (int i = 0; i < n; i++) begin
        b = txc[i];
        if (b == COF || b == ESC_DL) begin
          send_sym(ESC_DL);
          send_sym(b ^ 8'h20);
        end else begin
          send_sym(b);
        end
      end
      send_sym(COF);
    end
  endtask

  // receive L2 frame; status: 0=ok 1=timeout 2=bad CRC 3=bad len/framing
  task automatic recv_frame(output logic tc, output logic [3:0] cport,
                            output logic [3:0] seq, output logic [127:0] pay,
                            output int plen, output int status);
    logic [7:0] b;
    logic esc;
    int st, n, to;
    logic [15:0] c;
    begin
      status = 0; pay = '0; plen = 0; n = 0; esc = 0;
      tc = 'x; cport = 'x; seq = 'x;
      // wait for COF
      to = 0;
      b = '0;
      while (b != COF && to < 20) begin
        recv_sym(b, st);
        if (st != 0) to = 99;
        to++;
      end
      if (b != COF) begin
        status = 1;
      end else begin
        // collect until next COF
        st = 0;
        while (st == 0) begin
          recv_sym(b, st);
          if (st == 0) begin
            if (esc) begin
              rxc[n] = b ^ 8'h20; n++; esc = 0;
            end else if (b == ESC_DL) begin
              esc = 1;
            end else if (b == COF) begin
              st = 2;                        // frame complete
            end else begin
              rxc[n] = b; n++;
            end
          end
        end
        if (st == 1) begin
          status = 1;
        end else if (n < 5) begin
          status = 3;
          $display("DBG recv_frame: n=%0d b0=%h b1=%h b2=%h", n, rxc[0], rxc[1], rxc[2]);
        end else begin
          c = 16'hFFFF;
          for (int i = 0; i < n; i++) c = crc16_byte(c, rxc[i]);
          if (c != 16'h0000) begin
            status = 2;
          end else if (n != 5 + rxc[2]) begin
            status = 3;
            $display("DBG recv_frame: n=%0d len=%0d b0=%h b1=%h b2=%h b3=%h b4=%h",
                     n, rxc[2], rxc[0], rxc[1], rxc[2], rxc[3], rxc[4]);
          end else begin
            tc    = rxc[0][7];
            cport = rxc[0][3:0];
            seq   = rxc[1][3:0];
            plen  = rxc[2];
            for (int i = 0; i < rxc[2]; i++) pay[127 - 8*i -: 8] = rxc[3+i];
          end
        end
      end
    end
  endtask

  // expect a data frame with given header + payload
  task automatic expect_data(input logic etc, input logic [3:0] ecport,
                             input logic [3:0] eseq, input logic [127:0] epay,
                             input string tag);
    logic tc; logic [3:0] cport, seq; logic [127:0] pay; int plen, status;
    begin
      recv_frame(tc, cport, seq, pay, plen, status);
      if (status != 0) begin
        errors++;
        $display("ERROR: UniPro %s: recv status=%0d", tag, status);
      end else if (cport == CPORT_CTL) begin
        errors++;
        $display("ERROR: UniPro %s: got control frame cmd=%0d", tag, pay[127:120]);
      end else begin
        if (tc !== etc || cport !== ecport || seq !== eseq || plen != 4) begin
          errors++;
          $display("ERROR: UniPro %s: hdr tc=%b cport=%h seq=%h len=%0d exp tc=%b cport=%h seq=%h len=4",
                   tag, tc, cport, seq, plen, etc, ecport, eseq);
        end
        if (pay !== epay) begin
          errors++;
          $display("ERROR: UniPro %s: payload=%h exp=%h", tag, pay, epay);
        end
      end
    end
  endtask

  // expect a control frame {cmd, arg1, arg2}
  task automatic expect_ctl(input logic [7:0] ecmd, earg1, earg2,
                            input string tag);
    logic tc; logic [3:0] cport, seq; logic [127:0] pay; int plen, status;
    begin
      recv_frame(tc, cport, seq, pay, plen, status);
      if (status != 0) begin
        errors++;
        $display("ERROR: UniPro %s: recv status=%0d", tag, status);
      end else if (cport != CPORT_CTL || plen != 3 ||
                   pay[127:120] !== ecmd || pay[119:112] !== earg1 ||
                   pay[111:104] !== earg2) begin
        errors++;
        $display("ERROR: UniPro %s: ctl cport=%h len=%0d cmd=%h a1=%h a2=%h exp cmd=%h a1=%h a2=%h",
                 tag, cport, plen, pay[127:120], pay[119:112], pay[111:104],
                 ecmd, earg1, earg2);
      end
    end
  endtask

  task automatic send_ack(input logic [3:0] seq);
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_ACK, 4'b0000, seq, 8'h00, 104'h0}, 3, 1'b0);
  endtask

  task automatic send_nac(input logic [3:0] seq);
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_NAC, 4'b0000, seq, 8'h00, 104'h0}, 3, 1'b0);
  endtask

  // ------------------------------------------------------------------
  // cpu port model
  // ------------------------------------------------------------------
  task automatic cpu_wr(input logic [2:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      cpu_we <= 1'b1; cpu_addr <= a; cpu_wdata <= d;
      @(negedge clk);
      cpu_we <= 1'b0;
    end
  endtask

  task automatic cpu_rd(input logic [2:0] a, output logic [31:0] d);
    begin
      @(negedge clk);
      cpu_addr <= a; cpu_re <= 1'b1;
      #1 d = cpu_rdata;              // sample before the pop/clear posedge
      @(negedge clk);
      cpu_re <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [31:0] rd;
  logic [127:0] p;
  logic irq_seen, fr_seen;

  initial begin
`ifdef VERILATOR
    // CRV support locals (Verilator path; single coroutine, macros only)
    int           wf_to, sf_i, sf_n, sb_i;
    logic [7:0]   sb, sf_b;
    logic [7:0]   sf_txc [0:31];
    logic [15:0]  sf_c;
    int           plen_c;
    logic [127:0] pay128;
    logic [31:0]  dw;
    logic         tc_c;
    logic [3:0]   idx4, seq_m, eseq_m;
    logic [7:0]   val8, attr_m [0:15];
    logic [31:0]  qpay [0:8];
    int           mbuf_m, base, roll, roll2, eroll;
    int           n_push, n_up, n_ppacp, n_cpacp;
    int           n_bcrc, n_oos, n_dup, n_retx, n_mof, n_frm, n_qof, n_cof;
    logic [3:0]   cport_m;        // tx_cport register model
`endif
    rx_bit = 1'b1; cpu_we = 0; cpu_re = 0; cpu_addr = 0; cpu_wdata = 0;
    rst_n = 0; repeat (4) @(posedge clk);

`ifdef VERILATOR
    // =================================================================
    // On the Verilator side: recorder-based directed sequence (mirrors the
    // iverilog checks 1-7 one-to-one) + CRV random phase. All receives
    // are post-hoc against the passive recorder; all stimulus is inlined
    // via macros (single coroutine, plain awaits only).
    // =================================================================

    // CHECK 1: reset state
    if (tx_bit !== 1'b1 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: UniPro reset state tx_bit=%b irq=%b", tx_bit, irq);
    end
    rst_n = 1; repeat (2) @(posedge clk);
    `UNI_CPU_RD(3'd5, rd)
    if (rd[13:0] !== 14'h0) begin
      errors++;
      $display("ERROR: UniPro reset status=%h exp 0", rd);
    end

    // CHECK 2: single TC0 data frame + ACK
    `UNI_CPU_WR(3'd0, 32'h1111_1111)
    `UNI_WAIT_FRAMES(1)
    chk_data(0, 1'b0, 4'h0, 4'h0, {32'h1111_1111, 96'h0}, "tc0 data frame seq0");
    `UNI_SEND_ACK(4'h0)
    `UNI_WAIT_CLK(20)
    `UNI_CPU_RD(3'd5, rd)
    if (rd[3:0] !== 4'h0) begin
      errors++;
      $display("ERROR: UniPro q0 not drained after ACK status=%h", rd);
    end

    // CHECK 3: TC1 strict priority over TC0
    `UNI_CPU_WR(3'd0, 32'hAAAA_0001)           // A -> TC0, sent first
    `UNI_WAIT_FRAMES(2)
    chk_data(1, 1'b0, 4'h0, 4'h1, {32'hAAAA_0001, 96'h0}, "tc0 frame A seq1");
    `UNI_CPU_WR(3'd0, 32'hBBBB_0002)           // B -> TC0 (queued behind A)
    `UNI_CPU_WR(3'd1, 32'hCCCC_0003)           // C -> TC1
    `UNI_SEND_ACK(4'h1)                        // release A; C must win next slot
    `UNI_WAIT_FRAMES(3)
    chk_data(2, 1'b1, 4'h0, 4'h2, {32'hCCCC_0003, 96'h0}, "tc1 frame C seq2");
    `UNI_SEND_ACK(4'h2)
    `UNI_WAIT_FRAMES(4)
    chk_data(3, 1'b0, 4'h0, 4'h3, {32'hBBBB_0002, 96'h0}, "tc0 frame B seq3");
    `UNI_SEND_ACK(4'h3)
    `UNI_WAIT_CLK(20)

    // CHECK 4: NAC retransmit <=3 then drop + irq
    `UNI_CPU_WR(3'd0, 32'hDDDD_0004)
    `UNI_WAIT_FRAMES(5)
    chk_data(4, 1'b0, 4'h0, 4'h4, {32'hDDDD_0004, 96'h0}, "frame D seq4 orig");
    `UNI_SEND_NAC(4'h4)
    `UNI_WAIT_FRAMES(6)
    chk_data(5, 1'b0, 4'h0, 4'h4, {32'hDDDD_0004, 96'h0}, "frame D retransmit 1");
    `UNI_SEND_NAC(4'h4)
    `UNI_WAIT_FRAMES(7)
    chk_data(6, 1'b0, 4'h0, 4'h4, {32'hDDDD_0004, 96'h0}, "frame D retransmit 2");
    `UNI_SEND_NAC(4'h4)
    `UNI_WAIT_FRAMES(8)
    chk_data(7, 1'b0, 4'h0, 4'h4, {32'hDDDD_0004, 96'h0}, "frame D retransmit 3");
    // 4th NAC: budget exhausted -> drop + irq, no more retransmission
    `UNI_WAIT_CLK(20)
    v_irq_seen = 1'b0; v_serb_seen = 1'b0;
    `UNI_SEND_NAC(4'h4)
    `UNI_WAIT_CLK(300)
    if (!v_irq_seen) begin
      errors++;
      $display("ERROR: UniPro NAC exhausted: no irq pulse");
    end
    if (v_serb_seen) begin
      errors++;
      $display("ERROR: UniPro NAC exhausted: frame retransmitted >3 times");
    end
    `UNI_CPU_RD(3'd5, rd)
    if (rd[3:0] !== 4'h0) begin
      errors++;
      $display("ERROR: UniPro dropped frame still queued status=%h", rd);
    end

    // CHECK 5: CPort0 uplink incl. escaped bytes, duplicate, out-of-seq
    pay128 = {8'h7E, 8'h9D, 8'h00, 8'hFF, 96'h0};
    `UNI_SEND_FRAME(1'b0, 4'h0, 4'h0, pay128, 4, 1'b0)   // peer seq0
    `UNI_WAIT_FRAMES(9)
    chk_ctl(8, 8'd4, 8'h00, 8'h00, "uplink ACK seq0");
    `UNI_CPU_RD(3'd5, rd)
    if (rd[13:8] !== 6'd4) begin
      errors++;
      $display("ERROR: UniPro msg count=%0d exp 4", rd[13:8]);
    end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h7E) begin errors++; $display("ERROR: UniPro msg[0]=%h exp 7E", rd[7:0]); end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h9D) begin errors++; $display("ERROR: UniPro msg[1]=%h exp 9D", rd[7:0]); end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h00) begin errors++; $display("ERROR: UniPro msg[2]=%h exp 00", rd[7:0]); end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'hFF) begin errors++; $display("ERROR: UniPro msg[3]=%h exp FF", rd[7:0]); end
    // duplicate seq0: ACK again, no re-accept
    `UNI_SEND_FRAME(1'b0, 4'h0, 4'h0, pay128, 4, 1'b0)
    `UNI_WAIT_FRAMES(10)
    chk_ctl(9, 8'd4, 8'h00, 8'h00, "duplicate ACK seq0");
    `UNI_CPU_RD(3'd5, rd)
    if (rd[13:8] !== 6'd0) begin
      errors++;
      $display("ERROR: UniPro duplicate accepted msg_cnt=%0d", rd[13:8]);
    end
    // out-of-sequence: expect NAC with exp_seq=1
    pay128 = {32'h5555_0005, 96'h0};
    `UNI_SEND_FRAME(1'b0, 4'h0, 4'h5, pay128, 4, 1'b0)
    `UNI_WAIT_FRAMES(11)
    chk_ctl(10, 8'd5, 8'h01, 8'h00, "out-of-seq NAC");

    // CHECK 6: PACP both directions
    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, {8'd1, 8'h03, 8'h5A, 104'h0}, 3, 1'b0)
    `UNI_WAIT_FRAMES(12)
    chk_ctl(11, 8'd3, 8'h03, 8'h00, "PACP set cnf");
    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, {8'd0, 8'h03, 8'h00, 104'h0}, 3, 1'b0)
    `UNI_WAIT_FRAMES(13)
    chk_ctl(12, 8'd2, 8'h03, 8'h5A, "PACP get rsp");
    // DUT-initiated: cpu PACP SET idx=5 val=A5
    `UNI_CPU_WR(3'd2, {16'h0, 8'hA5, 4'h0, 4'h5})
    `UNI_WAIT_FRAMES(14)
    chk_ctl(13, 8'd1, 8'h05, 8'hA5, "PACP cpu set req");
    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, {8'd3, 8'h05, 8'h00, 104'h0}, 3, 1'b0)
    `UNI_WAIT_CLK(30)
    `UNI_CPU_RD(3'd6, rd)
    if (rd[9] !== 1'b1) begin
      errors++;
      $display("ERROR: UniPro pacp_cnf not set rd=%h", rd);
    end
    // DUT-initiated: cpu PACP GET idx=5
    `UNI_CPU_WR(3'd3, {28'h0, 4'h5})
    `UNI_WAIT_FRAMES(15)
    chk_ctl(14, 8'd0, 8'h05, 8'h00, "PACP cpu get req");
    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, {8'd2, 8'h05, 8'hA5, 104'h0}, 3, 1'b0)
    `UNI_WAIT_CLK(30)
    `UNI_CPU_RD(3'd6, rd)
    if (rd[8] !== 1'b1 || rd[7:0] !== 8'hA5) begin
      errors++;
      $display("ERROR: UniPro pacp_rsp rd=%h exp valid+A5", rd);
    end

    // CHECK 7: error injection - bad CRC data frame dropped + irq
    v_irq_seen = 1'b0; v_serb_seen = 1'b0;
    pay128 = {32'hBAD0_0001, 96'h0};
    `UNI_SEND_FRAME(1'b0, 4'h0, 4'h1, pay128, 4, 1'b1)   // corrupted CRC
    `UNI_WAIT_CLK(200)
    if (!v_irq_seen) begin
      errors++;
      $display("ERROR: UniPro bad-CRC frame: no irq pulse");
    end
    if (v_serb_seen) begin
      errors++;
      $display("ERROR: UniPro bad-CRC frame: DUT responded");
    end

    // recovery: valid seq1 frame still accepted
    pay128 = {32'h600D_0001, 96'h0};
    `UNI_SEND_FRAME(1'b0, 4'h0, 4'h1, pay128, 4, 1'b0)
    `UNI_WAIT_FRAMES(16)
    chk_ctl(15, 8'd4, 8'h01, 8'h00, "recovery ACK seq1");
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h60) begin errors++; $display("ERROR: UniPro recovery msg[0]=%h exp 60", rd[7:0]); end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h0D) begin errors++; $display("ERROR: UniPro recovery msg[1]=%h exp 0D", rd[7:0]); end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h00) begin errors++; $display("ERROR: UniPro recovery msg[2]=%h exp 00", rd[7:0]); end
    `UNI_CPU_RD(3'd4, rd) if (rd[7:0] !== 8'h01) begin errors++; $display("ERROR: UniPro recovery msg[3]=%h exp 01", rd[7:0]); end

    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 126 randomized transactions, single coroutine, all stimulus inlined
    // via macros, all receives post-hoc via the passive recorder.
    // Normal classes (~2/3): TC0/TC1 data push + ACK (random payload incl.
    // escape-heavy 7E/9D patterns); CPort0 uplink (random plen 1-4, msg
    // buffer popped and compared) / nonzero-CPort uplink (ACK, payload
    // dropped); peer PACP set/get; cpu PACP set/get with peer response.
    // Error classes (round-robin selector, all parameters randomized):
    //   0 bad-CRC data frame (dropped + irq, no response)
    //   1 out-of-sequence data frame (NAC with expected seq)
    //   2 duplicate sequence (re-ACK, no re-accept)
    //   3 retransmit: NAC-triggered / ACK-timeout-triggered (alternating)
    //   4 message-buffer overflow (fill 32B, one more -> e_mof + NAC)
    //   5 framing error: missing stop bit (e_frm irq, deframer resyncs)
    //   6 queue overflow: 9 pushes into an 8-deep queue (e_qof irq)
    begin : crv_phase
      n_push = 0; n_up = 0; n_ppacp = 0; n_cpacp = 0;
      n_bcrc = 0; n_oos = 0; n_dup = 0; n_retx = 0; n_mof = 0; n_frm = 0;
      n_qof = 0; n_cof = 0;
      eroll = 0;
      cport_m = 4'h0;
      seq_m  = dut.tx_seq;      // outgoing data frame seq model
      eseq_m = dut.exp_seq;     // uplink expected seq model
      mbuf_m = 0;               // msg-buffer occupancy model (empty now)
      for (int i = 0; i < 16; i++) attr_m[i] = 8'h00;
      attr_m[3] = 8'h5A;        // directed CHECK 6 set attr3
      for (int t = 0; t < 126; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 20) begin
          roll2 = $urandom_range(0, 19);
          if (roll2 < 9) begin
            // ---- TC data push + ACK ----
            n_push++;
            tc_c = ($urandom_range(0, 1) == 1);
            roll = $urandom_range(0, 9);
            dw = (roll == 0) ? 32'h7E9D_7E9D :      // escape-heavy boundary
                 (roll == 1) ? 32'h0000_0000 :
                 (roll == 2) ? 32'hFFFF_FFFF : $urandom;
            if (roll2 % 4 == 0) begin
              // program the TX CPort register and verify it on the wire
              cport_m = 4'($urandom_range(0, 14));
              `UNI_CPU_WR(3'd4, {28'h0, cport_m})
            end
            `UNI_CPU_WR(tc_c ? 3'd1 : 3'd0, dw)
            base = n_frames;
            `UNI_WAIT_FRAMES(base + 1)
            chk_data(base, tc_c, cport_m, seq_m, {dw, 96'h0}, "crv push");
            `UNI_SEND_ACK(seq_m)
            seq_m = seq_m + 4'd1;
            `UNI_WAIT_CLK(5)
          end else if (roll2 < 14) begin
            // ---- uplink data frame (CPort0 -> msg buffer / other CPort) --
            n_up++;
            roll = $urandom_range(0, 9);
            plen_c = (roll < 6) ? 1 + $urandom_range(0, 3)
                                : 5 + $urandom_range(0, 11);  // up to 16
            pay128 = {$urandom, $urandom, $urandom, $urandom};
            if ($urandom_range(0, 3) == 0)
              pay128[127 -: 32] = 32'h7E9D_7E9D;    // escaped-byte coverage
            for (int i = 16; i < 32; i++) sf_txc[i] = 8'h00;
            if (roll2 < 11) begin
              // make room in the message buffer if the frame would not fit
              while (mbuf_m + plen_c > 30) begin
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
              // CPort0: accepted into the message buffer
              v_irq_seen = 1'b0;
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, plen_c, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd4, {4'h0, eseq_m}, 8'h00, "crv uplink ACK");
              eseq_m = eseq_m + 4'd1;
              mbuf_m = mbuf_m + plen_c;
              // pop and compare the payload bytes
              for (int i = 0; i < plen_c; i++) begin
                `UNI_CPU_RD(3'd4, rd)
                if (rd[7:0] !== pay128[127-8*i -: 8]) begin
                  errors++;
                  $display("ERROR: CRV uplink byte %0d got=%h exp=%h",
                           i, rd[7:0], pay128[127-8*i -: 8]);
                end
                mbuf_m = mbuf_m - 1;
              end
              if (v_irq_seen) begin
                errors++; $display("ERROR: CRV irq on clean uplink");
              end
            end else begin
              // other CPorts: accepted + ACK, payload dropped
              idx4 = 4'($urandom_range(1, 14));
              if (idx4 == 4'hF) idx4 = 4'h7;        // rejection (paranoia)
              `UNI_SEND_FRAME(1'b0, idx4, eseq_m, pay128, plen_c, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd4, {4'h0, eseq_m}, 8'h00, "crv uplink other-cport ACK");
              eseq_m = eseq_m + 4'd1;
            end
          end else if (roll2 < 17) begin
            // ---- peer PACP set/get roundtrip ----
            n_ppacp++;
            idx4 = 4'($urandom_range(0, 15));
            val8 = 8'($urandom_range(0, 255));
            base = n_frames;
            pay128 = {8'd1, {4'h0, idx4}, val8, 104'h0};
            `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
            `UNI_WAIT_FRAMES(base + 1)
            chk_ctl(base, 8'd3, {4'h0, idx4}, 8'h00, "crv pacp set cnf");
            attr_m[idx4] = val8;
            base = n_frames;
            pay128 = {8'd0, {4'h0, idx4}, 8'h00, 104'h0};
            `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
            `UNI_WAIT_FRAMES(base + 1)
            chk_ctl(base, 8'd2, {4'h0, idx4}, attr_m[idx4], "crv pacp get rsp");
          end else begin
            // ---- cpu PACP set/get with peer response ----
            n_cpacp++;
            idx4 = 4'($urandom_range(0, 15));
            val8 = 8'($urandom_range(0, 255));
            if (n_cpacp % 2 == 1) begin
              `UNI_CPU_WR(3'd2, {16'h0, val8, 4'h0, idx4})
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd1, {4'h0, idx4}, val8, "crv cpu pacp set req");
              pay128 = {8'd3, {4'h0, idx4}, 8'h00, 104'h0};
              `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
              `UNI_WAIT_CLK(30)
              `UNI_CPU_RD(3'd6, rd)
              if (rd[9] !== 1'b1) begin
                errors++; $display("ERROR: CRV pacp_cnf not set rd=%h", rd);
              end
            end else begin
              `UNI_CPU_WR(3'd3, {28'h0, idx4})
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd0, {4'h0, idx4}, 8'h00, "crv cpu pacp get req");
              pay128 = {8'd2, {4'h0, idx4}, attr_m[idx4], 104'h0};
              `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
              `UNI_WAIT_CLK(30)
              `UNI_CPU_RD(3'd6, rd)
              if (rd[8] !== 1'b1 || rd[7:0] !== attr_m[idx4]) begin
                errors++;
                $display("ERROR: CRV pacp_rsp rd=%h exp valid+%h", rd,
                         attr_m[idx4]);
              end
            end
          end
        end else begin
          // ---- error / special classes (round-robin) ----
          case (eroll)
            0: begin
              // bad-CRC data frame: dropped + irq, no response
              n_bcrc++;
              pay128 = {$urandom, $urandom, $urandom, $urandom};
              v_irq_seen = 1'b0;
              base = n_frames;
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b1)
              pay128 = {$urandom, $urandom, $urandom, $urandom};
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b1)
              `UNI_WAIT_CLK(60)
              if (!v_irq_seen) begin
                errors++; $display("ERROR: CRV bad CRC: no irq");
              end
              if (n_frames != base) begin
                errors++;
                $display("ERROR: CRV bad CRC: response emitted");
              end
              // unknown control command: default arm, ignored silently
              base = n_frames;
              v_irq_seen = 1'b0;
              pay128 = {8'h7F, 8'h12, 8'h34, 104'h0};
              `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
              `UNI_WAIT_CLK(60)
              if (n_frames != base) begin
                errors++;
                $display("ERROR: CRV unknown ctl cmd: response emitted");
              end
              if (v_irq_seen) begin
                errors++; $display("ERROR: CRV unknown ctl cmd: irq");
              end
            end
            1: begin
              // out-of-sequence data frame: NAC carrying the expected seq
              n_oos++;
              idx4 = eseq_m + 4'd1 + 4'($urandom_range(0, 13));
              if (idx4 == eseq_m || idx4 == (eseq_m - 4'd1))
                idx4 = eseq_m + 4'd2;              // rejection sampling
              pay128 = {$urandom, 96'h0};
              `UNI_SEND_FRAME(1'b0, 4'h0, idx4, pay128, 4, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd5, {4'h0, eseq_m}, 8'h00, "crv out-of-seq NAC");
            end
            2: begin
              // duplicate sequence: re-ACK, no re-accept
              n_dup++;
              if (eseq_m == 4'h0) begin
                // no frame accepted yet: establish one first (plain uplink)
                pay128 = {$urandom, 96'h0};
                `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b0)
                base = n_frames;
                `UNI_WAIT_FRAMES(base + 1)
                chk_ctl(base, 8'd4, {4'h0, eseq_m}, 8'h00, "crv dup-prime ACK");
                eseq_m = eseq_m + 4'd1;
                for (int i = 0; i < 4; i++) begin
                  `UNI_CPU_RD(3'd4, rd)
                end
              end
              pay128 = {$urandom, 96'h0};
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m - 4'd1, pay128, 4, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd4, {4'h0, eseq_m - 4'd1}, 8'h00, "crv dup ACK");
              `UNI_CPU_RD(3'd5, rd)
              if (rd[13:8] !== 6'(mbuf_m)) begin
                errors++;
                $display("ERROR: CRV duplicate accepted msg_cnt=%0d exp %0d",
                         rd[13:8], mbuf_m);
              end
            end
            3: begin
              // retransmit: NAC-triggered / ACK-timeout (alternating)
              n_retx++;
              tc_c = ($urandom_range(0, 1) == 1);
              dw = $urandom;
              `UNI_CPU_WR(tc_c ? 3'd1 : 3'd0, dw)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_data(base, tc_c, cport_m, seq_m, {dw, 96'h0}, "crv retx orig");
              if (n_retx % 2 == 1) begin
                // NAC -> immediate retransmission with the same seq
                `UNI_SEND_NAC(seq_m)
                `UNI_WAIT_FRAMES(base + 2)
                chk_data(base + 1, tc_c, cport_m, seq_m, {dw, 96'h0},
                         "crv retx nac");
                `UNI_SEND_ACK(seq_m)
              end else begin
                // no ACK: ack_timer hits ACK_WAIT -> retransmission
                `UNI_WAIT_FRAMES(base + 2)
                chk_data(base + 1, tc_c, cport_m, seq_m, {dw, 96'h0},
                         "crv retx timeout");
                `UNI_SEND_ACK(seq_m)
              end
              seq_m = seq_m + 4'd1;
              `UNI_WAIT_CLK(5)
            end
            4: begin
              // message-buffer overflow: fill 32B, one more -> e_mof + NAC
              n_mof++;
              while (mbuf_m > 0) begin             // drain first
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
              while (mbuf_m + 4 <= 32) begin       // fill to capacity
                pay128 = {$urandom, 96'h0};
                `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b0)
                base = n_frames;
                `UNI_WAIT_FRAMES(base + 1)
                chk_ctl(base, 8'd4, {4'h0, eseq_m}, 8'h00, "crv mof fill ACK");
                eseq_m = eseq_m + 4'd1;
                mbuf_m = mbuf_m + 4;
                if (mbuf_m == 8 || mbuf_m == 16) begin
                  `UNI_CPU_RD(3'd5, rd)        // status mid-fill
                  if (rd[13:8] !== 6'(mbuf_m)) begin
                    errors++;
                    $display("ERROR: CRV mof mid-status m_cnt=%0d exp %0d",
                             rd[13:8], mbuf_m);
                  end
                end
              end
              `UNI_CPU_RD(3'd5, rd)          // status at full buffer
              if (rd[13:8] !== 6'd32) begin
                errors++;
                $display("ERROR: CRV mof status m_cnt=%0d exp 32", rd[13:8]);
              end
              pay128 = {$urandom, 96'h0};
              v_irq_seen = 1'b0;
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd5, {4'h0, eseq_m}, 8'h00, "crv mof NAC");
              `UNI_WAIT_CLK(10)
              if (!v_irq_seen) begin
                errors++; $display("ERROR: CRV msg overflow: no irq");
              end
              while (mbuf_m > 0) begin             // drain for the next round
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
            end
            5: begin
              // framing error: missing stop bit -> e_frm irq
              n_frm++;
              v_irq_seen = 1'b0;
              base = n_frames;
              sb = 8'($urandom_range(0, 255));
              @(negedge clk); rx_bit <= 1'b0;      // start
              for (sb_i = 0; sb_i < 8; sb_i = sb_i + 1) begin
                @(negedge clk); rx_bit <= sb[sb_i];
              end
              @(negedge clk); rx_bit <= 1'b0;      // bad stop (held low)
              @(negedge clk); rx_bit <= 1'b1;      // release to idle
              `UNI_WAIT_CLK(30)
              if (!v_irq_seen) begin
                errors++; $display("ERROR: CRV framing error: no irq");
              end
              if (n_frames != base) begin
                errors++;
                $display("ERROR: CRV framing error: response emitted");
              end
              // resync: a following valid frame is processed normally
              pay128 = {$urandom, 96'h0};
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd4, {4'h0, eseq_m}, 8'h00, "crv frm resync ACK");
              eseq_m = eseq_m + 4'd1;
              mbuf_m = mbuf_m + 4;
              for (int i = 0; i < 4; i++) begin
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
              // oversized frame (> 32 bytes): de-framer fdrop, silent drop
              v_irq_seen = 1'b0;
              base = n_frames;
              begin
                sf_txc[0] = {1'b0, 3'b000, 4'h0};
                sf_txc[1] = {4'h0, eseq_m};
                sf_txc[2] = 8'd27;
                for (sf_i = 0; sf_i < 31; sf_i = sf_i + 1)
                  sf_txc[3+sf_i] = 8'($urandom_range(0, 255));
                sf_txc[32] = 8'h55;   // plain byte at flen == 32 (fdrop)
                sf_txc[33] = 8'h9D;   // then ESC + one more content byte
                sf_txc[34] = 8'h66;   // (esc-arm fdrop)
                `UNI_SEND_SYM(8'h7E)
                for (sf_i = 0; sf_i < 35; sf_i = sf_i + 1) begin
                  sf_b = sf_txc[sf_i];
                  if (sf_b == 8'h7E || sf_b == 8'h9D) begin
                    `UNI_SEND_SYM(8'h9D)
                    `UNI_SEND_SYM(sf_b ^ 8'h20)
                  end else begin
                    `UNI_SEND_SYM(sf_b)
                  end
                end
                `UNI_SEND_SYM(8'h7E)
              end
              `UNI_WAIT_CLK(60)
              // fdrop frames never reach the frame processor: silent drop
              if (v_irq_seen) begin
                errors++; $display("ERROR: CRV oversized frame: unexpected irq");
              end
              if (n_frames != base) begin
                errors++;
                $display("ERROR: CRV oversized frame: response emitted");
              end
              // resync: a following valid frame is processed normally
              pay128 = {$urandom, 96'h0};
              `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 4, 1'b0)
              base = n_frames;
              `UNI_WAIT_FRAMES(base + 1)
              chk_ctl(base, 8'd4, {4'h0, eseq_m}, 8'h00, "crv fdrop resync ACK");
              eseq_m = eseq_m + 4'd1;
              mbuf_m = mbuf_m + 4;
              for (int i = 0; i < 4; i++) begin
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
            end
            6: begin
              // queue overflow: 9 pushes into an 8-deep queue (TC0/TC1 alt)
              n_qof++;
              tc_c = (n_qof % 2 == 0);          // odd: TC0, even: TC1
              for (int qi = 0; qi < 9; qi++) begin
                qpay[qi] = $urandom;
              end
              v_irq_seen = 1'b0;
              for (int qi = 0; qi < 9; qi++) begin
                `UNI_CPU_WR(tc_c ? 3'd1 : 3'd0, qpay[qi])
              end
              `UNI_WAIT_CLK(20)
              if (!v_irq_seen) begin
                errors++; $display("ERROR: CRV queue overflow: no irq");
              end
              base = n_frames;
              for (int qi = 0; qi < 8; qi++) begin
                `UNI_WAIT_FRAMES(base + 1 + qi)
                chk_data(base + qi, tc_c, cport_m, seq_m + 4'(qi),
                         {qpay[qi], 96'h0}, "crv qof drain");
                `UNI_SEND_ACK(seq_m + 4'(qi))
              end
              seq_m = seq_m + 4'd8;
              `UNI_WAIT_CLK(10)
            end
            default: begin
              // control-FIFO overflow: back-to-back 1-byte data frames
              // (8 syms ~ 80 clk) push ACKs faster than the ~110-clk ctl
              // drain -> the 4-deep cfifo saturates -> e_cof pulse(s)
              n_cof++;
              while (mbuf_m > 0) begin         // start with an empty buffer
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
              // let the TX side go idle so only cfifo traffic competes
              `UNI_WAIT_CLK(200)
              v_irq_seen = 1'b0;
              base = n_frames;
              for (int qi = 0; qi < 30; qi++) begin
                case (qi)
                  10: begin                  // one GET (longer frame)
                    idx4 = 4'($urandom_range(0, 15));
                    pay128 = {8'd0, {4'h0, idx4}, 8'h00, 104'h0};
                    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
                  end
                  12: begin                  // one SET
                    idx4 = 4'($urandom_range(0, 15));
                    val8 = 8'($urandom_range(0, 255));
                    pay128 = {8'd1, {4'h0, idx4}, val8, 104'h0};
                    `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
                    attr_m[idx4] = val8;
                  end
                  14: begin                  // one duplicate
                    pay128 = {8'h55, 120'h0};
                    `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m - 4'd1, pay128, 1, 1'b0)
                  end
                  16: begin                  // one out-of-seq
                    pay128 = {8'h55, 120'h0};
                    `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m + 4'd3, pay128, 1, 1'b0)
                  end
                  default: begin             // fast 1-byte data accept
                    pay128 = {8'h55, 120'h0};
                    `UNI_SEND_FRAME(1'b0, 4'h0, eseq_m, pay128, 1, 1'b0)
                    eseq_m = eseq_m + 4'd1;
                    mbuf_m = mbuf_m + 1;
                  end
                endcase
              end
              `UNI_WAIT_CLK(2000)              // let the cfifo drain out
              if (!v_irq_seen) begin
                errors++;
                $display("ERROR: CRV cfifo overflow: no e_cof irq");
              end
              if (n_frames < base + 4) begin
                errors++;
                $display("ERROR: CRV cfifo overflow: only %0d responses",
                         n_frames - base);
              end
              while (mbuf_m > 0) begin         // pop the accepted byte
                `UNI_CPU_RD(3'd4, rd)
                mbuf_m = mbuf_m - 1;
              end
              `UNI_WAIT_CLK(50)
            end
          endcase
          eroll = (eroll + 1) % 8;
        end
      end
      // ---- attribute toggle sweep + cpu-PACP readback -------------------
      // 0xFF then 0x00 into each attribute (peer SET, SET_RSP self-checked)
      // then cpu-PACP GET per index (response frame + csr value checked).
      for (int i = 0; i < 16; i++) begin
        for (int v = 0; v < 2; v++) begin
          val8 = (v == 0) ? 8'h00 : 8'hFF;
          base = n_frames;
          pay128 = {8'd1, 8'(i), val8, 104'h0};
          `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
          `UNI_WAIT_FRAMES(base + 1)
          chk_ctl(base, 8'd3, 8'(i), 8'h00, "crv attr sweep setcnf");
          attr_m[4'(i)] = val8;
        end
        // cpu-initiated GET of the same index
        `UNI_CPU_WR(3'd3, {28'h0, 4'(i)})
        base = n_frames;
        `UNI_WAIT_FRAMES(base + 1)
        chk_ctl(base, 8'd0, 8'(i), 8'h00, "crv attr sweep cpu get req");
        pay128 = {8'd2, 8'(i), attr_m[4'(i)], 104'h0};
        `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
        `UNI_WAIT_CLK(30)
        `UNI_CPU_RD(3'd6, rd)
        if (rd[8] !== 1'b1 || rd[7:0] !== attr_m[4'(i)]) begin
          errors++;
          $display("ERROR: CRV attr sweep readback idx=%0d rd=%h exp=%h",
                   i, rd, attr_m[4'(i)]);
        end
      end
      // GET tail: GETRSPs with 0xFF/0x00 arg2 through the cfifo
      for (int i = 0; i < 8; i++) begin
        base = n_frames;
        pay128 = {8'd0, 8'(i), 8'h00, 104'h0};
        `UNI_SEND_FRAME(1'b0, 4'hF, 4'h0, pay128, 3, 1'b0)
        `UNI_WAIT_FRAMES(base + 1)
        chk_ctl(base, 8'd2, 8'(i), attr_m[4'(i)], "crv attr get tail");
      end
      $display("CRV: 126 txns + sweeps (push=%0d uplink=%0d ppacp=%0d cpacp=%0d | badcrc=%0d oos=%0d dup=%0d retx=%0d mof=%0d frm=%0d qof=%0d cof=%0d)",
               n_push, n_up, n_ppacp, n_cpacp,
               n_bcrc, n_oos, n_dup, n_retx, n_mof, n_frm, n_qof, n_cof);
    end
  `undef UNI_SEND_SYM
  `undef UNI_SEND_FRAME
  `undef UNI_SEND_ACK
  `undef UNI_SEND_NAC
  `undef UNI_CPU_WR
  `undef UNI_CPU_RD
  `undef UNI_WAIT_FRAMES
  `undef UNI_WAIT_CLK

`else
    // CHECK 1: reset state
    if (tx_bit !== 1'b1 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: UniPro reset state tx_bit=%b irq=%b", tx_bit, irq);
    end
    rst_n = 1; repeat (2) @(posedge clk);
    cpu_rd(3'd5, rd);
    if (rd[13:0] !== 14'h0) begin
      errors++;
      $display("ERROR: UniPro reset status=%h exp 0", rd);
    end

    // CHECK 2: single TC0 data frame + ACK
    cpu_wr(3'd0, 32'h1111_1111);
    p = {32'h1111_1111, 96'h0};
    expect_data(1'b0, 4'h0, 4'h0, p, "tc0 data frame seq0");
    send_ack(4'h0);
    repeat (20) @(posedge clk);
    cpu_rd(3'd5, rd);
    if (rd[3:0] !== 4'h0) begin
      errors++;
      $display("ERROR: UniPro q0 not drained after ACK status=%h", rd);
    end

    // CHECK 3: TC1 strict priority over TC0
    cpu_wr(3'd0, 32'hAAAA_0001);           // A -> TC0, sent first
    p = {32'hAAAA_0001, 96'h0};
    expect_data(1'b0, 4'h0, 4'h1, p, "tc0 frame A seq1");
    cpu_wr(3'd0, 32'hBBBB_0002);           // B -> TC0 (queued behind A)
    cpu_wr(3'd1, 32'hCCCC_0003);           // C -> TC1
    send_ack(4'h1);                        // release A; C must win next slot
    p = {32'hCCCC_0003, 96'h0};
    expect_data(1'b1, 4'h0, 4'h2, p, "tc1 frame C seq2 (priority)");
    send_ack(4'h2);
    p = {32'hBBBB_0002, 96'h0};
    expect_data(1'b0, 4'h0, 4'h3, p, "tc0 frame B seq3");
    send_ack(4'h3);
    repeat (20) @(posedge clk);

    // CHECK 4: NAC retransmit <=3 then drop + irq
    cpu_wr(3'd0, 32'hDDDD_0004);
    p = {32'hDDDD_0004, 96'h0};
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D seq4 orig");
    send_nac(4'h4);
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D retransmit 1");
    send_nac(4'h4);
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D retransmit 2");
    send_nac(4'h4);
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D retransmit 3");
    // 4th NAC: budget exhausted -> drop + irq, no more retransmission
    irq_seen = 0; fr_seen = 0;
    fork
      begin
        repeat (1500) begin
          @(posedge clk);
          if (irq) irq_seen = 1;
          if (dut.ser_busy) fr_seen = 1;
        end
      end
      send_nac(4'h4);
    join
    if (!irq_seen) begin
      errors++;
      $display("ERROR: UniPro NAC exhausted: no irq pulse");
    end
    if (fr_seen) begin
      errors++;
      $display("ERROR: UniPro NAC exhausted: frame retransmitted >3 times");
    end
    cpu_rd(3'd5, rd);
    if (rd[3:0] !== 4'h0) begin
      errors++;
      $display("ERROR: UniPro dropped frame still queued status=%h", rd);
    end

    // CHECK 5: CPort0 uplink incl. escaped bytes (7E, 9D), duplicate, out-of-seq
    p = {8'h7E, 8'h9D, 8'h00, 8'hFF, 96'h0};
    send_frame(1'b0, 4'h0, 4'h0, p, 4, 1'b0);   // peer seq0 -> DUT exp_seq0
    expect_ctl(CC_ACK, 8'h00, 8'h00, "uplink ACK seq0");
    cpu_rd(3'd5, rd);
    if (rd[13:8] !== 6'd4) begin
      errors++;
      $display("ERROR: UniPro msg count=%0d exp 4", rd[13:8]);
    end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h7E) begin errors++; $display("ERROR: UniPro msg[0]=%h exp 7E", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h9D) begin errors++; $display("ERROR: UniPro msg[1]=%h exp 9D", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h00) begin errors++; $display("ERROR: UniPro msg[2]=%h exp 00", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'hFF) begin errors++; $display("ERROR: UniPro msg[3]=%h exp FF", rd[7:0]); end
    // duplicate seq0: ACK again, no re-accept
    send_frame(1'b0, 4'h0, 4'h0, p, 4, 1'b0);
    expect_ctl(CC_ACK, 8'h00, 8'h00, "duplicate ACK seq0");
    cpu_rd(3'd5, rd);
    if (rd[13:8] !== 6'd0) begin
      errors++;
      $display("ERROR: UniPro duplicate accepted msg_cnt=%0d", rd[13:8]);
    end
    // out-of-sequence: expect NAC with exp_seq=1
    p = {32'h5555_0005, 96'h0};
    send_frame(1'b0, 4'h0, 4'h5, p, 4, 1'b0);
    expect_ctl(CC_NAC, 8'h01, 8'h00, "out-of-seq NAC");

    // CHECK 6: PACP both directions
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_SET, 8'h03, 8'h5A, 104'h0}, 3, 1'b0);
    expect_ctl(CC_SETCNF, 8'h03, 8'h00, "PACP set cnf");
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_GET, 8'h03, 8'h00, 104'h0}, 3, 1'b0);
    expect_ctl(CC_GETRSP, 8'h03, 8'h5A, "PACP get rsp");
    // DUT-initiated: cpu PACP SET idx=5 val=A5
    cpu_wr(3'd2, {16'h0, 8'hA5, 4'h0, 4'h5});
    expect_ctl(CC_SET, 8'h05, 8'hA5, "PACP cpu set req");
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_SETCNF, 8'h05, 8'h00, 104'h0}, 3, 1'b0);
    repeat (30) @(posedge clk);
    cpu_rd(3'd6, rd);
    if (rd[9] !== 1'b1) begin
      errors++;
      $display("ERROR: UniPro pacp_cnf not set rd=%h", rd);
    end
    // DUT-initiated: cpu PACP GET idx=5
    cpu_wr(3'd3, {28'h0, 4'h5});
    expect_ctl(CC_GET, 8'h05, 8'h00, "PACP cpu get req");
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_GETRSP, 8'h05, 8'hA5, 104'h0}, 3, 1'b0);
    repeat (30) @(posedge clk);
    cpu_rd(3'd6, rd);
    if (rd[8] !== 1'b1 || rd[7:0] !== 8'hA5) begin
      errors++;
      $display("ERROR: UniPro pacp_rsp rd=%h exp valid+A5", rd);
    end

    // CHECK 7: error injection - bad CRC data frame dropped + irq
    irq_seen = 0; fr_seen = 0;
    fork
      begin
        repeat (1200) begin
          @(posedge clk);
          if (irq) irq_seen = 1;
          if (dut.ser_busy) fr_seen = 1;
        end
      end
      begin
        p = {32'hBAD0_0001, 96'h0};
        send_frame(1'b0, 4'h0, 4'h1, p, 4, 1'b1);   // corrupted CRC
      end
    join
    if (!irq_seen) begin
      errors++;
      $display("ERROR: UniPro bad-CRC frame: no irq pulse");
    end
    if (fr_seen) begin
      errors++;
      $display("ERROR: UniPro bad-CRC frame: DUT responded");
    end

    // recovery: valid seq1 frame still accepted
    p = {32'h600D_0001, 96'h0};
    send_frame(1'b0, 4'h0, 4'h1, p, 4, 1'b0);
    expect_ctl(CC_ACK, 8'h01, 8'h00, "recovery ACK seq1");
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h60) begin errors++; $display("ERROR: UniPro recovery msg[0]=%h exp 60", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h0D) begin errors++; $display("ERROR: UniPro recovery msg[1]=%h exp 0D", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h00) begin errors++; $display("ERROR: UniPro recovery msg[2]=%h exp 00", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h01) begin errors++; $display("ERROR: UniPro recovery msg[3]=%h exp 01", rd[7:0]); end

    repeat (20) @(posedge clk);
`endif
    if (errors == 0) $display("TEST PASSED: UniPro");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < UNI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, UNI_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (20000) #1000;   // 20 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #5_000_000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
