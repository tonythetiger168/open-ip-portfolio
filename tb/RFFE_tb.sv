// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for RFFE_top v2.0 (the bus master)
//  * Slaves: two MIPI_RFFE_top (USID 5 and 2, the repository's RFFE slave,
//    32 registers, no long commands) and a slave model of the TB's own
//    (USID 9, 256 registers, long commands, can corrupt a read parity bit).
//    SDATA has a pull-down as the bus holder; two drivers at once is an
//    error.
//  * Line monitor of its own (from SCLK and SDATA): the SSC shape, every
//    frame's parity, bus park cycles, SCLK half periods.
//  * Every command type to every slave, broadcast writes, a slave that is
//    not there (reads 0 with a parity error), the reserved type; register
//    files and every read byte checked against models; write bytes held
//    back (SCLK stalls); read parity errors; every cfg_div; resets in the
//    middle of a sequence.
// ============================================================================
`timescale 1ns/1ps
`include "../rtl/MIPI_RFFE_top.sv"

// RFFE slave model: samples at SCLK falling edges, drives read bits after
// rising edges, full command set including the long commands
module RFFE_tb_slave #(parameter logic [3:0] USID = 4'h9) (
  input  logic clk, rst_n, sclk,
  inout  wire  sdata,
  input  logic corrupt                   // invert the parity bit of read frames
);
  logic [7:0]  mem [0:255];
  logic        sc, sd, drv, dv, ssc_arm;
  int          st;                       // 0 idle, 1 command, 2 address high, 3 address low, 4 write data, 5 bus park, 6 read, 7 park
  int          n, nleft, ri;
  logic [12:0] sh;
  logic [15:0] addr;
  bit          long, rd, ok_par;
  int          n_err;
  logic [8:0]  rf;
  assign sdata = drv ? dv : 1'bz;
  function automatic int idx(input logic [15:0] a); return int'(a[7:0] ^ a[15:8]); endfunction
  initial begin for (int i = 0; i < 256; i++) mem[i] = 8'(i * 11 + 3); n_err = 0; end
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin sc <= 0; sd <= 0; drv <= 0; dv <= 0; st <= 0; ssc_arm <= 0; end
    else begin : b
      logic b0;
      sc <= sclk; sd <= sdata;
      b0 = sdata;
      // SSC: SDATA up and down with SCLK low, not while this slave drives
      if (!sclk && !sc && !drv) begin
        if (!sd && b0) ssc_arm <= 1;
        if (sd && !b0 && ssc_arm) begin st <= 1; n <= 0; sh <= 0; ssc_arm <= 0; end
      end
      if (sclk) ssc_arm <= 0;
      if (sc && !sclk) begin                 // falling edge: sample
        case (st)
          1: begin
            sh <= {sh[11:0], b0}; n <= n + 1;
            if (n == 12) begin : b_c
              logic [12:0] f;
              logic [7:0]  c;
              f = {sh[11:0], b0}; c = f[8:1];
              n <= 0; st <= 0;
              if (!(^f)) n_err++;
              else if (f[12:9] == USID || f[12:9] == 0) begin
                long = 0; rd = 0;
                if (c[7]) mem[0] = {1'b0, c[6:0]};
                else if (c[7:5] == 3'b010) begin addr = c[4:0]; nleft = 0; st <= 4; end
                else if (c[7:5] == 3'b011 && f[12:9] == USID) begin addr = c[4:0]; nleft = 0; rd = 1; st <= 5; end
                else if (c[7:4] == 4'b0000) begin nleft = c[3:0]; st <= 3; end
                else if (c[7:4] == 4'b0010 && f[12:9] == USID) begin nleft = c[3:0]; rd = 1; st <= 3; end
                else if (c[7:4] == 4'b0011 && (!c[3] || f[12:9] == USID)) begin nleft = c[2:0]; rd = c[3]; long = 1; st <= 2; end
              end
            end
          end
          2, 3, 4: begin
            sh <= {sh[11:0], b0}; n <= n + 1;
            if (n == 8) begin : b_f
              logic [8:0] f;
              f = {sh[7:0], b0};
              n <= 0;
              if (!(^f)) begin n_err++; st <= 0; end
              else if (st == 2) begin addr[15:8] = f[8:1]; st <= 3; end
              else if (st == 3) begin addr[7:0] = f[8:1]; if (!long) addr[15:8] = 0; st <= rd ? 5 : 4; end
              else begin
                mem[idx(addr)] = f[8:1];
                if (long) addr++; else addr[7:0]++;
                if (nleft == 0) st <= 0;
                nleft--;
              end
            end
          end
          7: begin drv <= 0; st <= 0; end
          default: ;
        endcase
      end
      if (!sc && sclk) begin                 // rising edge: drive
        if (st == 5) begin st <= 6; ri = 0; rf = {mem[idx(addr)], ~^mem[idx(addr)] ^ corrupt}; end
        else if (st == 6) begin
          drv <= 1;
          if (ri < 9) begin dv <= rf[8 - ri]; ri++; end
          if (ri == 9) begin
            if (long) addr++; else addr[7:0]++;
            if (nleft == 0) st <= 7;
            else begin nleft--; ri = 0; rf = {mem[idx(addr)], ~^mem[idx(addr)] ^ corrupt}; end
          end
        end else if (st == 7) dv <= 0;
      end
    end
endmodule

module RFFE_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 40) $display("ERROR: %s @%0t", m, $time);
  endfunction

  // ---------------- DUT, slaves, bus ----------------
  logic [3:0]  cfg_div = 7;
  logic        cmd_valid = 0, wr_valid = 0;
  logic [2:0]  cmd_type = 0;
  logic [3:0]  cmd_sa = 0, cmd_bc = 0;
  logic [15:0] cmd_addr = 0;
  logic [7:0]  wr_data = 0;
  wire         sclk, sdata_o, sdata_oe, cmd_ready, wr_ready, rd_valid, rd_perr, done, done_perr, busy;
  wire  [7:0]  rd_data;
  tri0         sdata;
  logic        s_rst_n = 0, corrupt = 0;
  wire         irq5, irq2;
  assign sdata = sdata_oe ? sdata_o : 1'bz;
  RFFE_top dut (.clk, .rst_n, .cfg_div, .sclk, .sdata_o, .sdata_oe, .sdata_i(sdata),
    .cmd_valid, .cmd_ready, .cmd_type, .cmd_sa, .cmd_addr, .cmd_bc, .wr_valid, .wr_ready, .wr_data,
    .rd_valid, .rd_data, .rd_perr, .done, .done_perr, .busy);
  MIPI_RFFE_top #(.USID(4'h5)) u_s5 (.clk, .rst_n(s_rst_n), .sclk, .sdata, .irq(irq5));
  MIPI_RFFE_top #(.USID(4'h2)) u_s2 (.clk, .rst_n(s_rst_n), .sclk, .sdata, .irq(irq2));
  RFFE_tb_slave #(.USID(4'h9)) u_s9 (.clk, .rst_n(s_rst_n), .sclk, .sdata, .corrupt);
  bit allow_cont = 0;
  always @(negedge clk)
    if (!allow_cont && int'(sdata_oe) + int'(u_s5.drv_en) + int'(u_s2.drv_en) + int'(u_s9.drv) > 1)
      fail("SDATA driven by two");

  // ---------------- line monitor ----------------
  // checks every SCLK half period, the SSC and the parity of every frame of
  // a sequence, from the pins
  bit          psc = 0;
  int          lo_run = 0, hi_run = 0;
  always @(negedge clk) if (rst_n && s_rst_n) begin
    if (sclk != psc) begin
      if (psc && hi_run != int'(cfg_div) + 1) fail($sformatf("SCLK high for %0d", hi_run));
      hi_run = 0; lo_run = 0;
    end
    if (sclk) hi_run++; else lo_run++;
    psc = sclk;
  end else begin psc = 0; hi_run = 0; lo_run = 0; end

  // ---------------- register file models ----------------
  logic [7:0] m5 [0:31], m2 [0:31], m9 [0:255];
  function automatic int idx9(input logic [15:0] a); return int'(a[7:0] ^ a[15:8]); endfunction
  // expected read bytes, in order: {perr, data}
  logic [8:0] rq [0:1023];
  int         rqh = 0, rqt = 0, n_done = 0, n_rd = 0, dq_h = 0, dq_t = 0;
  bit         dq [0:255];                  // expected done_perr per sequence
  function automatic void w_reg(input logic [3:0] sa, input logic [15:0] a, input logic [7:0] d, input bit long);
    if (sa == 5 || sa == 0) if (a[15:5] == 0) m5[a[4:0]] = d;
    if (sa == 2 || sa == 0) if (a[15:5] == 0) m2[a[4:0]] = d;
    if (sa == 9 || sa == 0) m9[idx9(long ? a : {8'h00, a[7:0]})] = d;
  endfunction
  function automatic logic [8:0] r_reg(input logic [3:0] sa, input logic [15:0] a, input bit long);
    if (sa == 5) return {1'b0, a[15:5] == 0 ? m5[a[4:0]] : 8'h00};
    if (sa == 2) return {1'b0, a[15:5] == 0 ? m2[a[4:0]] : 8'h00};
    if (sa == 9) return {1'b0, m9[idx9(long ? a : {8'h00, a[7:0]})]} ^ {corrupt, 8'h00};
    return 9'h100;                          // nobody drives: 0 with a parity error
  endfunction
  always @(negedge clk) if (rst_n) begin
    if (rd_valid) begin
      n_rd++;
      if (rqh == rqt) fail($sformatf("read byte %h with none expected", rd_data));
      else begin
        if ({rd_perr, rd_data} !== rq[rqh % 1024])
          fail($sformatf("read %b %h, expected %h", rd_perr, rd_data, rq[rqh % 1024]));
        rqh++;
      end
    end
    if (done) begin
      n_done++;
      if (dq_h == dq_t) fail("done with no command");
      else begin
        if (done_perr !== dq[dq_h % 256]) fail($sformatf("done_perr %b", done_perr));
        dq_h++;
      end
    end
  end

  // ---------------- write data host ----------------
  logic [7:0] wq [0:1023];
  int         wqh = 0, wqt = 0, n_stall = 0, wr_delay = 0;
  int         hold = 0, wpat = -1;          // wpat >= 0: every write byte is that value
  always @(negedge clk) if (rst_n) begin
    if (wr_valid && wr_ready) begin wqh++; wr_valid = 0; hold = wr_delay; end
    if (sclk == 0 && dut.st == dut.S_WAIT) n_stall++;
    if (!wr_valid && wqh != wqt) begin
      if (hold > 0) hold--;
      else begin wr_valid = 1; wr_data = wq[wqh % 1024]; end
    end
  end

  // ---------------- commands ----------------
  task automatic cmd(input int ty, input logic [3:0] sa, input logic [15:0] a, input int bc);
    int nb;
    bit perr;
    logic [15:0] ad;
    perr = 0;
    nb = ty == 1 ? 1 : (ty == 3 ? bc + 1 : (ty == 5 ? (bc % 8) + 1 : 0));
    ad = ty == 1 || ty == 2 ? {11'd0, a[4:0]} : (ty == 3 || ty == 4 ? {8'd0, a[7:0]} : a);
    // write bytes, and the model of what the slaves keep
    for (int i = 0; i < nb; i++) begin : b_w
      logic [7:0] d;
      d = wpat >= 0 ? 8'(wpat) : 8'($urandom);
      wq[wqt % 1024] = d; wqt++;
      w_reg(sa, ty == 5 ? ad + 16'(i) : {8'h00, ad[7:0] + 8'(i)}, d, ty == 5);
    end
    if (ty == 0) w_reg(sa, 0, {1'b0, a[6:0]}, 0);
    if (ty == 2 || ty == 4 || ty == 6) begin
      int n;
      n = ty == 2 ? 1 : (ty == 4 ? bc + 1 : (bc % 8) + 1);
      for (int i = 0; i < n; i++) begin : b_r
        logic [8:0] e;
        e = r_reg(sa, ty == 6 ? ad + 16'(i) : {8'h00, ad[7:0] + 8'(i)}, ty == 6);
        rq[rqt % 1024] = e; rqt++;
        if (e[8]) perr = 1;
      end
    end
    dq[dq_t % 256] = perr; dq_t++;
    @(negedge clk);
    while (!cmd_ready) @(negedge clk);
    cmd_valid = 1; cmd_type = 3'(ty); cmd_sa = sa; cmd_addr = a; cmd_bc = 4'(bc);
    @(negedge clk);
    cmd_valid = 0; cmd_type = $urandom; cmd_sa = $urandom; cmd_addr = $urandom; cmd_bc = $urandom;
  endtask
  task automatic wait_done;
    int g;
    g = 0;
    while ((dq_h != dq_t || busy) && g < 400_000) begin @(negedge clk); g++; end
    if (g >= 400_000) fail("sequence did not finish");
  endtask
  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  task automatic check_files;
    for (int i = 0; i < 32; i++) begin
      if (u_s5.mem[i] !== m5[i]) fail($sformatf("slave 5 register %0d = %h, expected %h", i, u_s5.mem[i], m5[i]));
      if (u_s2.mem[i] !== m2[i]) fail($sformatf("slave 2 register %0d = %h, expected %h", i, u_s2.mem[i], m2[i]));
    end
    for (int i = 0; i < 256; i++)
      if (u_s9.mem[i] !== m9[i]) fail($sformatf("slave 9 register %0d = %h, expected %h", i, u_s9.mem[i], m9[i]));
  endtask
  // a random command; long commands only to the slave model, reads not broadcast
  task automatic rnd_cmd;
    int ty, k;
    logic [3:0] sa;
    ty = $urandom % 7;
    k = $urandom % 8;
    sa = k < 3 ? 4'd5 : (k < 5 ? 4'd2 : (k < 7 ? 4'd9 : 4'd0));
    if (ty >= 5) sa = 9;
    if (sa == 0 && (ty == 2 || ty == 4)) sa = 4'd2;
    cmd(ty, sa, $urandom, $urandom % 16);
  endtask

  initial begin
    for (int i = 0; i < 32; i++) begin m5[i] = 0; m2[i] = 0; end
    for (int i = 0; i < 256; i++) m9[i] = 8'(i * 11 + 3);
    #22 rst_n = 1; s_rst_n = 1;
    cycles(10);
    // 1. every command type to every slave, random bus speeds and write delays
    for (int r = 0; r < 4; r++) begin
      cfg_div = r == 0 ? 7 : 4'(7 + $urandom % 9);
      wr_delay = r == 1 ? 400 : (r == 2 ? 0 : $urandom % 3);
      for (int i = 0; i < 25; i++) begin rnd_cmd(); if ($urandom % 3 == 0) wait_done(); end
      wait_done();
      check_files();
    end
    cfg_div = 15;
    // every type, both edges of the byte counts, all-ones and all-zero data
    for (int ty = 0; ty < 7; ty++) begin
      cmd(ty, ty >= 5 ? 4'd9 : 4'd5, 16'hFFFF, 15); wait_done();
      cmd(ty, ty >= 5 ? 4'd9 : 4'd2, 16'h0000, 0); wait_done();
    end
    // a slave that is not there, the reserved type, broadcast
    // (a write and the reserved type right after a failed read: their done_perr is 0)
    cmd(2, 4'd7, 16'h0003, 0); cmd(1, 4'd0, 16'h0004, 0); cmd(4, 4'd11, 16'h0010, 2); cmd(6, 4'd12, 16'h1234, 1);
    cmd(7, 4'd5, 16'h0001, 0); cmd(7, 4'd5, 16'h0001, 0);
    cmd(0, 4'd0, 16'h007F, 0); cmd(3, 4'd0, 16'h0001, 3);
    wait_done(); check_files();
    // read parity errors from the slave model
    corrupt = 1;
    cmd(2, 4'd9, 16'h0005, 0); cmd(6, 4'd9, 16'hA0A0, 3);
    wait_done();
    corrupt = 0;
    cmd(4, 4'd9, 16'h0020, 1); wait_done();
    // the slowest write host: every data frame stalls
    wr_delay = 1000;
    cmd(3, 4'd9, 16'h0040, 5); cmd(5, 4'd9, 16'h4040, 2); cmd(1, 4'd5, 16'h0007, 0);
    wait_done(); check_files();
    wr_delay = 1; cfg_div = 7;
    // 2. resets in the middle of sequences (master and slaves together)
    for (int k = 0; k < 3; k++) begin
      cmd(k == 0 ? 4 : (k == 1 ? 3 : 6), 4'd9, $urandom, 7);
      cycles(300 + 500 * k);
      allow_cont = 1;
      rst_n = 0; s_rst_n = 0;
      cycles(3);
      // the queues restart empty; the slave files keep their contents
      rqh = rqt; dq_h = dq_t; wqh = wqt; wr_valid = 0;
      for (int i = 0; i < 256; i++) m9[i] = u_s9.mem[i];
      for (int i = 0; i < 32; i++) begin m5[i] = 8'h00; m2[i] = 8'h00; end
      rst_n = 1; s_rst_n = 1;
      cycles(5);
      allow_cont = 0;
      cmd(4, 4'd9, 16'h0000, 3); cmd(1, 4'd5, 16'h0002, 0); wait_done();
    end
    for (int i = 0; i < 30; i++) rnd_cmd();
    wait_done(); check_files();

    // functional classes: every type broadcast, write and read data classes
    // per command type (the last command clears the slaves' irq from the
    // broadcast long write they do not support)
    for (int ty = 0; ty < 7; ty++) begin cmd(ty, 4'd0, 16'h1230, 1); wait_done(); end
    for (int p = 0; p < 4; p++) begin
      wpat = p == 0 ? 8'h00 : (p == 1 ? 8'hFF : (p == 2 ? 8'h55 : 8'h3C));
      cmd(1, 4'd9, 16'h0008, 0); cmd(3, 4'd9, 16'h0040, 1); cmd(5, 4'd9, 16'h0140, 1);
      wpat = -1;
      cmd(2, 4'd9, 16'h0008, 0); cmd(4, 4'd9, 16'h0040, 1); cmd(6, 4'd9, 16'h0140, 1);
      wait_done();
    end
    cmd(1, 4'd5, 16'h0003, 0); cmd(1, 4'd2, 16'h0003, 0);
    wait_done(); check_files();

    $display("sequences %0d reads %0d stalls %0d", n_done, n_rd, n_stall);
    if (u_s5.irq || u_s2.irq) fail("a slave saw an error");
    if (u_s9.n_err != 0) fail("the slave model saw a parity error");
    if (errors == 0) $display("TEST PASSED: RFFE");
    else $display("TEST FAILED: RFFE (%0d errors)", errors);
    $finish;
  end
  initial begin #300ms; $display("TEST FAILED: RFFE (timeout)"); $finish; end
endmodule
