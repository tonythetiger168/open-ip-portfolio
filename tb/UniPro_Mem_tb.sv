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
              if (n_frames < 64) begin
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
    logic [7:0]  fb [0:18];
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

    // ---- summary ----
    wait_clk(20);
    if (errors == 0) $display("TEST PASSED: UniPro_Mem");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // ------------------------------------------------------------------
  // TIMEOUT guard
  // ------------------------------------------------------------------
  initial begin
    #5000000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
