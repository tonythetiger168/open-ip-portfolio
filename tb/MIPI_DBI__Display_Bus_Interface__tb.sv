// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for MIPI_DBI__Display_Bus_Interface__top v2.0
//  * A display model decodes the pins of every interface type on its own:
//    Type A (latch on E falling, drive while E high with R/WX = 1), Type B
//    (latch on WRX rising, drive while RDX low), Type C options 1 / 3
//    (sample SDA on SCL rising, drive read bits from SCL falling, dummy
//    clocks before the first read). Every transfer is checked against the
//    op the host issued (D/CX, direction, data, bus width), read data
//    against what the display drove.
//  * Pin checks: CSX low through every transfer and high after op_last;
//    Type A / B data and D/CX stable while the strobe is active; one
//    strobe at a time; SDA released during reads.
//  * Scenarios: random transactions on every type, bus width and phase
//    length (0 and 15 included), every dummy count, back-to-back ops and
//    idle gaps, a configuration change between transactions, reset in the
//    middle of a transfer.
// ============================================================================
`timescale 1ns/1ps
module MIPI_DBI__Display_Bus_Interface__tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 40) $display("ERROR: %s @%0t", m, $time);
  endfunction

  logic [1:0]  cfg_type = 1, cfg_dummy = 0;
  logic        cfg_w16 = 0;
  logic [3:0]  cfg_tw = 1, cfg_tr = 2;
  logic        op_valid = 0, op_dc = 0, op_rd = 0, op_last = 0;
  logic [15:0] op_data = 0;
  wire         op_ready, rd_valid, busy, csx, dcx, wrx, rdx, d_oe, scl, sda_o, sda_oe;
  wire  [15:0] rd_data, d_o;
  logic [15:0] d_i = 0;
  logic        sda_i = 0;

  MIPI_DBI__Display_Bus_Interface__top dut (.*);

  // ---------------- host ----------------
  // expected transfers: {last, w16, rd, dc, data}
  logic [19:0] xq [0:4095];
  int          xh = 0, xt = 0;
  logic [15:0] rq [0:4095];              // read data the display drove
  int          rh = 0, rt = 0, n_ops = 0, n_rd = 0;
  bit          took = 0;
  always @(posedge clk) took <= op_valid && op_ready;
  task automatic op(input bit dc, input bit rd, input bit last, input logic [15:0] d, input int gap);
    repeat (gap) @(negedge clk);
    op_valid = 1; op_dc = dc; op_rd = rd; op_last = last; op_data = d;
    @(negedge clk);
    while (!took) @(negedge clk);
    xq[xt % 4096] = {last, cfg_w16 && !cfg_type[1], rd, dc, d}; xt++;
    n_ops++;
    op_valid = 0; op_dc = $urandom; op_rd = $urandom; op_last = $urandom; op_data = $urandom;
  endtask
  always @(negedge clk) if (rst_n && rd_valid) begin
    if (rh == rt) fail("read data with no read");
    else begin
      if (rd_data !== rq[rh % 4096]) fail($sformatf("read data %h, expected %h", rd_data, rq[rh % 4096]));
      rh++; n_rd++;
    end
  end

  // ---------------- display model ----------------
  logic        p_csx, p_wrx, p_rdx, p_scl;
  logic [15:0] p_d;
  logic        p_dcx;
  int          c_bits, c_dum, c_d0, c_fall;  // Type C: bits seen, dummy left / total, SCL falls
  logic [8:0]  c_sh;
  logic [7:0]  c_rb;                        // byte being read
  bit          c_rd_prev, c_rx, in_x, saw_last;
  int          n_x = 0;
  function automatic logic [19:0] head; return xq[xh % 4096]; endfunction
  // a transfer ended with data dat
  task automatic done(input bit dc, input bit rd, input logic [15:0] dat);
    logic [19:0] h;
    h = head();
    if (xh == xt) fail("transfer with no op");
    else begin
      if (h[17] != rd || h[16] != dc) fail($sformatf("transfer rd %0d dc %0d, op %h", rd, dc, h));
      if (!rd && dat !== (h[18] ? h[15:0] : {8'd0, h[7:0]})) fail($sformatf("write %h, op %h", dat, h));
      saw_last = h[19];
      xh++; n_x++;
    end
  endtask
  function automatic bit rd_now;
    logic [19:0] h;
    h = head();
    return xh != xt && h[17];
  endfunction
  logic [15:0] r_val;
  always @(negedge clk) if (!rst_n) begin
    p_csx = 1; p_wrx = 1; p_rdx = 1; p_scl = 0; p_d = 0; p_dcx = 1; c_bits = 0; c_dum = 0; c_sh = 0;
    c_rb = 0; c_rd_prev = 0; c_rx = 0; c_d0 = 0; c_fall = 0; saw_last = 0; d_i = 0; sda_i = 0; in_x = 0;
  end else begin
    // CSX framing
    if (!csx && p_csx) begin c_rd_prev = 0; if (in_x) fail("CSX fell twice"); end
    if (csx && !p_csx && !saw_last) fail("CSX rose before op_last");
    if (!csx && saw_last && !busy) fail("CSX low after op_last");
    if (csx && p_csx) saw_last = 0;
    case (cfg_type)
      2'd0: begin                           // Type A: wrx = R/WX, rdx = E
        if (rdx && !p_rdx && !csx) begin
          if (wrx) begin r_val = $urandom; rq[rt % 4096] = cfg_w16 ? r_val : {8'd0, r_val[7:0]}; rt++; d_i = r_val; end
          if (d_oe == wrx) fail("bus driven by both or neither");
        end
        if (rdx && (wrx != p_wrx || dcx != p_dcx || (!wrx && d_o != p_d))) fail("R/WX, D/CX or data changed while E high");
        if (!rdx && p_rdx && !p_csx) begin
          done(p_dcx, p_wrx, cfg_w16 ? p_d : {8'd0, p_d[7:0]});
          d_i = $urandom;
        end
      end
      2'd1: begin                           // Type B
        if (!wrx && !rdx) fail("WRX and RDX low together");
        if (((!wrx && p_wrx) || (!rdx && p_rdx)) && csx) fail("strobe with CSX high");
        if ((!wrx && p_wrx) || (!rdx && p_rdx)) begin
          if (d_oe != !wrx) fail("bus direction wrong for the strobe");
        end
        if (!rdx && p_rdx) begin r_val = $urandom; rq[rt % 4096] = cfg_w16 ? r_val : {8'd0, r_val[7:0]}; rt++; d_i = r_val; end
        if ((!wrx || !rdx) && (dcx != p_dcx || (!wrx && d_o != p_d))) fail("D/CX or data changed during the strobe");
        if (wrx && !p_wrx && !p_csx) done(p_dcx, 0, cfg_w16 ? p_d : {8'd0, p_d[7:0]});
        if (rdx && !p_rdx && !p_csx) begin done(p_dcx, 1, 0); d_i = $urandom; end
      end
      default: begin                        // Type C
        if (wrx !== 1'b1 || rdx !== 1'b1 || d_oe) fail("parallel pins active in Type C");
        if (scl && !p_scl) begin
          if (csx) fail("SCL with CSX high");
          if (rd_now()) begin
            if (sda_oe) fail("host drives SDA in a read");
            if (c_dum > 0) c_dum--;
            else begin
              c_bits++;
              if (c_bits == 8) begin
                rq[rt % 4096] = {8'd0, c_rb}; rt++;
                done(dcx, 1, 0); c_bits = 0; c_rd_prev = 1; c_rx = 0;
              end
            end
          end else begin
            if (!sda_oe) fail("SDA not driven in a write");
            c_sh = {c_sh[7:0], sda_o}; c_bits++;
            if (c_bits == (cfg_type == 2'd2 ? 9 : 8)) begin
              done(cfg_type == 2'd2 ? c_sh[8] : dcx, 0, {8'd0, c_sh[7:0]});
              c_bits = 0; c_rd_prev = 0;
            end
          end
        end
        // read bits change on SCL falling: after fall f the next rising edge
        // is dummy f + 1 or data bit f - dummies
        if (!scl && p_scl && c_rx) begin
          c_fall++;
          sda_i = c_fall < c_d0 ? 1'($urandom) : c_rb[7 - (c_fall - c_d0)];
        end
      end
    endcase
    p_csx = csx; p_wrx = wrx; p_rdx = rdx; p_scl = scl; p_d = d_o; p_dcx = dcx;
  end
  // Type C read start: when a read op is taken, set up the dummy clocks and
  // the first bit
  logic op_rd_q, csx_q;
  always @(posedge clk) begin op_rd_q <= op_rd; csx_q <= csx; end
  always @(negedge clk) if (rst_n && took && cfg_type[1] && op_rd_q) begin
    c_d0 = (!c_rd_prev || csx_q) ? int'(cfg_dummy) : 0;
    c_dum = c_d0; c_fall = 0; c_rx = 1;
    c_rb = $urandom; c_bits = 0;
    sda_i = c_d0 > 0 ? 1'($urandom) : c_rb[7];
  end

  // ---------------- scenarios ----------------
  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  task automatic drain;
    int g;
    g = 0;
    while ((busy || xh != xt || rh != rt) && g < 20000) begin @(negedge clk); g++; end
    if (g >= 20000) fail($sformatf("did not drain (%0d transfers, %0d reads left)", xt - xh, rt - rh));
    cycles(3);
  endtask
  // a random transaction: a command, then parameters or reads
  task automatic txn(input int n, input int gapmax);
    bit rd;
    op(0, 0, n == 0, $urandom, $urandom % (gapmax + 1));
    rd = $urandom % 2;
    for (int i = 0; i < n; i++)
      op(1, rd && ($urandom % 4 != 0), i == n - 1, $urandom, $urandom % (gapmax + 1));
  endtask

  initial begin
    #22 rst_n = 1;
    cycles(5);
    for (int t = 0; t < 4; t++) begin
      cfg_type = t;
      for (int w = 0; w < 2; w++) begin
        cfg_w16 = w;
        for (int k = 0; k < 4; k++) begin
          cfg_tw = k == 0 ? 0 : (k == 3 ? 15 : $urandom % 4);
          cfg_tr = k == 1 ? 0 : (k == 2 ? 15 : $urandom % 4);
          cfg_dummy = k;
          for (int i = 0; i < 6; i++) txn($urandom % 6, i < 3 ? 0 : 6);
          drain();
        end
      end
      // transactions that start with a read, after one that ended with a read
      if (t >= 2) begin
        cfg_dummy = 2;
        op(0, 0, 0, 16'h0A, 0); op(1, 1, 1, 0, 0);
        op(1, 1, 0, 0, 0); op(1, 1, 1, 0, 3);
        drain();
      end
      // all-ones and all-zeros data
      op(0, 0, 0, 16'hFFFF, 0); op(1, 0, 0, 16'h0000, 0); op(1, 0, 1, 16'hFFFF, 0);
      drain();
    end
    // reset in the middle of a transfer
    cfg_type = 1; cfg_tw = 5;
    fork op(0, 0, 0, 16'h2C, 0); join_none
    cycles(6);
    rst_n = 0; cycles(2);
    disable fork;
    op_valid = 0; xh = xt; rh = rt;
    rst_n = 1; cycles(3);
    cfg_type = 3; txn(3, 2); drain();
    $display("ops %0d transfers %0d reads %0d", n_ops, n_x, n_rd);
    if (errors == 0) $display("TEST PASSED: MIPI_DBI");
    else $display("TEST FAILED: MIPI_DBI (%0d errors)", errors);
    $finish;
  end
  initial begin #20ms; $display("TEST FAILED: MIPI_DBI (timeout)"); $finish; end
endmodule
