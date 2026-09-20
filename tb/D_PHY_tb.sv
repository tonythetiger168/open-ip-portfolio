// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for D_PHY_top (MIPI D-PHY lane pair TX + RX decode)
// The TB plays the host (HS byte stream / escape requests) and loops the
// data-lane TX pads back into the same-lane RX decoder through an injection
// mux, so protocol errors can be driven directly onto the lane.
// Checks:
//   1. reset state: both lanes LP-11, HS drivers off, irq low
//   2. HS burst of 4 bytes: wire-level SoT (LP-01 -> LP-00 -> HS-0),
//      sync pattern 00011101 (8'hB8 LSB-first), payload bits LSB-first,
//      EoT (last bit inverted + hold + LP-11) -- all compared per bit;
//      clock lane HS enable + toggle; RX loopback bytes compared
//   3. second HS burst back-to-back (1 byte) after hs_tx_done
//   4. escape LPDT: entry LP-10/00/01/00 + cmd 8'h87 wire compare,
//      2 LPDT bytes looped back and compared, exit space/Mark-1/LP-11
//   5. escape ULPS: rx_ulps observed, esc_release exits to LP-11
//   6. escape Trigger-Reset 8'h46: Mark-1 hold + exit sequence
//   7. error injection: unknown escape command 8'h00 -> irq, irq_clear
//   8. error injection: bad HS sync byte -> irq, no RX bytes, irq_clear
// ============================================================================
`timescale 1ns/1ps
module D_PHY_tb;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // host interface
  logic       hs_req = 0;
  logic [7:0] hs_tx_data = 0;
  logic       hs_tx_valid = 0;
  wire        hs_tx_ready;
  wire        hs_tx_done;
  logic       esc_req = 0;
  logic [7:0] esc_cmd = 0;
  logic       esc_release = 0;
  logic [7:0] lpdt_data = 0;
  logic       lpdt_valid = 0;
  logic       lpdt_last = 0;
  wire        lpdt_ready;
  wire        esc_done;
  logic       irq_clear = 0;
  wire        irq;

  // data lane TX pads
  wire d_lp_p, d_lp_n, d_hs_p, d_hs_n, d_hs_en;
  // clock lane pads
  wire c_lp_p, c_lp_n, c_hs_p, c_hs_n, c_hs_en;

  // injection mux: TB can seize the lane feeding the RX decoder
  logic       inj = 0;
  logic       i_lp_p = 1, i_lp_n = 1;
  logic       i_hs_p = 0, i_hs_n = 1, i_hs_en = 0;
  wire r_lp_p  = inj ? i_lp_p  : d_lp_p;
  wire r_lp_n  = inj ? i_lp_n  : d_lp_n;
  wire r_hs_p  = inj ? i_hs_p  : d_hs_p;
  wire r_hs_n  = inj ? i_hs_n  : d_hs_n;
  wire r_hs_en = inj ? i_hs_en : d_hs_en;

  // RX decode outputs
  wire       rx_hs_active;
  wire [7:0] rx_data;
  wire       rx_data_valid;
  wire [7:0] rx_esc_cmd;
  wire       rx_esc_valid;
  wire       rx_ulps;

  int errors = 0;

  D_PHY_top #(.DW(32), .AW(32)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .hs_req(hs_req), .hs_tx_data(hs_tx_data), .hs_tx_valid(hs_tx_valid),
    .hs_tx_ready(hs_tx_ready), .hs_tx_done(hs_tx_done),
    .esc_req(esc_req), .esc_cmd(esc_cmd), .esc_release(esc_release),
    .lpdt_data(lpdt_data), .lpdt_valid(lpdt_valid), .lpdt_last(lpdt_last),
    .lpdt_ready(lpdt_ready), .esc_done(esc_done),
    .d_lp_p(d_lp_p), .d_lp_n(d_lp_n),
    .d_hs_p(d_hs_p), .d_hs_n(d_hs_n), .d_hs_en(d_hs_en),
    .c_lp_p(c_lp_p), .c_lp_n(c_lp_n),
    .c_hs_p(c_hs_p), .c_hs_n(c_hs_n), .c_hs_en(c_hs_en),
    .r_lp_p(r_lp_p), .r_lp_n(r_lp_n),
    .r_hs_p(r_hs_p), .r_hs_n(r_hs_n), .r_hs_en(r_hs_en),
    .rx_hs_active(rx_hs_active), .rx_data(rx_data),
    .rx_data_valid(rx_data_valid), .rx_esc_cmd(rx_esc_cmd),
    .rx_esc_valid(rx_esc_valid), .rx_ulps(rx_ulps)
  );

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (time %0t)", msg, $time);
    end
  endtask

  // expected payload bytes (shared by sender + monitor)
  logic [7:0] exp_bytes [0:63];
  int         exp_n;
  logic [7:0] exp_esc;

  // RX capture queues (plain arrays: iverilog-safe)
  logic [7:0] rxq [0:63];
  int         rxn = 0;
  logic [7:0] escq [0:15];
  int         escn = 0;
  int         rxn_mark, escn_mark;

  always @(posedge clk) begin
    if (rx_data_valid) begin
      rxq[rxn] = rx_data;
      rxn = rxn + 1;
    end
    if (rx_esc_valid) begin
      escq[escn] = rx_esc_cmd;
      escn = escn + 1;
    end
  end

  task automatic mark_rx;
    begin rxn_mark = rxn; escn_mark = escn; end
  endtask

  // compare bytes captured since mark
  task automatic check_rxq(input int n, input string tag);
    for (int i = 0; i < n; i++)
      check(rxq[rxn_mark + i] === exp_bytes[i],
            $sformatf("%s: rx byte %0d got=%h exp=%h",
                      tag, i, rxq[rxn_mark + i], exp_bytes[i]));
    check(rxn - rxn_mark === n,
          $sformatf("%s: rx byte count got=%0d exp=%0d", tag, rxn - rxn_mark, n));
  endtask

  // ------------------------------------------------------------------
  // host sender tasks
  // ------------------------------------------------------------------
  task automatic hs_push(input logic [7:0] b);
    begin
      @(negedge clk);
      hs_tx_data <= b;
      hs_tx_valid <= 1'b1;
      @(posedge clk);
      while (hs_tx_ready !== 1'b1) @(posedge clk);   // accepted at this edge
      @(negedge clk);
      hs_tx_valid <= 1'b0;
    end
  endtask

  // caller must ensure the lane is idle (LP-11) before calling
  task automatic hs_send(input int n);
    begin
      @(negedge clk);
      hs_req <= 1'b1;
      @(negedge clk);
      hs_req <= 1'b0;
      for (int i = 0; i < n; i++) hs_push(exp_bytes[i]);
    end
  endtask

  task automatic lpdt_push(input logic [7:0] b, input bit last);
    begin
      @(negedge clk);
      lpdt_data  <= b;
      lpdt_last  <= last;
      lpdt_valid <= 1'b1;
      @(posedge clk);
      while (lpdt_ready !== 1'b1) @(posedge clk);
      @(negedge clk);
      lpdt_valid <= 1'b0;
      lpdt_last  <= 1'b0;
    end
  endtask

  task automatic esc_start(input logic [7:0] cmd);
    begin
      @(negedge clk);
      esc_cmd <= cmd;
      esc_req <= 1'b1;
      @(negedge clk);
      esc_req <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // wire-level monitor tasks (sample on negedge: pads are stable)
  // ------------------------------------------------------------------
  task automatic mon_hs;
    logic [7:0] sh;
    logic       lb;
    logic       cprev;
    begin
      // SoT: LP-01 (HS request) -> LP-00 (bridge) -> HS-0
      do @(negedge clk); while ({d_lp_p, d_lp_n} !== 2'b01);
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "HS SoT: LP-00 bridge after LP-01");
      @(negedge clk);
      check(d_hs_en === 1'b1 && d_hs_p === 1'b0 && d_hs_n === 1'b1,
            "HS SoT: HS-0 differential entry");
      check(c_hs_en === 1'b1, "HS SoT: clock lane HS enabled");
      // sync byte 8'hB8 LSB-first
      sh = 8'h00;
      cprev = c_hs_p;
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        check(d_hs_en === 1'b1, "HS sync: driver still enabled");
        check(d_hs_n === ~d_hs_p, "HS sync: differential levels");
        sh = {d_hs_p, sh[7:1]};
        if (i == 1) check(c_hs_p !== cprev, "HS clock lane toggling");
        cprev = c_hs_p;
      end
      check(sh === 8'hB8, $sformatf("HS sync byte got=%h exp=B8", sh));
      check(rx_hs_active === 1'b1, "rx_hs_active during payload");
      // payload bytes
      for (int b = 0; b < exp_n; b++) begin
        sh = 8'h00;
        for (int i = 0; i < 8; i++) begin
          @(negedge clk);
          check(d_hs_en === 1'b1, "HS data: driver enabled");
          sh = {d_hs_p, sh[7:1]};
        end
        check(sh === exp_bytes[b],
              $sformatf("HS wire byte %0d got=%h exp=%h", b, sh, exp_bytes[b]));
      end
      lb = d_hs_p;
      // EoT: last bit inverted, then held, then LP-11
      @(negedge clk);
      check(d_hs_en === 1'b1 && d_hs_p === ~lb, "HS EoT: last bit inverted");
      @(negedge clk);
      check(d_hs_en === 1'b1 && d_hs_p === lb, "HS EoT: last level held");
      @(negedge clk);
      check(d_hs_en === 1'b0 && {d_lp_p, d_lp_n} === 2'b11,
            "HS EoT: return to LP-11");
    end
  endtask

  // escape entry + command; leaves the lane right after the command byte
  task automatic mon_esc_entry;
    logic [7:0] sh;
    begin
      do @(negedge clk); while ({d_lp_p, d_lp_n} !== 2'b10);
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "ESC entry: LP-00 after LP-10");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b01, "ESC entry: LP-01");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "ESC entry: LP-00");
      sh = 8'h00;
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        check(({d_lp_p, d_lp_n} === 2'b10) || ({d_lp_p, d_lp_n} === 2'b00),
              "ESC cmd: bit level is LP-10/LP-00");
        sh = {d_lp_p, sh[7:1]};
      end
      check(sh === exp_esc,
            $sformatf("ESC cmd on wire got=%h exp=%h", sh, exp_esc));
    end
  endtask

  // LPDT bytes + exit (call right after mon_esc_entry)
  task automatic mon_lpdt_exit;
    logic [7:0] sh;
    begin
      for (int b = 0; b < exp_n; b++) begin
        sh = 8'h00;
        for (int i = 0; i < 8; i++) begin
          @(negedge clk);
          check(({d_lp_p, d_lp_n} === 2'b10) || ({d_lp_p, d_lp_n} === 2'b00),
                "LPDT: bit level is LP-10/LP-00");
          sh = {d_lp_p, sh[7:1]};
        end
        check(sh === exp_bytes[b],
              $sformatf("LPDT wire byte %0d got=%h exp=%h", b, sh, exp_bytes[b]));
      end
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b01, "LPDT exit: LP-01 space");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b10, "LPDT exit: LP-10 Mark-1");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b11, "LPDT exit: LP-11 stop");
    end
  endtask

  // ULPS phase + exit (call right after mon_esc_entry)
  task automatic mon_ulps_exit;
    begin
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "ULPS: lines held LP-00");
      do @(negedge clk); while ({d_lp_p, d_lp_n} !== 2'b10);
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b11, "ULPS exit: LP-11 stop");
    end
  endtask

  // Trigger Mark-1 + exit (call right after mon_esc_entry)
  task automatic mon_trig_exit;
    begin
      for (int i = 0; i < 4; i++) begin
        @(negedge clk);
        check({d_lp_p, d_lp_n} === 2'b00, "Trigger: Mark-1 hold LP-00");
      end
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b10, "Trigger exit: LP-10");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b11, "Trigger exit: LP-11 stop");
    end
  endtask

  // ------------------------------------------------------------------
  // lane injection tasks (1 clk per level/bit)
  // ------------------------------------------------------------------
  task automatic inj_lp(input logic [1:0] lv);
    begin
      @(negedge clk);
      i_lp_p <= lv[1];
      i_lp_n <= lv[0];
    end
  endtask

  task automatic inj_hs_bit(input logic b);
    begin
      @(negedge clk);
      i_hs_en <= 1'b1;
      i_hs_p  <= b;
      i_hs_n  <= ~b;
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
    check({d_lp_p, d_lp_n} === 2'b11, "reset: data lane LP-11");
    check({c_lp_p, c_lp_n} === 2'b11, "reset: clock lane LP-11");
    check(d_hs_en === 1'b0 && c_hs_en === 1'b0, "reset: HS drivers off");
    check(irq === 1'b0, "reset: irq low");

    // ---- check 2: HS burst, 4 bytes, wire + loopback compare ----
    exp_bytes[0] = 8'h11;
    exp_bytes[1] = 8'h22;
    exp_bytes[2] = 8'h33;
    exp_bytes[3] = 8'h44;
    exp_n = 4;
    mark_rx;
    fork
      hs_send(4);
      mon_hs;
    join
    repeat (2) @(negedge clk);
    check_rxq(4, "HS burst #1 loopback");

    // ---- check 3: back-to-back HS burst, 1 byte ----
    exp_bytes[0] = 8'hA5;
    exp_n = 1;
    mark_rx;
    fork
      hs_send(1);
      mon_hs;
    join
    repeat (2) @(negedge clk);
    check_rxq(1, "HS burst #2 loopback");

    // ---- check 4: escape LPDT (cmd 8'h87 + 2 data bytes) ----
    exp_esc = 8'h87;
    exp_bytes[0] = 8'h96;
    exp_bytes[1] = 8'h3C;
    exp_n = 2;
    mark_rx;
    fork
      begin
        esc_start(8'h87);
        lpdt_push(8'h96, 0);
        lpdt_push(8'h3C, 1);
        @(posedge esc_done);
      end
      begin
        mon_esc_entry;
        mon_lpdt_exit;
      end
    join
    repeat (2) @(negedge clk);
    check_rxq(2, "LPDT loopback");
    check(escn - escn_mark === 1 && escq[escn_mark] === 8'h87,
          "LPDT: rx escape command 8'h87 decoded");

    // ---- check 5: escape ULPS ----
    exp_esc = 8'h78;
    mark_rx;
    fork
      begin
        esc_start(8'h78);
        wait (rx_ulps === 1'b1);
        check(rx_ulps === 1'b1, "ULPS: rx_ulps raised");
        repeat (4) @(negedge clk);
        esc_release <= 1'b1;
        @(negedge clk);
        esc_release <= 1'b0;
        @(posedge esc_done);
        @(negedge clk);
        check(rx_ulps === 1'b0, "ULPS: rx_ulps cleared after exit");
      end
      begin
        mon_esc_entry;
        mon_ulps_exit;
      end
    join
    check(escn - escn_mark === 1 && escq[escn_mark] === 8'h78,
          "ULPS: rx escape command 8'h78 decoded");

    // ---- check 6: escape Trigger-Reset ----
    exp_esc = 8'h46;
    mark_rx;
    fork
      begin
        esc_start(8'h46);
        @(posedge esc_done);
      end
      begin
        mon_esc_entry;
        mon_trig_exit;
      end
    join
    check(escn - escn_mark === 1 && escq[escn_mark] === 8'h46,
          "Trigger: rx escape command 8'h46 decoded");

    // ---- check 7: inject unknown escape command 8'h00 -> irq ----
    mark_rx;
    @(negedge clk);
    inj <= 1'b1;
    i_hs_en <= 1'b0;
    inj_lp(2'b10);                 // entry: LP-10
    inj_lp(2'b00);                 // LP-00
    inj_lp(2'b01);                 // LP-01
    inj_lp(2'b00);                 // LP-00
    for (int i = 0; i < 8; i++) inj_lp(2'b00);  // cmd = 8'h00 (unknown)
    inj_lp(2'b01);                 // exit space
    inj_lp(2'b10);                 // Mark-1
    inj_lp(2'b11);                 // stop
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: unknown escape cmd raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared by irq_clear");

    // ---- check 8: inject bad HS sync byte -> irq ----
    mark_rx;
    @(negedge clk);
    inj <= 1'b1;
    inj_lp(2'b01);                 // LP-01 HS request
    inj_lp(2'b00);                 // LP-00 bridge
    inj_hs_bit(1'b0);              // HS-0
    for (int i = 0; i < 8; i++) inj_hs_bit(1'b0);  // sync = 8'h00 (bad)
    @(negedge clk);
    i_hs_en <= 1'b0;               // back to LP-11
    i_lp_p  <= 1'b1;
    i_lp_n  <= 1'b1;
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: bad HS sync raises irq");
    check(rxn === rxn_mark, "bad HS sync: no payload byte decoded");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;

    repeat (4) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: D-PHY");
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
