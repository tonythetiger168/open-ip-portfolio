// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for C_PHY_top (MIPI C-PHY trio TX + RX decode)
// The TB plays the host (16-bit word stream) and loops the trio TX pads
// back into the RX decoder through an injection mux. It implements the same
// 16-bit -> 7 symbol mapping table as the DUT and compares every symbol on
// the wires.
// Checks:
//   1. reset state: trio idle (mid,mid,mid), irq low, tx_ready high
//   2. packet of 4 words (0000/FFFF/1234/BEEF): sync word + every data
//      symbol compared on the wires (same mapping table; 16'hFFFF exercises
//      the X collision marker), RX loopback words compared, rx_done pulse
//   3. back-to-back second packet (2 words) right after tx_done
//   4. error injection: adjacent identical symbols on the trio -> irq
//   5. error injection: illegal wire state (two wires equal level) -> irq
//   6. irq_clear clears the sticky flag after each injection
// ============================================================================
`timescale 1ns/1ps
module C_PHY_tb;

  localparam logic [1:0] LVL_L = 2'b00;
  localparam logic [1:0] LVL_M = 2'b01;
  localparam logic [1:0] LVL_H = 2'b10;

  localparam logic [5:0] ST_S0 = {LVL_L, LVL_M, LVL_H};
  localparam logic [5:0] ST_S1 = {LVL_L, LVL_H, LVL_M};
  localparam logic [5:0] ST_S2 = {LVL_M, LVL_L, LVL_H};
  localparam logic [5:0] ST_S3 = {LVL_M, LVL_H, LVL_L};
  localparam logic [5:0] ST_S4 = {LVL_H, LVL_L, LVL_M};
  localparam logic [5:0] ST_X  = {LVL_H, LVL_M, LVL_L};
  localparam logic [5:0] ST_MID = {LVL_M, LVL_M, LVL_M};

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // host interface
  logic [15:0] tx_data = 0;
  logic        tx_valid = 0;
  wire         tx_ready;
  logic        tx_last = 0;
  wire         tx_done;
  logic        irq_clear = 0;
  wire         irq;

  // trio TX pads
  wire [1:0] t_a, t_b, t_c;

  // injection mux
  logic       inj = 0;
  logic [1:0] i_a = LVL_M, i_b = LVL_M, i_c = LVL_M;
  wire [1:0] r_a = inj ? i_a : t_a;
  wire [1:0] r_b = inj ? i_b : t_b;
  wire [1:0] r_c = inj ? i_c : t_c;

  // RX decode outputs
  wire        rx_active;
  wire [15:0] rx_data;
  wire        rx_valid;
  wire        rx_done;

  int errors = 0;

  C_PHY_top #(.DW(32), .AW(32)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_last(tx_last), .tx_done(tx_done),
    .t_a(t_a), .t_b(t_b), .t_c(t_c),
    .r_a(r_a), .r_b(r_b), .r_c(r_c),
    .rx_active(rx_active), .rx_data(rx_data), .rx_valid(rx_valid),
    .rx_done(rx_done)
  );

  // ------------------------------------------------------------------
  // helpers + the same mapping table as the DUT
  // ------------------------------------------------------------------
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (time %0t)", msg, $time);
    end
  endtask

  function automatic logic [5:0] state_abc(input int k);
    case (k)
      0: state_abc = ST_S0;
      1: state_abc = ST_S1;
      2: state_abc = ST_S2;
      3: state_abc = ST_S3;
      default: state_abc = ST_S4;
    endcase
  endfunction

  function automatic logic [5:0] sync_sym(input int i);
    case (i)
      0: sync_sym = ST_S1;
      1: sync_sym = ST_S3;
      2: sync_sym = ST_S0;
      3: sync_sym = ST_S2;
      4: sync_sym = ST_S4;
      5: sync_sym = ST_S1;
      default: sync_sym = ST_X;
    endcase
  endfunction

  function automatic int pow5(input int i);
    case (i)
      0: pow5 = 1;
      1: pow5 = 5;
      2: pow5 = 25;
      3: pow5 = 125;
      4: pow5 = 625;
      5: pow5 = 3125;
      default: pow5 = 15625;
    endcase
  endfunction

  // expected wire-symbol sequence for the whole packet
  logic [5:0]  exp_sym [0:255];
  int          exp_len;
  logic [15:0] exp_words [0:31];
  int          exp_nw;

  // build expected symbols: sync + 7 per word (same table as DUT)
  task automatic build_exp;
    logic [5:0] prev, cand;
    int d, k;
    begin
      exp_len = 0;
      for (int i = 0; i < 7; i++) exp_sym[exp_len++] = sync_sym(i);
      prev = sync_sym(6);
      for (int w = 0; w < exp_nw; w++) begin
        for (int i = 0; i < 7; i++) begin
          d = (exp_words[w] / pow5(i)) % 5;
          k = (d + i) % 5;
          cand = state_abc(k);
          if (cand == prev) exp_sym[exp_len] = ST_X;
          else              exp_sym[exp_len] = cand;
          prev = exp_sym[exp_len];
          exp_len++;
        end
      end
    end
  endtask

  // RX capture
  logic [15:0] rxq [0:63];
  int          rxn = 0;
  int          dones = 0;
  int          rxn_mark, done_mark;

  always @(posedge clk) begin
    if (rx_valid) begin
      rxq[rxn] = rx_data;
      rxn = rxn + 1;
    end
    if (rx_done) dones = dones + 1;
  end

  // acceptance flag for the word stream handshake
  logic acc_tx;
  always @(posedge clk) acc_tx <= tx_valid & tx_ready;

  task automatic tx_push(input logic [15:0] w, input bit last);
    begin
      @(negedge clk);
      tx_data  <= w;
      tx_last  <= last;
      tx_valid <= 1'b1;
      do @(negedge clk); while (acc_tx !== 1'b1);
      tx_valid <= 1'b0;
      tx_last  <= 1'b0;
    end
  endtask

  task automatic send_pkt;
    begin
      for (int w = 0; w < exp_nw; w++)
        tx_push(exp_words[w], w == exp_nw - 1);
    end
  endtask

  // wire-level monitor: every symbol of the packet + return to idle
  task automatic mon_pkt;
    begin
      do @(negedge clk); while ({t_a, t_b, t_c} === ST_MID);
      check({t_a, t_b, t_c} === exp_sym[0],
            $sformatf("sym 0 (sync) got=%b exp=%b", {t_a, t_b, t_c}, exp_sym[0]));
      for (int i = 1; i < exp_len; i++) begin
        @(negedge clk);
        check({t_a, t_b, t_c} === exp_sym[i],
              $sformatf("sym %0d got=%b exp=%b", i, {t_a, t_b, t_c}, exp_sym[i]));
        if (i == 2)
          check(rx_active === 1'b1, "rx_active during packet");
        if (i > 0)
          check({t_a, t_b, t_c} !== exp_sym[i-1],
                $sformatf("sym %0d equals previous symbol (change rule)", i));
      end
      @(negedge clk);
      check({t_a, t_b, t_c} === ST_MID, "packet end: trio back to idle");
    end
  endtask

  task automatic check_rxq(input string tag);
    for (int i = 0; i < exp_nw; i++)
      check(rxq[rxn_mark + i] === exp_words[i],
            $sformatf("%s: rx word %0d got=%h exp=%h",
                      tag, i, rxq[rxn_mark + i], exp_words[i]));
    check(rxn - rxn_mark === exp_nw,
          $sformatf("%s: rx word count got=%0d exp=%0d",
                    tag, rxn - rxn_mark, exp_nw));
    check(dones - done_mark === 1, $sformatf("%s: rx_done pulse", tag));
  endtask

  // drive one symbol onto the trio through the injection mux
  task automatic inj_sym(input logic [5:0] s);
    begin
      @(negedge clk);
      i_a <= s[5:4];
      i_b <= s[3:2];
      i_c <= s[1:0];
    end
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  initial begin
    // ---- reset ----
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // check 1: reset state
    check({t_a, t_b, t_c} === ST_MID, "reset: trio idle (mid,mid,mid)");
    check(irq === 1'b0, "reset: irq low");
    check(tx_ready === 1'b1, "reset: tx_ready high");

    // ---- check 2: packet #1, 4 words, wire + loopback compare ----
    exp_words[0] = 16'h0000;
    exp_words[1] = 16'hFFFF;   // exercises the X collision marker
    exp_words[2] = 16'h1234;
    exp_words[3] = 16'hBEEF;
    exp_nw = 4;
    build_exp;
    rxn_mark = rxn; done_mark = dones;
    fork
      send_pkt;
      mon_pkt;
    join
    repeat (2) @(negedge clk);
    check_rxq("packet #1");

    // ---- check 3: back-to-back packet #2 ----
    exp_words[0] = 16'h5555;
    exp_words[1] = 16'hAAAA;
    exp_nw = 2;
    build_exp;
    rxn_mark = rxn; done_mark = dones;
    fork
      send_pkt;
      mon_pkt;
    join
    repeat (2) @(negedge clk);
    check_rxq("packet #2 (back-to-back)");

    // ---- check 4: inject adjacent identical symbols -> irq ----
    @(negedge clk);
    inj <= 1'b1;
    for (int i = 0; i < 7; i++) inj_sym(sync_sym(i));  // valid sync
    inj_sym(ST_S2);                                    // data symbol
    inj_sym(ST_S2);                                    // repeated -> violation
    inj_sym(ST_MID);                                   // back to idle
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: repeated symbol raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared by irq_clear");

    // ---- check 5: inject illegal wire state (a=b=high) -> irq ----
    @(negedge clk);
    inj <= 1'b1;
    for (int i = 0; i < 7; i++) inj_sym(sync_sym(i));
    inj_sym(ST_S2);
    inj_sym({LVL_H, LVL_H, LVL_L});                    // two wires equal
    inj_sym(ST_MID);
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: illegal wire state raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared after illegal-state injection");

    // ---- check 6: normal packet still works after error recovery ----
    exp_words[0] = 16'h0F0F;
    exp_nw = 1;
    build_exp;
    rxn_mark = rxn; done_mark = dones;
    fork
      send_pkt;
      mon_pkt;
    join
    repeat (2) @(negedge clk);
    check_rxq("packet #3 (post-error)");

    repeat (4) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: C-PHY");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #200000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
