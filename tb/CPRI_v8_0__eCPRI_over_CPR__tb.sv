// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for CPRI_v8_0__eCPRI_over_CPR__top -- CPRI master.
// The TB plays the RE (slave) peer with its own table-driven 8b/10b encoder
// (RD- tables + complement rules, D.x.A7, K28 at both disparities).
// Covered: every transmitted symbol checked against the expected
// hyperframe (K28.5, 0x50 stuff bytes, L1 slow stream with version / rate /
// check byte, vendor byte, IQ pattern) including its running disparity;
// sync handshake (HUNT -> ALIGN -> SYNC), stray comma and missing comma
// during ALIGN, IQ capture into the 32-word buffer with pops, simultaneous
// push / pop, overflow count saturation, L1 negotiation (good, bad check
// byte, restart), loss of sync after 4 missed commas (and staying in sync
// after 3), code violations (invalid code group, wrong disparity) with the
// sticky irq and its clear, the configuration registers, reset mid-sync.
`timescale 1ns/1ps
module CPRI_v8_0__eCPRI_over_CPR__tb;
  localparam logic [7:0] K28_5 = 8'hBC;

  logic clk = 0, rst_n = 0;
  logic [9:0]  rx_sym = 10'h0;
  logic [9:0]  tx_sym;
  logic        cpu_we = 0, cpu_re = 0;
  logic [3:0]  cpu_addr = 0;
  logic [31:0] cpu_wdata = 0, cpu_rdata;
  logic        irq;

  int errors = 0;

  CPRI_v8_0__eCPRI_over_CPR__top dut (
    .clk(clk), .rst_n(rst_n),
    .rx_sym(rx_sym), .tx_sym(tx_sym),
    .cpu_we(cpu_we), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  // ------------------------------------------------------------------
  // reference 8b/10b encoder: {abcdei} / {fghj}, RD- column + complement
  // ------------------------------------------------------------------
  // 5b/6b and 3b/4b codes in the RD- column
  function automatic logic [5:0] t6(input int y);
    case (y)
      0: t6 = 6'b100111;
      1: t6 = 6'b011101;
      2: t6 = 6'b101101;
      3: t6 = 6'b110001;
      4: t6 = 6'b110101;
      5: t6 = 6'b101001;
      6: t6 = 6'b011001;
      7: t6 = 6'b111000;
      8: t6 = 6'b111001;
      9: t6 = 6'b100101;
      10: t6 = 6'b010101;
      11: t6 = 6'b110100;
      12: t6 = 6'b001101;
      13: t6 = 6'b101100;
      14: t6 = 6'b011100;
      15: t6 = 6'b010111;
      16: t6 = 6'b011011;
      17: t6 = 6'b100011;
      18: t6 = 6'b010011;
      19: t6 = 6'b110010;
      20: t6 = 6'b001011;
      21: t6 = 6'b101010;
      22: t6 = 6'b011010;
      23: t6 = 6'b111010;
      24: t6 = 6'b110011;
      25: t6 = 6'b100110;
      26: t6 = 6'b010110;
      27: t6 = 6'b110110;
      28: t6 = 6'b001110;
      29: t6 = 6'b101110;
      30: t6 = 6'b011110;
      31: t6 = 6'b101011;
      default: t6 = 6'b000000;
    endcase
  endfunction
  function automatic logic [3:0] t4(input int x);
    case (x)
      0: t4 = 4'b1011;
      1: t4 = 4'b1001;
      2: t4 = 4'b0101;
      3: t4 = 4'b1100;
      4: t4 = 4'b1101;
      5: t4 = 4'b1010;
      6: t4 = 4'b0110;
      7: t4 = 4'b1110;
      default: t4 = 4'b0000;
    endcase
  endfunction
  function automatic int ones(input logic [9:0] v);
    ones = 0;
    for (int i = 0; i < 10; i++) ones += v[i];
  endfunction

  // returns {rd_out, symbol}
  function automatic logic [10:0] enc(input logic [7:0] d, input logic k, input logic rd);
    logic [5:0] c6;
    logic [3:0] c4;
    logic       r;
    int         y, x;
    y = d[4:0]; x = d[7:5];
    if (k) begin                                      // K28.x: RD+ = complement
      c6 = 6'b001111;
      c4 = (x == 0) ? 4'b0100 : (x == 1) ? 4'b1001 : (x == 2) ? 4'b0101 : (x == 3) ? 4'b0011 :
           (x == 4) ? 4'b0010 : (x == 5) ? 4'b1010 : (x == 6) ? 4'b0110 : 4'b1000;
      if (rd) begin c6 = ~c6; c4 = ~c4; end
      enc = {(ones({c6, c4}) == 5) ? rd : ~rd, c6, c4};
    end else begin
      c6 = t6(y);
      if (rd && (ones({4'h0, c6}) != 3 || c6 == 6'b111000)) c6 = ~c6;
      r = (ones({4'h0, c6}) == 3) ? rd : ~rd;
      if (x == 7 && ((!r && (y == 17 || y == 18 || y == 20)) ||
                     (r && (y == 11 || y == 13 || y == 14)))) c4 = r ? 4'b1000 : 4'b0111;
      else begin
        c4 = t4(x);
        if (r && (ones({6'h0, c4}) != 2 || x == 3)) c4 = ~c4;
      end
      if (ones({6'h0, c4}) != 2) r = ~r;
      enc = {r, c6, c4};
    end
  endfunction

  // ------------------------------------------------------------------
  // cpu port
  // ------------------------------------------------------------------
  logic [7:0] cfgm [0:7];          // model of the config registers

  task automatic cpu_wr(input logic [3:0] a, input logic [31:0] d);
    @(negedge clk);
    cpu_we = 1; cpu_addr = a; cpu_wdata = d;
    @(negedge clk);
    cpu_we = 0;
  endtask
  task automatic cpu_rd(input logic [3:0] a, output logic [31:0] d, input logic pop);
    @(negedge clk);
    cpu_re = pop; cpu_addr = a;
    #1 d = cpu_rdata;
    @(negedge clk);
    cpu_re = 0;
  endtask

  // ------------------------------------------------------------------
  // master TX monitor: every symbol against the expected hyperframe
  // ------------------------------------------------------------------
  int         tpos = 0;            // position of the symbol produced at this edge
  int         thfi = 0;
  logic       trd = 0;
  logic [9:0] exp_sym;
  logic       exp_ok = 0;

  function automatic logic [7:0] m_l1(input int hfi);
    case (hfi)
      0:  m_l1 = 8'h5A;
      1:  m_l1 = {4'h0, cfgm[1][3:0]};
      2:  m_l1 = cfgm[0];
      15: m_l1 = cfgm[0] ^ {4'h0, cfgm[1][3:0]} ^ 8'hA5;
      default: m_l1 = 8'h00;
    endcase
  endfunction

  always @(posedge clk) begin
    logic [7:0] b;
    logic       k;
    int         bf, w;
    if (!rst_n) begin
      tpos = 0; thfi = 0; trd = 0; exp_ok = 0;
      cfgm[0] = 8'h2A; cfgm[1] = 8'h04; cfgm[2] = 8'hC9;
      for (int i = 3; i < 8; i++) cfgm[i] = 8'h00;
    end else begin
      bf = tpos / 16; w = tpos % 16; k = 0;
      if (w == 0) begin
        if (bf == 0) begin k = 1; b = K28_5; end
        else if (bf == 1) b = m_l1(thfi);
        else if (bf == 4) b = cfgm[2];
        else b = 8'h00;
      end else if (bf == 0 && w <= 2) b = 8'h50;
      else b = {4'(bf), 4'(w)};
      {trd, exp_sym} = enc(b, k, trd);
      exp_ok = 1;
      if (tpos == 1023) begin tpos = 0; thfi = (thfi + 1) % 16; end
      else tpos++;
      if (cpu_we && cpu_addr < 8) cfgm[cpu_addr] = cpu_wdata[7:0];
    end
  end
  always @(negedge clk) if (rst_n && exp_ok) check(tx_sym === exp_sym, "TX symbol");

  // ------------------------------------------------------------------
  // RE peer stream (one symbol per clock, driven on negedge)
  // ------------------------------------------------------------------
  logic       peer_on = 0;
  int         pw = 0, phf = 0, phfi = 0;  // position, hyperframe count, L1 index
  logic       prd = 0;
  int         skip_comma = 0;             // hyperframes with the comma suppressed
  int         stray_at = -1;              // position of an extra comma
  int         bad_at = -1;                // position of an invalid code group
  int         disp_at = -1;               // position of the next wrong-disparity symbol
  int         disp_n = 0;                 // wrong-disparity symbols still to send
  int         disp_k = 0;
  logic       pop_full = 0, pop_off = 0;  // pop in the clock a word is pushed
  int         pp_idx = -1;
  logic [3:0] p_ver = 4'd3, p_rate = 4'd5, p_vhi = 4'd0, p_ptr = 4'd1;
  logic [7:0] p_chk_x = 8'h00;            // XOR into the check byte (0 = good)
  logic       p_som2 = 0;                 // a second SOM in the middle of a sequence
  logic       bad_clr = 0, clr_off = 0;   // clear the cv flag in the bad symbol's clock
  logic [7:0] p_vendor = 8'h5C;
  int         iq_n = 0;
  logic [7:0] iq_log [0:65535];
  int         iq_base = -1;
  logic       log_iq = 0;

  function automatic logic [7:0] p_l1(input int hfi);
    case (hfi)
      0:  p_l1 = 8'h5A;
      1:  p_l1 = {p_vhi, p_ver};
      2:  p_l1 = {p_ptr, p_rate};
      7:  p_l1 = p_som2 ? 8'h5A : 8'h00;
      15: p_l1 = {p_vhi, p_ver} ^ {p_ptr, p_rate} ^ 8'hA5 ^ p_chk_x;
      default: p_l1 = 8'h00;
    endcase
  endfunction

  always @(negedge clk) begin
    logic [7:0] b;
    logic       k, r2;
    logic [9:0] s2;
    if (clr_off) begin cpu_we = 0; clr_off = 0; end
    if (pop_off) begin cpu_re = 0; pop_off = 0; end
    if (peer_on) begin
      b = 8'h00; k = 0;
      if (pw % 16 == 0) begin
        if (pw == 0) begin
          if (skip_comma == 0) begin k = 1; b = K28_5; end
          else skip_comma--;
        end else if (pw == 16) b = p_l1(phfi);
        else if (pw == 64) b = p_vendor;
      end else if (pw < 3) b = 8'h50;
      else begin
        b = 8'($urandom);
        if (log_iq) begin
          if (pop_full && iq_n % 4 == 3) begin
            cpu_re = 1; cpu_addr = 4'd10; pop_full = 0; pop_off = 1; pp_idx = iq_n - 3;
          end
          iq_log[iq_n % 65536] = b; iq_n++;
        end
      end
      if (pw == stray_at) begin k = 1; b = K28_5; stray_at = -1; end
      if (pw == bad_at) begin
        rx_sym = 10'b1111110000; bad_at = -1;
        if (bad_clr) begin
          cpu_we = 1; cpu_addr = 4'd13; cpu_wdata = 32'h2; bad_clr = 0; clr_off = 1;
        end
      end else if (pw == disp_at && disp_n > 0) begin
        // D0.0 / D3.3 / D7.1 / D3.0 encoded for the wrong disparity
        {r2, s2} = enc((disp_k % 4 == 0) ? 8'h00 : (disp_k % 4 == 1) ? 8'h63 :
                       (disp_k % 4 == 2) ? 8'h27 : 8'h03, 1'b0, ~prd);
        rx_sym = s2;
        // the receiver follows the symbol's own sub-block disparities
        prd = (ones({6'h0, s2[3:0]}) == 3) ? 1'b1 : (ones({6'h0, s2[3:0]}) == 1) ? 1'b0 :
              (ones({4'h0, s2[9:4]}) == 4) ? 1'b1 : (ones({4'h0, s2[9:4]}) == 2) ? 1'b0 : prd;
        disp_k++; disp_n--; disp_at = disp_at + 7;
      end else
        {prd, rx_sym} = enc(b, k, prd);
      if (pw == 1023) begin
        pw = 0; phf++; phfi = (phfi + 1) % 16;
      end else pw++;
    end else
      {prd, rx_sym} = enc(8'h00, 1'b0, prd);       // idle D0.0
  end

  // return just after the clock edge that samples the symbol before p
  task automatic wait_pos(input int p);
    @(posedge clk); #1;
    while (pw != p) begin @(posedge clk); #1; end
  endtask

  task automatic st_is(input logic [1:0] st, input string msg);
    logic [31:0] r;
    cpu_rd(4'd8, r, 0);
    check(r[1:0] == st, msg);
  endtask

  // pop n IQ words and compare with the logged bytes
  task automatic pop_check(input int n);
    logic [31:0] r;
    int          i;
    for (int j = 0; j < n; j++) begin
      i = iq_base;
      cpu_rd(4'd10, r, 1);
      check(r == {iq_log[i % 65536], iq_log[(i + 1) % 65536], iq_log[(i + 2) % 65536],
                  iq_log[(i + 3) % 65536]}, "IQ word");
      iq_base += 4;
    end
  endtask

  // peer start at a hyperframe boundary; sync reached at the third comma
  task automatic bring_up;
    pw = 0; phfi = 0;
    peer_on = 1;
    wait_pos(1); st_is(2'd1, "ALIGN after the first comma");
    wait_pos(0); wait_pos(1); st_is(2'd1, "still ALIGN after the second comma");
    wait_pos(0);
    log_iq = 1; iq_n = 0; iq_base = 0;
    wait_pos(1); st_is(2'd2, "SYNC after the third comma");
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  logic [31:0] r;
  int          n;

  initial begin
    repeat (3) @(negedge clk);
    check(irq == 0, "reset irq");
    rst_n = 1;

    // ---- configuration registers: every bit both ways ----
    for (int a = 0; a < 8; a++) begin
      cpu_wr(4'(a), 32'hFFFF_FFFF); cpu_rd(4'(a), r, 0); check(r == 32'hFF, "cfg write ones");
      cpu_wr(4'(a), 32'h0000_0000); cpu_rd(4'(a), r, 0); check(r == 32'h00, "cfg write zeros");
    end
    cpu_wr(4'd0, 32'h2A); cpu_wr(4'd1, 32'h04); cpu_wr(4'd2, 32'hC9);
    cpu_wr(4'd14, 32'hFFFF_FFFF);                     // unmapped
    cpu_rd(4'd14, r, 0); check(r == 0, "unmapped read");
    cpu_rd(4'd15, r, 0); check(r == 0, "unmapped read 15");
    cpu_rd(4'd11, r, 0); check(r == 0, "IQ buffer empty");
    cpu_rd(4'd10, r, 1);                              // pop on empty: no effect
    cpu_rd(4'd11, r, 0); check(r == 0, "pop on empty");
    st_is(2'd0, "HUNT");

    // ---- ALIGN: stray comma re-aligns, then a missed comma -> HUNT ----
    pw = 0; peer_on = 1;
    wait_pos(1); st_is(2'd1, "ALIGN");
    stray_at = 300;
    wait_pos(301); st_is(2'd1, "ALIGN after the stray comma");
    // the expected comma is now 1024 after position 300; suppress the next
    // hyperframe comma so that no comma arrives at all
    skip_comma = 1;
    repeat (1030) @(negedge clk);
    st_is(2'd0, "back to HUNT when the comma is missing");
    peer_on = 0;
    repeat (20) @(negedge clk);

    // ---- sync bring-up, IQ capture ----
    bring_up;
    // pop as words arrive (some pops coincide with a push)
    for (int j = 0; j < 60; j++) begin
      cpu_rd(4'd11, r, 0);
      if (r != 0) pop_check(1);
    end
    // stop popping: the buffer fills, further words are dropped and counted
    repeat (300) @(negedge clk);
    cpu_rd(4'd11, r, 0); check(r == 32, "IQ buffer full");
    cpu_rd(4'd8, r, 0);  check(r[23:16] > 0, "overflow counted");
    // pop in the very clock a word completes: the word is kept
    pop_full = 1;
    while (pop_full || pop_off) @(negedge clk);
    repeat (2) @(negedge clk);
    cpu_rd(4'd11, r, 0); check(r == 32, "buffer still full after pop + push");
    iq_base += 4;                                    // the popped oldest word
    pop_check(31);                                   // the oldest words survive
    iq_base = pp_idx;
    pop_check(1);                                    // then the word pushed with the pop

    // ---- L1 negotiation: good sequence ----
    wait_pos(0);
    while (phfi != 0) wait_pos(0);
    repeat (16) wait_pos(0);
    wait_pos(20);
    cpu_rd(4'd8, r, 0); check(r[2] == 1 && r[15:12] == 4'd3, "L1 done, peer version");
    cpu_rd(4'd9, r, 0); check(r == {24'h0, 4'd5, 4'd3}, "negotiated rate / version");
    cpu_wr(4'd1, 32'h02); cpu_wr(4'd0, 32'h12);
    cpu_rd(4'd9, r, 0); check(r == {24'h0, 4'd2, 4'd2}, "local lower");
    cpu_rd(4'd12, r, 0); check(r == 8'h5C, "peer vendor byte");
    // all-ones / all-zeros peer fields, then a bad check byte
    p_ver = 4'hF; p_rate = 4'hF; p_vendor = 8'hA3; p_vhi = 4'hF; p_ptr = 4'hF;
    cpu_wr(4'd1, 32'h0F); cpu_wr(4'd0, 32'hFF); cpu_wr(4'd2, 32'h00);
    repeat (17) wait_pos(0);
    wait_pos(20);
    cpu_rd(4'd8, r, 0); check(r[15:12] == 4'hF, "peer version F");
    cpu_rd(4'd9, r, 0); check(r == 8'hFF, "negotiated F / F");
    cpu_rd(4'd12, r, 0); check(r == 8'hA3, "peer vendor A3");
    p_ver = 4'h0; p_rate = 4'h0; p_chk_x = 8'h01; p_vhi = 4'h0; p_ptr = 4'h0;
    repeat (17) wait_pos(0);
    wait_pos(20);
    cpu_rd(4'd8, r, 0); check(r[15:12] == 4'hF, "bad check byte ignored");
    p_chk_x = 8'h80;
    repeat (17) wait_pos(0);
    wait_pos(20);
    cpu_rd(4'd8, r, 0); check(r[15:12] == 4'hF, "check byte bit 7 wrong: ignored");
    p_chk_x = 8'h00; p_som2 = 1;                     // SOM restarts the sequence at hfi 7
    repeat (17) wait_pos(0);
    wait_pos(20);
    cpu_rd(4'd8, r, 0); check(r[15:12] == 4'hF, "restarted sequence not complete");
    p_som2 = 0;
    repeat (17) wait_pos(0);
    wait_pos(20);
    cpu_rd(4'd8, r, 0); check(r[15:12] == 4'h0, "peer version 0");
    cpu_wr(4'd1, 32'h04); cpu_wr(4'd0, 32'h2A); cpu_wr(4'd2, 32'hC9);

    // ---- code violations: invalid code group, wrong disparity; irq clear ----
    check(irq == 0, "no irq yet");
    bad_at = 500; wait_pos(502);
    check(irq == 1, "code violation irq");
    cpu_rd(4'd13, r, 0); check(r == 2, "cv flag");
    cpu_wr(4'd13, 32'h1); check(irq == 1, "clearing los leaves cv");
    cpu_wr(4'd13, 32'h2); check(irq == 0, "cv cleared");
    // wrong-disparity symbols, one at a time with the flag cleared between
    for (int k = 0; k < 20; k++) begin
      wait_pos(100 + 40 * k);
      disp_n = 1; disp_at = 105 + 40 * k;
      wait_pos(108 + 40 * k);
      check(irq == 1 && disp_n == 0, "disparity error irq");
      cpu_wr(4'd13, 32'h2); check(irq == 0, "cv cleared after a disparity error");
    end
    wait_pos(890); disp_n = 1; disp_at = 895; wait_pos(898);
    // clear in the same clock as a new violation: set wins
    wait_pos(900);
    bad_clr = 1; bad_at = 902;
    wait_pos(905); check(irq == 1, "violation set wins over clear");
    cpu_wr(4'd13, 32'h3); check(irq == 0, "cleared");
    st_is(2'd2, "still in sync after violations");

    // ---- 3 missed commas: stays in sync; 4: loss of sync ----
    wait_pos(500);
    skip_comma = 3;
    repeat (4) wait_pos(0);
    wait_pos(5);
    st_is(2'd2, "3 missed commas tolerated");
    check(irq == 0, "no loss of sync");
    wait_pos(500);
    skip_comma = 4;
    repeat (4) wait_pos(0);
    wait_pos(5);
    st_is(2'd0, "loss of sync after 4 missed commas");
    check(irq == 1, "loss of sync irq");
    cpu_rd(4'd13, r, 0); check(r == 1, "los flag");
    cpu_wr(4'd13, 32'h1); check(irq == 0, "los cleared");
    // HUNT again; resync
    peer_on = 0; log_iq = 0;
    repeat (50) @(negedge clk);
    // pop what was left in the buffer
    cpu_rd(4'd11, r, 0);
    n = r;
    for (int j = 0; j < n; j++) cpu_rd(4'd10, r, 1);
    bring_up;
    repeat (300) @(negedge clk);
    pop_check(4);

    // ---- reset mid-sync ----
    rst_n = 0; @(negedge clk);
    check(irq == 0, "reset clears irq");
    rst_n = 1; peer_on = 0; log_iq = 0;
    repeat (20) @(negedge clk);
    st_is(2'd0, "HUNT after reset");
    cpu_rd(4'd11, r, 0); check(r == 0, "buffer empty after reset");

    if (errors == 0) $display("TEST PASSED: CPRI_v8_0__eCPRI_over_CPR_");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
