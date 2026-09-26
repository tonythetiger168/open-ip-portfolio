// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UniPro_Mem_top testbench -- peer endpoint model driving the UniPro symbol
// link (ESC/COF framing, CRC16) and checking the memory-mapped transaction
// layer, QoS arbitration, read timeout, PACP attributes, NAC retransmission
// and error/irq behaviour.
// ============================================================================
`timescale 1ns/1ps
module UniPro_Mem_tb;

  localparam logic [7:0] SYM_ESC = 8'h9D;
  localparam logic [7:0] SYM_COF = 8'hC0;
  localparam logic [7:0] ESC_XOR = 8'h20;

  logic       clk = 1'b0;
  logic       rst_n = 1'b0;
  logic [7:0] rx_sym = 8'h00;
  logic       rx_valid = 1'b0;
  logic [7:0] tx_sym;
  logic       tx_valid;
  logic       tx_ready = 1'b1;
  logic       irq;

  integer errors = 0;

  UniPro_Mem_top dut (
    .clk(clk), .rst_n(rst_n),
    .rx_sym(rx_sym), .rx_valid(rx_valid),
    .tx_sym(tx_sym), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // CRC-16/CCITT-FALSE (independent reference)
  // ------------------------------------------------------------------
  function automatic logic [15:0] crc16b(input logic [15:0] crc,
                                         input logic [7:0] d);
    logic [15:0] c;
    begin
      c = crc ^ {d, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      return c;
    end
  endfunction

  // ------------------------------------------------------------------
  // RX (DUT->TB) frame monitor, samples on negedge
  // ------------------------------------------------------------------
  integer      m_state = 0;
  integer      m_cnt = 0;
  integer      m_total = 31;
  logic        m_esc = 1'b0;
  logic [7:0]  m_buf [0:31];
  logic [7:0]  fr_pay  [0:63][0:15];
  logic        fr_tc   [0:63];
  logic [3:0]  fr_cport[0:63];
  logic [3:0]  fr_seq  [0:63];
  logic [7:0]  fr_len  [0:63];
  integer      n_frames = 0;

  logic [7:0]  d;
  logic [15:0] crc;
  integer      ii;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int UPM_FSM_TOTAL = 6; // RX: R_IDLE..R_DISCARD, TX: T_IDLE/T_RUN
  logic [5:0] fsm_seen = '0;        // visited-state bitmap
  wire  [1:0] dut_rxs = dut.rxs;    // hierarchical FSM probes
  wire        dut_txs = dut.txs;

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
    fsm_seen[dut_rxs]       <= 1'b1;
    fsm_seen[4 + dut_txs]   <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit  first_cycle = 1; // skip the first posedge (DUT reset values land
                        // in that NBA region)
  logic irq_q = 1'b0;
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(tx_valid === 1'b0 && irq === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: tx_valid exactly while the TX engine runs a frame
      sva_check(tx_valid === (dut_txs == 1'b1), "A2 tx_valid mirrors txs");
      // A3: irq is a one-cycle event pulse
      sva_check(!(irq === 1'b1 && irq_q === 1'b1), "A3 irq is a pulse");
      // A4: read-response timeout counters within the 100-clk bound
      sva_check(dut.q0_timer <= 8'd100 && dut.q1_timer <= 8'd100,
                "A4 timers within bound");
      // A5: byte counters within the frame envelope
      sva_check(dut.bcnt <= 5'd21 && dut.t_cnt <= 5'd22,
                "A5 counters within bounds");
      // A6: retransmit budget counter within 0..3
      sva_check(dut.rb_retry <= 2'd3, "A6 rb_retry within budget");
      // A7: escape phase always carries the ESC symbol on the wire
      sva_check(!dut.t_esc || tx_sym === 8'h9D, "A7 esc phase carries ESC");
      // A8: queued response frames carry legal lengths (2..16)
      sva_check((!dut.q0_valid || (dut.q0_len >= 8'd2 && dut.q0_len <= 8'd16)) &&
                (!dut.q1_valid || (dut.q1_len >= 8'd2 && dut.q1_len <= 8'd16)),
                "A8 queued frame lengths legal");
    end
    irq_q <= irq;
  end

  // ---- inlined stimulus macros for the random phase -------------------
  // (same Verilator 5.006 scheduler rationale as the I2C pilot: chained
  // timing-task coroutines can lose wakeups after ~2k awaits, so the
  // random phase runs as ONE coroutine with plain awaits only)
  `define UPM_SEND_SYM(s) \
    @(negedge clk); rx_sym = (s); rx_valid = 1'b1; \
    @(negedge clk); rx_valid = 1'b0;
  `define UPM_SEND_FRAME(ftc, fcport, fseq, fpay, fplen, fbad) \
    begin \
      sf_fb[0] = {3'b000, ftc, fcport}; \
      sf_fb[1] = {4'h0, fseq}; \
      sf_fb[2] = fplen; \
      for (sf_i = 0; sf_i < 16; sf_i = sf_i + 1) \
        sf_fb[3+sf_i] = fpay[127-8*sf_i -: 8]; \
      sf_c = 16'hFFFF; \
      for (sf_i = 0; sf_i < 19; sf_i = sf_i + 1) \
        if (sf_i < 3 + fplen) sf_c = crc16b(sf_c, sf_fb[sf_i]); \
      if (fbad) sf_c = sf_c ^ 16'h5A5A; \
      sf_fb[3+fplen] = sf_c[15:8]; \
      sf_fb[4+fplen] = sf_c[7:0]; \
      `UPM_SEND_SYM(8'h9D) \
      `UPM_SEND_SYM(8'hC0) \
      for (sf_i = 0; sf_i < 21; sf_i = sf_i + 1) begin \
        if (sf_i < 5 + fplen) begin \
          sf_b = sf_fb[sf_i]; \
          if ((sf_b == 8'h9D) || (sf_b == 8'hC0)) begin \
            `UPM_SEND_SYM(8'h9D) \
            `UPM_SEND_SYM(sf_b ^ 8'h20) \
          end else begin \
            `UPM_SEND_SYM(sf_b) \
          end \
        end \
      end \
    end
  `define UPM_WAIT_FRAMES(n) \
    begin \
      wf_to = 0; \
      while ((n_frames < (n)) && (wf_to < 40000)) begin \
        @(posedge clk); wf_to = wf_to + 1; \
      end \
      if (n_frames < (n)) begin \
        errors = errors + 1; \
        $display("ERROR: CRV timeout waiting frame count %0d (have %0d)", \
                 (n), n_frames); \
      end \
    end
  `define UPM_WAIT_CLK(n) \
    begin \
      for (wf_to = 0; wf_to < (n); wf_to = wf_to + 1) @(posedge clk); \
    end
`endif

  always @(negedge clk) begin
    if (tx_valid && tx_ready) begin
      case (m_state)
        0: if (tx_sym == SYM_ESC) m_state = 1;
        1: begin
          if (tx_sym == SYM_COF) begin m_state = 2; m_cnt = 0; m_esc = 1'b0; m_total = 31; end
          else if (tx_sym != SYM_ESC) m_state = 0;
        end
        default: begin // 2: in frame
          if (!m_esc && (tx_sym == SYM_ESC)) m_esc = 1'b1;
          else if (m_esc && (tx_sym == SYM_COF)) begin
            m_state = 2; m_cnt = 0; m_esc = 1'b0; m_total = 31; // restart
          end else begin
            d = m_esc ? (tx_sym ^ ESC_XOR) : tx_sym;
            m_esc = 1'b0;
            m_buf[m_cnt] = d;
            if (m_cnt == 2) m_total = d + 5;
            if ((m_cnt >= 4) && (m_cnt == m_total - 1)) begin
              // frame complete: verify CRC
              crc = 16'hFFFF;
              for (ii = 0; ii < 19; ii = ii + 1)
                if (ii < m_total - 2) crc = crc16b(crc, m_buf[ii]);
              if ({m_buf[m_total-2], m_buf[m_total-1]} !== crc) begin
                errors = errors + 1;
                $display("ERROR: DUT frame %0d has bad CRC (got %04h exp %04h)",
                         n_frames, {m_buf[m_total-2], m_buf[m_total-1]}, crc);
              end
              if (n_frames < 256) begin
                fr_tc[n_frames]    = m_buf[0][4];
                fr_cport[n_frames] = m_buf[0][3:0];
                fr_seq[n_frames]   = m_buf[1][3:0];
                fr_len[n_frames]   = m_buf[2];
                for (ii = 0; ii < 16; ii = ii + 1)
                  fr_pay[n_frames][ii] = (ii < m_buf[2]) ? m_buf[3+ii] : 8'h00;
                n_frames = n_frames + 1;
              end
              m_state = 0;
            end
            m_cnt = m_cnt + 1;
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // irq capture
  // ------------------------------------------------------------------
  logic irq_seen = 1'b0;
  always @(posedge clk) if (irq) irq_seen = 1'b1;

  // ------------------------------------------------------------------
  // stimulus tasks
  // ------------------------------------------------------------------
  task automatic send_sym(input logic [7:0] s);
    begin
      @(negedge clk); rx_sym = s; rx_valid = 1'b1;
      @(negedge clk); rx_valid = 1'b0;
    end
  endtask

  task automatic send_frame(input logic        tc,
                            input logic [3:0]  cport,
                            input logic [3:0]  seq,
                            input logic [127:0] pay,
                            input logic [7:0]  plen,
                            input logic        bad_crc);
    logic [7:0]  fb [0:20];   // v2.5: was [0:18]; CRC bytes fb[19]/fb[20]
                              // were out-of-bounds (silently x in iverilog,
                              // 0 under Verilator -> bad-CRC drops)
    logic [15:0] c;
    logic [7:0]  b;
    begin
      fb[0] = {3'b000, tc, cport};
      fb[1] = {4'h0, seq};
      fb[2] = plen;
      for (int i = 0; i < 16; i = i + 1) fb[3+i] = pay[127-8*i -: 8];
      c = 16'hFFFF;
      for (int i = 0; i < 19; i = i + 1)
        if (i < 3 + plen) c = crc16b(c, fb[i]);
      if (bad_crc) c = c ^ 16'h5A5A;
      fb[3+plen] = c[15:8];
      fb[4+plen] = c[7:0];
      send_sym(SYM_ESC);
      send_sym(SYM_COF);
      for (int i = 0; i < 21; i = i + 1) begin
        if (i < 5 + plen) begin
          b = fb[i];
          if ((b == SYM_ESC) || (b == SYM_COF)) begin
            send_sym(SYM_ESC);
            send_sym(b ^ ESC_XOR);
          end else send_sym(b);
        end
      end
    end
  endtask

  task automatic wait_frames(input integer n);
    integer t;
    begin
      t = 0;
      while ((n_frames < n) && (t < 20000)) begin @(posedge clk); t = t + 1; end
      if (n_frames < n) begin
        errors = errors + 1;
        $display("ERROR: timeout waiting for frame count %0d (have %0d)", n, n_frames);
      end
    end
  endtask

  task automatic check_frame(input integer      idx,
                             input logic        e_tc,
                             input logic [3:0]  e_cport,
                             input logic [7:0]  e_len,
                             input logic [127:0] e_pay,
                             input string       tag);
    begin
      if (fr_tc[idx] !== e_tc) begin
        errors = errors + 1;
        $display("ERROR: %s frame %0d tc=%0d exp %0d", tag, idx, fr_tc[idx], e_tc);
      end
      if (fr_cport[idx] !== e_cport) begin
        errors = errors + 1;
        $display("ERROR: %s frame %0d cport=%h exp %h", tag, idx, fr_cport[idx], e_cport);
      end
      if (fr_len[idx] !== e_len) begin
        errors = errors + 1;
        $display("ERROR: %s frame %0d len=%h exp %h", tag, idx, fr_len[idx], e_len);
      end
      for (int i = 0; i < 16; i = i + 1)
        if (i < e_len)
          if (fr_pay[idx][i] !== e_pay[127-8*i -: 8]) begin
            errors = errors + 1;
            $display("ERROR: %s frame %0d pay[%0d]=%h exp %h", tag, idx, i,
                     fr_pay[idx][i], e_pay[127-8*i -: 8]);
          end
    end
  endtask

  task automatic wait_clk(input integer n);
    integer t;
    begin for (t = 0; t < n; t = t + 1) @(posedge clk); end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [3:0] nac_seq;
  integer     base;

  initial begin
    // ---- 1. reset state ----
    rst_n = 1'b0;
    wait_clk(10);
    rst_n = 1'b1;
    wait_clk(5);
    if (tx_valid !== 1'b0) begin
      errors = errors + 1; $display("ERROR: tx_valid not low after reset");
    end
    if (irq !== 1'b0) begin
      errors = errors + 1; $display("ERROR: irq not low after reset");
    end
    $display("check 1: reset state done");

    // ---- 2. PACP attribute set/get roundtrip (consecutive transactions) ----
    send_frame(1'b0, 4'hF, 4'h0, {8'h11, 8'h03, 8'hA5, 104'h0}, 8'd3, 1'b0); // set attr3=A5
    wait_frames(1);
    check_frame(0, 1'b0, 4'hF, 8'd3, {8'h91, 8'h03, 8'hA5, 104'h0}, "pacp_set");
    send_frame(1'b0, 4'hF, 4'h1, {8'h10, 8'h03, 112'h0}, 8'd2, 1'b0);         // get attr3
    wait_frames(2);
    check_frame(1, 1'b0, 4'hF, 8'd3, {8'h90, 8'h03, 8'hA5, 104'h0}, "pacp_get");
    $display("check 2: PACP set/get done");

    // ---- 3. memory write (TC0) + read back, full data compare ----
    send_frame(1'b0, 4'h1, 4'h2,
               {8'h01, 8'h00, 8'h10, 8'h0C,
                8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h01, 8'h23, 8'h45, 8'h67,
                8'h89, 8'hAB, 8'hCD, 8'hEF}, 8'd16, 1'b0);
    wait_frames(3);
    check_frame(2, 1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h10, 8'h0C, 8'h00, 88'h0},
                "mem_wr_ack");
    send_frame(1'b0, 4'h1, 4'h3, {8'h02, 8'h00, 8'h10, 8'h0C, 96'h0}, 8'd4, 1'b0);
    wait_frames(4);
    check_frame(3, 1'b0, 4'h1, 8'd16,
                {8'h82, 8'h00, 8'h10, 8'h0C,
                 8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h01, 8'h23, 8'h45, 8'h67,
                 8'h89, 8'hAB, 8'hCD, 8'hEF}, "mem_rd");
    $display("check 3: memory write/read roundtrip done");

    // ---- 4. QoS: TC1 must overtake queued TC0 under TX backpressure ----
    @(negedge clk); tx_ready = 1'b0;
    send_frame(1'b0, 4'h1, 4'h4, {8'h01, 8'h00, 8'h20, 8'h04,
               8'hAA, 8'hAA, 8'hAA, 8'hAA, 64'h0}, 8'd8, 1'b0);  // blocker (preloaded)
    send_frame(1'b0, 4'h1, 4'h5, {8'h01, 8'h00, 8'h24, 8'h04,
               8'hBB, 8'hBB, 8'hBB, 8'hBB, 64'h0}, 8'd8, 1'b0);  // queued in TC0
    send_frame(1'b1, 4'h1, 4'h6, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0); // queued TC1
    base = n_frames;
    wait_clk(30);
    if (n_frames != base) begin
      errors = errors + 1; $display("ERROR: frames emitted while tx_ready low");
    end
    @(negedge clk); tx_ready = 1'b1;
    wait_frames(base + 3);
    // order: preloaded TC0 ack, then TC1 read rsp, then queued TC0 ack
    check_frame(base,   1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h20, 8'h04, 8'h00, 88'h0},
                "qos_first");
    check_frame(base+1, 1'b1, 4'h1, 8'd8, {8'h82, 8'h00, 8'h10, 8'h04,
                8'hDE, 8'hAD, 8'hBE, 8'hEF, 64'h0}, "qos_tc1_first");
    check_frame(base+2, 1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h24, 8'h04, 8'h00, 88'h0},
                "qos_tc0_last");
    if (fr_tc[base+1] !== 1'b1) begin
      errors = errors + 1; $display("ERROR: QoS violated, TC1 did not overtake TC0");
    end
    $display("check 4: QoS TC1-over-TC0 done");

    // ---- 5. read timeout: stalled TX > 100 clk -> error frame, no data ----
    wait_clk(20);
    @(negedge clk); tx_ready = 1'b0;
    send_frame(1'b0, 4'h1, 4'h7, {8'h01, 8'h00, 8'h28, 8'h04,
               8'hCC, 8'hCC, 8'hCC, 8'hCC, 64'h0}, 8'd8, 1'b0);  // blocker
    send_frame(1'b1, 4'h1, 4'h8, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0); // read
    base = n_frames;
    wait_clk(150);                       // > 100 clk timeout
    @(negedge clk); tx_ready = 1'b1;
    wait_frames(base + 2);
    check_frame(base,   1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h28, 8'h04, 8'h00, 88'h0},
                "to_blocker");
    check_frame(base+1, 1'b1, 4'h1, 8'd2, {8'hE0, 8'h01, 112'h0}, "to_err");
    $display("check 5: read timeout error frame done");

    // ---- 6. CRC error injection: irq + frame dropped ----
    irq_seen = 1'b0;
    base = n_frames;
    send_frame(1'b0, 4'hF, 4'h9, {8'h10, 8'h03, 112'h0}, 8'd2, 1'b1); // bad CRC
    wait_clk(30);
    if (!irq_seen) begin
      errors = errors + 1; $display("ERROR: no irq on CRC error");
    end
    if (n_frames != base) begin
      errors = errors + 1; $display("ERROR: response sent for bad-CRC frame");
    end
    $display("check 6: CRC error injection done");

    // ---- 7. out-of-bounds + invalid length: error frames + irq ----
    irq_seen = 1'b0;
    send_frame(1'b0, 4'h1, 4'hA, {8'h01, 8'h00, 8'hFC, 8'h0C,
               8'h11, 8'h22, 8'h33, 8'h44, 8'h55, 8'h66, 8'h77, 8'h88,
               8'h99, 8'hAA, 8'hBB, 8'hCC}, 8'd16, 1'b0); // 0xFC+12 > 256
    wait_frames(base + 1);
    check_frame(base, 1'b0, 4'h1, 8'd2, {8'hE0, 8'h02, 112'h0}, "oob_wr");
    if (!irq_seen) begin
      errors = errors + 1; $display("ERROR: no irq on out-of-bounds write");
    end
    // memory at 0xFC must be untouched (reset 0)
    send_frame(1'b0, 4'h1, 4'hB, {8'h02, 8'h00, 8'hFC, 8'h04, 96'h0}, 8'd4, 1'b0);
    wait_frames(base + 2);
    check_frame(base+1, 1'b0, 4'h1, 8'd8, {8'h82, 8'h00, 8'hFC, 8'h04,
                8'h00, 8'h00, 8'h00, 8'h00, 64'h0}, "oob_untouched");
    irq_seen = 1'b0;
    send_frame(1'b0, 4'h1, 4'hC, {8'h01, 8'h00, 8'h30, 8'h05,
               8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 56'h0}, 8'd9, 1'b0); // len=5 invalid
    wait_frames(base + 3);
    check_frame(base+2, 1'b0, 4'h1, 8'd2, {8'hE0, 8'h02, 112'h0}, "badlen");
    if (!irq_seen) begin
      errors = errors + 1; $display("ERROR: no irq on invalid length");
    end
    $display("check 7: out-of-bounds / invalid length done");

    // ---- 8. NAC retransmission: <=3 retries then exhausted irq ----
    send_frame(1'b1, 4'h1, 4'hD, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0);
    wait_frames(base + 4);
    check_frame(base+3, 1'b1, 4'h1, 8'd8, {8'h82, 8'h00, 8'h10, 8'h04,
                8'hDE, 8'hAD, 8'hBE, 8'hEF, 64'h0}, "nac_orig");
    nac_seq = fr_seq[base+3];
    // NAC #1..#3 -> identical retransmissions
    for (int r = 1; r <= 3; r = r + 1) begin
      send_frame(1'b0, 4'hF, 4'h0, {8'h20, 4'h0, nac_seq, 112'h0}, 8'd2, 1'b0);
      wait_frames(base + 4 + r);
      check_frame(base+3+r, 1'b1, 4'h1, 8'd8, {8'h82, 8'h00, 8'h10, 8'h04,
                  8'hDE, 8'hAD, 8'hBE, 8'hEF, 64'h0}, "nac_retx");
      if (fr_seq[base+3+r] !== nac_seq) begin
        errors = errors + 1;
        $display("ERROR: retx %0d seq=%h exp %h", r, fr_seq[base+3+r], nac_seq);
      end
    end
    // NAC #4 -> retransmit budget exhausted: irq, no frame
    irq_seen = 1'b0;
    send_frame(1'b0, 4'hF, 4'h0, {8'h20, 4'h0, nac_seq, 112'h0}, 8'd2, 1'b0);
    wait_clk(40);
    if (!irq_seen) begin
      errors = errors + 1; $display("ERROR: no irq on NAC retransmit exhausted");
    end
    if (n_frames != base + 7) begin
      errors = errors + 1;
      $display("ERROR: unexpected frame after NAC exhausted (n=%0d exp %0d)",
               n_frames, base + 7);
    end
    $display("check 8: NAC retransmit/exhausted done");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 126 randomized transactions, single coroutine, fully inlined via the
    // macros above; DUT->TB frames go through the (already passive) negedge
    // monitor and are checked post-hoc against a TB memory/attribute model.
    // Normal class (~2/3): memory writes (len 4/8/12, random aligned
    // address incl. 0x00/0xFC boundary, random data incl. all-0/all-1),
    // memory reads verified against the model, PACP set/get roundtrips.
    // Error classes (round-robin selector, all parameters randomized):
    //   0 bad-CRC frame (dropped + irq) then NAC with unknown seq (ignored)
    //   1 out-of-bounds / misaligned / bad-length / len-mismatch WRITE
    //   2 out-of-bounds / misaligned / bad-length / len-mismatch READ
    //   3 unknown opcode / short CPort1 / unknown CPort / unknown PACP op
    //   4 PACP attribute index >= 16 (irq + ERR_OOB), set and get
    //   5 oversized frame (len > 16 -> R_DISCARD, resync on next frame)
    //   6 TC0 read-response timeout (tx_ready stall > 100 clk -> ERR frame)
    begin : crv_phase
      int n_rw = 0, n_pacp = 0, n_bcrc = 0, n_owr = 0, n_ord = 0;
      int n_bop = 0, n_paob = 0, n_ovsz = 0, n_rto = 0;
      int roll, roll2, eroll = 0, wf_to, sf_i;
      int wa, nw, nb;
      logic [7:0]  sf_fb [0:20];
      logic [15:0] sf_c;
      logic [7:0]  sf_b;
      logic [127:0] pay128, exp128;
      logic [7:0]  addr8, len8, idx8, val8, op8, cport8;
      logic        tc_c;
      logic [3:0]  seq_c;
      logic [31:0] mem_model [0:63];
      logic [7:0]  attr_model [0:15];
      logic [31:0] dw;
      for (int i = 0; i < 64; i++) mem_model[i] = 32'h0;
      for (int i = 0; i < 16; i++) attr_model[i] = 8'h00;
      attr_model[3] = 8'hA5;              // directed check 2 set attr3
      // directed-phase memory writes (checks 3/4/5)
      mem_model[4]  = 32'hDEAD_BEEF;      // check 3 write @0x10
      mem_model[5]  = 32'h0123_4567;
      mem_model[6]  = 32'h89AB_CDEF;
      mem_model[8]  = 32'hAAAA_AAAA;      // check 4 blocker @0x20
      mem_model[9]  = 32'hBBBB_BBBB;      // check 4 queued  @0x24
      mem_model[10] = 32'hCCCC_CCCC;      // check 5 blocker @0x28
      seq_c = 4'hA;                       // directed used seq 0..9 region
      for (int t = 0; t < 126; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 20) begin
          // ---- normal: mem write / mem read / PACP roundtrip ----
          roll2 = $urandom_range(0, 19);
          tc_c = ($urandom_range(0, 1) == 1);
          seq_c = seq_c + 4'd1;
          if (roll2 < 9) begin
            // memory write, then model update
            n_rw++;
            nw = 1 + $urandom_range(0, 2);          // 1..3 words
            nb = 4 * nw;
            wa = $urandom_range(0, 63 - (nw - 1));
            if (t == 0) wa = 0;                     // boundary: base
            if (t == 1) wa = 64 - nw;               // boundary: top
            addr8 = 8'(wa * 4);
            len8  = 8'(nb);
            pay128 = {8'h01, 8'h00, addr8, len8, 96'h0};
            for (int w = 0; w < 3; w++) begin
              if (w < nw) begin
                roll = $urandom_range(0, 9);
                dw = (roll == 0) ? 32'h0000_0000 :
                     (roll == 1) ? 32'hFFFF_FFFF : $urandom;
                mem_model[wa + w] = dw;
                pay128[127-32-32*w -: 32] = dw;
              end
            end
            base = n_frames;
            `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'(4 + nb), 1'b0)
            `UPM_WAIT_FRAMES(base + 1)
            exp128 = {8'h81, 8'h00, addr8, len8, 8'h00, 88'h0};
            check_frame(base, tc_c, 4'h1, 8'd5, exp128, "crv_mem_wr");
            if (irq !== 1'b0) begin
              errors = errors + 1; $display("ERROR: CRV irq on clean write");
            end
          end else if (roll2 < 17) begin
            // memory read, verified against the model
            n_rw++;
            nw = 1 + $urandom_range(0, 2);
            nb = 4 * nw;
            wa = $urandom_range(0, 61);   // mem[wa+2] must stay in bounds
            addr8 = 8'(wa * 4);
            len8  = 8'(nb);
            pay128 = {8'h02, 8'h00, addr8, len8, 96'h0};
            base = n_frames;
            `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd4, 1'b0)
            `UPM_WAIT_FRAMES(base + 1)
            exp128 = {8'h82, 8'h00, addr8, len8,
                      mem_model[wa], mem_model[wa+1], mem_model[wa+2]};
            check_frame(base, tc_c, 4'h1, 8'(4 + nb), exp128, "crv_mem_rd");
            if (irq !== 1'b0) begin
              errors = errors + 1; $display("ERROR: CRV irq on clean read");
            end
          end else begin
            // PACP set/get roundtrip
            n_pacp++;
            idx8 = 8'($urandom_range(0, 15));
            val8 = 8'($urandom_range(0, 255));
            base = n_frames;
            pay128 = {8'h11, idx8, val8, 104'h0};
            `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd3, 1'b0)
            `UPM_WAIT_FRAMES(base + 1)
            exp128 = {8'h91, idx8, val8, 104'h0};
            check_frame(base, tc_c, 4'hF, 8'd3, exp128, "crv_pacp_set");
            attr_model[idx8[3:0]] = val8;
            seq_c = seq_c + 4'd1;
            base = n_frames;
            pay128 = {8'h10, idx8, 112'h0};
            `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd2, 1'b0)
            `UPM_WAIT_FRAMES(base + 1)
            exp128 = {8'h90, idx8, attr_model[idx8[3:0]], 104'h0};
            check_frame(base, tc_c, 4'hF, 8'd3, exp128, "crv_pacp_get");
            if (irq !== 1'b0) begin
              errors = errors + 1; $display("ERROR: CRV irq on PACP");
            end
          end
        end else begin
          // ---- error / special classes (round-robin) ----
          tc_c = ($urandom_range(0, 1) == 1);
          seq_c = seq_c + 4'd1;
          case (eroll)
            0: begin
              // bad CRC: dropped + irq; then NAC with unknown seq: ignored
              n_bcrc++;
              base = n_frames;
              irq_seen = 1'b0;
              pay128 = {8'h10, 8'h03, 112'h0};
              `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd2, 1'b1)
              `UPM_WAIT_CLK(30)
              if (!irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV bad CRC: no irq");
              end
              if (n_frames != base) begin
                errors = errors + 1;
                $display("ERROR: CRV bad CRC: response emitted");
              end
              // NAC referencing a seq the retransmit buffer does not hold
              irq_seen = 1'b0;
              pay128 = {8'h20, 4'h0, ~(fr_seq[n_frames-1]), 112'h0};
              `UPM_SEND_FRAME(1'b0, 4'hF, seq_c, pay128, 8'd2, 1'b0)
              `UPM_WAIT_CLK(30)
              if (irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV NAC unknown seq: irq");
              end
              if (n_frames != base) begin
                errors = errors + 1;
                $display("ERROR: CRV NAC unknown seq: response emitted");
              end
            end
            1: begin
              // out-of-bounds / invalid WRITE (4 randomized subtypes)
              n_owr++;
              roll2 = $urandom_range(0, 3);
              nw = 1 + $urandom_range(0, 2);
              nb = 4 * nw;
              wa = $urandom_range(0, 60);
              addr8 = 8'(wa * 4); len8 = 8'(nb);
              pay128 = {8'h01, 8'h00, addr8, len8,
                        32'h1111_2222, 32'h3333_4444, 32'h5555_6666};
              base = n_frames;        // irq pulses during the send itself
              irq_seen = 1'b0;
              case (roll2)
                0: begin // misaligned address
                  pay128[111:104] = addr8 + 8'(1 + $urandom_range(0, 2));
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'(4 + nb), 1'b0)
                end
                1: begin // address + length beyond 256
                  pay128[111:104] = 8'hFC;
                  pay128[103:96]  = (nb == 4) ? 8'h08 : 8'h0C;
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128,
                                  8'(4 + ((nb == 4) ? 8 : 12)), 1'b0)
                end
                2: begin // invalid length value (consistent r_len)
                  pay128[103:96]  = 8'h05;
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd9, 1'b0)
                end
                default: begin // r_len != len + 4 mismatch
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'(4 + nb + 1), 1'b0)
                end
              endcase
              `UPM_WAIT_FRAMES(base + 1)
              exp128 = {8'hE0, 8'h02, 112'h0};
              check_frame(base, tc_c, 4'h1, 8'd2, exp128, "crv_oob_wr");
              if (!irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV OOB write: no irq");
              end
            end
            2: begin
              // out-of-bounds / invalid READ (same 4 subtypes)
              n_ord++;
              roll2 = $urandom_range(0, 3);
              wa = $urandom_range(0, 60);
              addr8 = 8'(wa * 4); len8 = 8'h04;
              pay128 = {8'h02, 8'h00, addr8, len8, 96'h0};
              base = n_frames;        // irq pulses during the send itself
              irq_seen = 1'b0;
              case (roll2)
                0: begin // misaligned address
                  pay128[111:104] = addr8 + 8'(1 + $urandom_range(0, 2));
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd4, 1'b0)
                end
                1: begin // address + length beyond 256
                  pay128[111:104] = 8'hFC;
                  pay128[103:96]  = 8'h08;
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd4, 1'b0)
                end
                2: begin // invalid length value
                  pay128[103:96]  = 8'h05;
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd4, 1'b0)
                end
                default: begin // r_len != 4 mismatch
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd5, 1'b0)
                end
              endcase
              `UPM_WAIT_FRAMES(base + 1)
              exp128 = {8'hE0, 8'h02, 112'h0};
              check_frame(base, tc_c, 4'h1, 8'd2, exp128, "crv_oob_rd");
              if (!irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV OOB read: no irq");
              end
            end
            3: begin
              // unknown opcode / short CPort1 / unknown CPort / unknown PACP
              n_bop++;
              roll2 = n_bop % 4;      // round-robin: every subtype runs
              cport8 = 4'h1; op8 = 8'h01;
              case (roll2)
                0: begin // CPort1 unknown opcode (r_len >= 4)
                  op8 = 8'hF7 ^ 8'(2 * (n_bop % 4));  // unknown, bit7 set
                  pay128 = {op8, 8'h00, 8'h10, 8'h04, 96'h0};
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd4, 1'b0)
                end
                1: begin // CPort1 with r_len < 4
                  pay128 = {8'h01, 8'h00, 112'h0};
                  `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd2, 1'b0)
                end
                2: begin // unknown CPort
                  cport8 = 4'($urandom_range(0, 15));
                  if (cport8 == 4'h1 || cport8 == 4'hF) cport8 = 4'h5; // rej.
                  pay128 = {8'h01, 8'h00, 8'h10, 8'h04, 96'h0};
                  `UPM_SEND_FRAME(tc_c, cport8[3:0], seq_c, pay128, 8'd4, 1'b0)
                end
                default: begin // PACP CPort unknown opcode
                  op8 = 8'($urandom_range(0, 255));
                  if (op8 == 8'h10 || op8 == 8'h11 || op8 == 8'h20)
                    op8 = 8'hF7; // rejection
                  pay128 = {op8, 8'h03, 8'hA5, 104'h0};
                  `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd3, 1'b0)
                end
              endcase
              base = n_frames;
              irq_seen = 1'b0;
              `UPM_WAIT_FRAMES(base + 1)
              exp128 = {8'hE0, 8'h03, 112'h0};
              if (roll2 == 2)
                check_frame(base, tc_c, cport8[3:0], 8'd2, exp128, "crv_badop");
              else if (roll2 == 3)
                check_frame(base, tc_c, 4'hF, 8'd2, exp128, "crv_badop");
              else
                check_frame(base, tc_c, 4'h1, 8'd2, exp128, "crv_badop");
              if (irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV bad-op raised irq");
              end
            end
            4: begin
              // PACP attribute index >= 16 (irq + ERR_OOB), set and get
              n_paob++;
              idx8 = 8'(16 + $urandom_range(0, 15));
              val8 = 8'($urandom_range(0, 255));
              base = n_frames;
              irq_seen = 1'b0;
              if (n_paob % 2 == 1) begin
                pay128 = {8'h11, idx8, val8, 104'h0};
                `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd3, 1'b0)
              end else begin
                pay128 = {8'h10, idx8, 112'h0};
                `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd2, 1'b0)
              end
              `UPM_WAIT_FRAMES(base + 1)
              exp128 = {8'hE0, 8'h02, 112'h0};
              check_frame(base, tc_c, 4'hF, 8'd2, exp128, "crv_pacp_oob");
              if (!irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV PACP OOB: no irq");
              end
            end
            5: begin
              // RX-engine edge paths (alternate):
              //  even: oversized frame (len > 16) -> R_DISCARD
              //  odd:  ESC then non-ESC/COF byte (R_ESC0 -> R_IDLE) and a
              //        mid-frame ESC+COF abort (R_FRAME restart arm)
              n_ovsz++;
              base = n_frames;
              irq_seen = 1'b0;
              if (n_ovsz % 2 == 1) begin
                sf_fb[0] = {3'b000, tc_c, 4'h1};
                sf_fb[1] = {4'h0, seq_c};
                sf_fb[2] = 8'd20;             // oversized length byte
                `UPM_SEND_SYM(8'h9D)
                `UPM_SEND_SYM(8'hC0)
                `UPM_SEND_SYM(sf_fb[0])
                `UPM_SEND_SYM(sf_fb[1])
                `UPM_SEND_SYM(sf_fb[2])
                for (sf_i = 0; sf_i < 6; sf_i = sf_i + 1)
                  `UPM_SEND_SYM(8'h55)        // garbage (no ESC/COF adjacency)
              end else begin
                `UPM_SEND_SYM(8'h9D)          // lone ESC ...
                `UPM_SEND_SYM(8'h55)          // ... then garbage -> R_IDLE
                `UPM_SEND_SYM(8'h9D)          // start a frame ...
                `UPM_SEND_SYM(8'hC0)
                `UPM_SEND_SYM(8'h11)          // ... one header byte, then the
              end                             // next frame's ESC+COF aborts it
              `UPM_WAIT_CLK(30)
              if (n_frames != base) begin
                errors = errors + 1;
                $display("ERROR: CRV rx-edge frame produced a response");
              end
              if (irq_seen) begin
                errors = errors + 1; $display("ERROR: CRV rx-edge: irq");
              end
              // resync: a following valid frame is processed normally
              seq_c = seq_c + 4'd1;
              base = n_frames;
              pay128 = {8'h10, 8'h03, 112'h0};
              `UPM_SEND_FRAME(tc_c, 4'hF, seq_c, pay128, 8'd2, 1'b0)
              `UPM_WAIT_FRAMES(base + 1)
              exp128 = {8'h90, 8'h03, attr_model[3], 104'h0};
              check_frame(base, tc_c, 4'hF, 8'd3, exp128, "crv_ovsz_resync");
            end
            default: begin
              // TC0 read-response timeout (covers the q0 timer arm)
              n_rto++;
              `UPM_WAIT_CLK(10)
              @(negedge clk); tx_ready = 1'b0;
              // blocker: TC0 write whose ACK occupies the stalled TX engine
              pay128 = {8'h01, 8'h00, 8'h30, 8'h04, 32'hABCD_1234, 64'h0};
              `UPM_SEND_FRAME(1'b0, 4'h1, seq_c, pay128, 8'd8, 1'b0)
              mem_model[12] = 32'hABCD_1234;
              // queued TC0 read: response waits > 100 clk -> ERR_TIMEOUT
              seq_c = seq_c + 4'd1;
              pay128 = {8'h02, 8'h00, 8'h10, 8'h04, 96'h0};
              `UPM_SEND_FRAME(1'b0, 4'h1, seq_c, pay128, 8'd4, 1'b0)
              base = n_frames;
              `UPM_WAIT_CLK(150)
              @(negedge clk); tx_ready = 1'b1;
              `UPM_WAIT_FRAMES(base + 2)
              exp128 = {8'h81, 8'h00, 8'h30, 8'h04, 8'h00, 88'h0};
              check_frame(base, 1'b0, 4'h1, 8'd5, exp128, "crv_rto_blocker");
              exp128 = {8'hE0, 8'h01, 112'h0};
              check_frame(base + 1, 1'b0, 4'h1, 8'd2, exp128, "crv_rto_err");
              if (irq !== 1'b0) begin
                errors = errors + 1; $display("ERROR: CRV irq on read timeout");
              end
            end
          endcase
          eroll = (eroll + 1) % 7;
        end
      end
      // ---- attr toggle-closure sweep: every attr bit both ways --------
      // 0xFF then 0x00 into each of the 16 attribute registers (each
      // SET_RSP frame self-checked against the model).
      for (int i = 0; i < 16; i++) begin
        for (int v = 0; v < 2; v++) begin
          val8 = (v == 0) ? 8'hFF : 8'h00;
          idx8 = 8'(i);
          seq_c = seq_c + 4'd1;
          base = n_frames;
          pay128 = {8'h11, idx8, val8, 104'h0};
          `UPM_SEND_FRAME(1'b0, 4'hF, seq_c, pay128, 8'd3, 1'b0)
          `UPM_WAIT_FRAMES(base + 1)
          exp128 = {8'h91, idx8, val8, 104'h0};
          check_frame(base, 1'b0, 4'hF, 8'd3, exp128, "crv_attr_sweep");
          attr_model[i] = val8;
        end
      end
      // ---- memory-data toggle sweep: walking patterns through the -----
      // deep payload bytes (write 12B + read 12B back, self-checked)
      for (int k = 0; k < 8; k++) begin
        tc_c  = (k % 2 == 0);
        dw    = 32'h0101_0101 << k;               // walking-1 per byte lane
        wa    = 8 + k;
        addr8 = 8'(wa * 4);
        seq_c = seq_c + 4'd1;
        base  = n_frames;
        pay128 = {8'h01, 8'h00, addr8, 8'h0C, dw, ~dw, (dw ^ 32'hA5A5_A5A5)};
        `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd16, 1'b0)
        `UPM_WAIT_FRAMES(base + 1)
        exp128 = {8'h81, 8'h00, addr8, 8'h0C, 8'h00, 88'h0};
        check_frame(base, tc_c, 4'h1, 8'd5, exp128, "crv_data_sweep_wr");
        mem_model[wa]   = dw;
        mem_model[wa+1] = ~dw;
        mem_model[wa+2] = dw ^ 32'hA5A5_A5A5;
        seq_c = seq_c + 4'd1;
        base  = n_frames;
        pay128 = {8'h02, 8'h00, addr8, 8'h0C, 96'h0};
        `UPM_SEND_FRAME(tc_c, 4'h1, seq_c, pay128, 8'd4, 1'b0)
        `UPM_WAIT_FRAMES(base + 1)
        exp128 = {8'h82, 8'h00, addr8, 8'h0C,
                  mem_model[wa], mem_model[wa+1], mem_model[wa+2]};
        check_frame(base, tc_c, 4'h1, 8'd16, exp128, "crv_data_sweep_rd");
      end
      $display("CRV: 126 txns + attr/data sweeps (mem=%0d pacp=%0d | badcrc=%0d oobwr=%0d oobrd=%0d badop=%0d pacpoob=%0d oversz=%0d rdto=%0d)",
               n_rw, n_pacp, n_bcrc, n_owr, n_ord, n_bop, n_paob, n_ovsz, n_rto);
    end
  `undef UPM_SEND_SYM
  `undef UPM_SEND_FRAME
  `undef UPM_WAIT_FRAMES
  `undef UPM_WAIT_CLK
`endif

    // ---- summary ----
    wait_clk(20);
    if (errors == 0) $display("TEST PASSED: UniPro_Mem");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < UPM_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, UPM_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // ------------------------------------------------------------------
  // TIMEOUT guard
  // ------------------------------------------------------------------
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (10000) #1000;   // 10 ms in 1-us chunks
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
`else
  initial begin
    #5000000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
`endif

endmodule
