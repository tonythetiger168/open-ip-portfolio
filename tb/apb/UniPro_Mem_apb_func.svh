// SPDX-License-Identifier: Apache-2.0
// IP part of UniPro_Mem_apb_tb: the peer endpoint of the core TB (frames
// with ESC / COF framing and CRC-16 on rx_sym, a monitor decoding and
// CRC-checking every DUT frame on tx_sym). PACP set / get, memory write /
// read, TC1 overtaking TC0 under back-pressure, the read timeout, and each
// error class (CRC, out-of-bounds, invalid length, NAC budget, dropped
// response) in IRQ_STATUS.ERR, masked and on the irq pin; PRESETN mid-frame.
  localparam logic [7:0] SYM_ESC = 8'h9D;
  localparam logic [7:0] SYM_COF = 8'hC0;
  localparam logic [7:0] ESC_XOR = 8'h20;
  initial begin rx_sym = 8'h00; rx_valid = 1'b0; tx_ready = 1'b1; end

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
  logic [7:0]  fr_pay  [0:1023][0:15];
  logic        fr_tc   [0:1023];
  logic [3:0]  fr_cport[0:1023];
  logic [3:0]  fr_seq  [0:1023];
  logic [7:0]  fr_len  [0:1023];
  integer      n_frames = 0;

  logic [7:0]  d;
  logic [15:0] crc;
  integer      ii;


  always @(negedge PCLK) begin
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
              if (n_frames < 1024) begin
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
  // dut.c_irq capture
  // ------------------------------------------------------------------
  logic irq_seen = 1'b0;
  always @(posedge PCLK) if (dut.c_irq) irq_seen = 1'b1;

  // ------------------------------------------------------------------
  // stimulus tasks
  // ------------------------------------------------------------------
  task automatic send_sym(input logic [7:0] s);
    begin
      @(negedge PCLK); rx_sym = s; rx_valid = 1'b1;
      @(negedge PCLK); rx_valid = 1'b0;
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
      while ((n_frames < n) && (t < 20000)) begin @(posedge PCLK); t = t + 1; end
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
    begin for (t = 0; t < n; t = t + 1) @(posedge PCLK); end
  endtask


  // ERR: one core pulse latched; the w1c clears it; the pin follows the enable
  task automatic err_seen(input bit en, input string m);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({m, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq !== 1'b0) fail({m, ": irq pin after clear"});
  endtask

  logic [3:0] nac_seq;
  integer     base;
  task automatic ip_func;
    rd_exp(A_FLAGS, 0);
    base = n_frames;
    // ---- PACP attribute set / get ----
    send_frame(1'b0, 4'hF, 4'h0, {8'h11, 8'h03, 8'hA5, 104'h0}, 8'd3, 1'b0);
    wait_frames(base + 1);
    check_frame(base, 1'b0, 4'hF, 8'd3, {8'h91, 8'h03, 8'hA5, 104'h0}, "pacp_set");
    send_frame(1'b0, 4'hF, 4'h1, {8'h10, 8'h03, 112'h0}, 8'd2, 1'b0);
    wait_frames(base + 2);
    check_frame(base + 1, 1'b0, 4'hF, 8'd3, {8'h90, 8'h03, 8'hA5, 104'h0}, "pacp_get");

    // ---- memory write + read back ----
    send_frame(1'b0, 4'h1, 4'h2,
               {8'h01, 8'h00, 8'h10, 8'h0C,
                8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h01, 8'h23, 8'h45, 8'h67,
                8'h89, 8'hAB, 8'hCD, 8'hEF}, 8'd16, 1'b0);
    wait_frames(base + 3);
    check_frame(base + 2, 1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h10, 8'h0C, 8'h00, 88'h0},
                "mem_wr_ack");
    send_frame(1'b0, 4'h1, 4'h3, {8'h02, 8'h00, 8'h10, 8'h0C, 96'h0}, 8'd4, 1'b0);
    wait_frames(base + 4);
    check_frame(base + 3, 1'b0, 4'h1, 8'd16,
                {8'h82, 8'h00, 8'h10, 8'h0C,
                 8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h01, 8'h23, 8'h45, 8'h67,
                 8'h89, 8'hAB, 8'hCD, 8'hEF}, "mem_rd");
    rd_exp(A_IRQ_STATUS, 0);

    // ---- QoS: TC1 overtakes queued TC0 under back-pressure ----
    @(negedge PCLK); tx_ready = 1'b0;
    send_frame(1'b0, 4'h1, 4'h4, {8'h01, 8'h00, 8'h20, 8'h04,
               8'hAA, 8'hAA, 8'hAA, 8'hAA, 64'h0}, 8'd8, 1'b0);
    send_frame(1'b0, 4'h1, 4'h5, {8'h01, 8'h00, 8'h24, 8'h04,
               8'hBB, 8'hBB, 8'hBB, 8'hBB, 64'h0}, 8'd8, 1'b0);
    send_frame(1'b1, 4'h1, 4'h6, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0);
    base = n_frames;
    wait_clk(30);
    if (n_frames != base) fail("frames emitted while tx_ready low");
    @(negedge PCLK); tx_ready = 1'b1;
    wait_frames(base + 3);
    check_frame(base,   1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h20, 8'h04, 8'h00, 88'h0}, "qos_first");
    check_frame(base+1, 1'b1, 4'h1, 8'd8, {8'h82, 8'h00, 8'h10, 8'h04,
                8'hDE, 8'hAD, 8'hBE, 8'hEF, 64'h0}, "qos_tc1_first");
    check_frame(base+2, 1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h24, 8'h04, 8'h00, 88'h0}, "qos_tc0_last");

    // ---- read timeout: error frame, no ERR ----
    wait_clk(20);
    @(negedge PCLK); tx_ready = 1'b0;
    send_frame(1'b0, 4'h1, 4'h7, {8'h01, 8'h00, 8'h28, 8'h04,
               8'hCC, 8'hCC, 8'hCC, 8'hCC, 64'h0}, 8'd8, 1'b0);
    send_frame(1'b1, 4'h1, 4'h8, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0);
    base = n_frames;
    wait_clk(150);
    @(negedge PCLK); tx_ready = 1'b1;
    wait_frames(base + 2);
    check_frame(base,   1'b0, 4'h1, 8'd5, {8'h81, 8'h00, 8'h28, 8'h04, 8'h00, 88'h0}, "to_blocker");
    check_frame(base+1, 1'b1, 4'h1, 8'd2, {8'hE0, 8'h01, 112'h0}, "to_err");
    rd_exp(A_IRQ_STATUS, 0);

    // ---- CRC error (masked): frame dropped ----
    base = n_frames;
    send_frame(1'b0, 4'hF, 4'h9, {8'h10, 8'h03, 112'h0}, 8'd2, 1'b1);
    wait_clk(30);
    if (n_frames != base) fail("response sent for bad-CRC frame");
    err_seen(0, "CRC error");

    // ---- out-of-bounds and invalid length (on the irq pin) ----
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    send_frame(1'b0, 4'h1, 4'hA, {8'h01, 8'h00, 8'hFC, 8'h0C,
               8'h11, 8'h22, 8'h33, 8'h44, 8'h55, 8'h66, 8'h77, 8'h88,
               8'h99, 8'hAA, 8'hBB, 8'hCC}, 8'd16, 1'b0);
    wait_frames(base + 1);
    check_frame(base, 1'b0, 4'h1, 8'd2, {8'hE0, 8'h02, 112'h0}, "oob_wr");
    err_seen(1, "out-of-bounds");
    send_frame(1'b0, 4'h1, 4'hC, {8'h01, 8'h00, 8'h30, 8'h05,
               8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 56'h0}, 8'd9, 1'b0);
    wait_frames(base + 2);
    check_frame(base+1, 1'b0, 4'h1, 8'd2, {8'hE0, 8'h02, 112'h0}, "badlen");
    err_seen(1, "invalid length");

    // ---- NAC retransmission: 3 retries, the 4th NAC exhausts the budget ----
    send_frame(1'b1, 4'h1, 4'hD, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0);
    wait_frames(base + 3);
    nac_seq = fr_seq[base+2];
    for (int r = 1; r <= 3; r = r + 1) begin
      send_frame(1'b0, 4'hF, 4'h0, {8'h20, 4'h0, nac_seq, 112'h0}, 8'd2, 1'b0);
      wait_frames(base + 3 + r);
      check_frame(base+2+r, 1'b1, 4'h1, 8'd8, {8'h82, 8'h00, 8'h10, 8'h04,
                  8'hDE, 8'hAD, 8'hBE, 8'hEF, 64'h0}, "nac_retx");
      if (fr_seq[base+2+r] !== nac_seq) fail("retransmission seq");
    end
    rd_exp(A_IRQ_STATUS, 0);
    send_frame(1'b0, 4'hF, 4'h0, {8'h20, 4'h0, nac_seq, 112'h0}, 8'd2, 1'b0);
    wait_clk(40);
    if (n_frames != base + 6) fail("frame after NAC exhausted");
    err_seen(1, "NAC exhausted");
    wr(A_IRQ_ENABLE, 0);

    // ---- response dropped: its TC slot still occupied under back-pressure ----
    @(negedge PCLK); tx_ready = 1'b0;
    for (int k = 0; k < 3; k++)
      send_frame(1'b0, 4'h1, 4'(k), {8'h01, 8'h00, 8'h30 + 8'(4 * k), 8'h04,
                 8'h11, 8'h22, 8'h33, 8'h44, 64'h0}, 8'd8, 1'b0);
    wait_clk(10);
    err_seen(0, "response dropped");
    @(negedge PCLK); tx_ready = 1'b1;
    wait_clk(400);

    // ---- PRESETN in the middle of an incoming frame ----
    fork
      send_frame(1'b0, 4'h1, 4'h1, {8'h02, 8'h00, 8'h10, 8'h04, 96'h0}, 8'd4, 1'b0);
      begin wait_clk(5); @(negedge PCLK); PRESETN = 0; wait_clk(3); @(negedge PCLK); PRESETN = 1; end
    join
    wait_clk(100);
    check_reset_values();
    rd_exp(A_IRQ_STATUS, 0);
    base = n_frames;
    send_frame(1'b0, 4'hF, 4'h0, {8'h10, 8'h03, 112'h0}, 8'd2, 1'b0);
    wait_frames(base + 1);
    check_frame(base, 1'b0, 4'hF, 8'd3, {8'h90, 8'h03, 8'h00, 104'h0}, "attr after PRESETN");

    // leave ERR pending (masked) for the final reset
    send_frame(1'b0, 4'hF, 4'h9, {8'h10, 8'h03, 112'h0}, 8'd2, 1'b1);
    wait_clk(30);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
