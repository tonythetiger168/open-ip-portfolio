// SPDX-License-Identifier: Apache-2.0
// ONFI_top testbench: a NAND target model on the pins and a host model on
// the command and data streams.
//  - the target decodes command, address and data cycles on WE# rising,
//    drives DQ while RE# is low and advances on RE# rising, holds R/B# low
//    for a random time after Reset, Read Page (30h), Program (10h), Erase
//    (D0h) and the features commands, and keeps its own array, page
//    register and feature store. It checks the pin rules: CLE and ALE never
//    together, WE# and RE# never low together, CE# low around every cycle,
//    WE# / RE# low and high for at least TP clocks, tWHR, tADL and tRR,
//    the address cycle count of each command, and no cycle while it is busy
//    other than Read Status
//  - the host keeps a reference array (programming clears bits, erase sets
//    a block to FFh, a failed operation changes nothing) and checks every
//    byte read, the status, ev_fail and ev_timeout of each command
//  - the target can report FAIL, add noise in the status bits it does not
//    define, and stay busy past the controller's timeout (the host then
//    reads the status while the target is busy); the data streams stall at
//    random; a reset lands in the middle of a Program
// The bound checker (tb/cov/ONFI_sva.sv) checks the pins and the host side
// on every clock against its own model of each command's cycles.
`timescale 1ns/1ps
module ONFI_tb;
  localparam int TP = 2, TWB = 6, TWHR = 8, TADL = 10, TRR = 3, TBUSY = 2048, LW = 12;
  localparam int PSZ = 4096, NPG = 32;           // the target: 8 blocks of 4 pages of 4 KiB
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic          cmd_valid = 0, wr_valid = 0, rd_ready = 0, rb_n = 1;
  logic [2:0]    cmd_op = 0;
  logic [23:0]   cmd_row = 0;
  logic [15:0]   cmd_col = 0;
  logic [LW-1:0] cmd_len = 0;
  logic [7:0]    wr_data = 0, dq_i = 0;
  wire           cmd_ready, wr_ready, rd_valid, done, ev_fail, ev_timeout, ce_n, cle, ale, we_n, re_n, dq_oe;
  wire  [7:0]    rd_data, status, dq_o;

  ONFI_top #(.TP(TP), .TWB(TWB), .TWHR(TWHR), .TADL(TADL), .TRR(TRR), .TBUSY(TBUSY), .LW(LW)) dut (.*);

  // ---------------- target ----------------
  logic [7:0] fl [0:NPG*PSZ-1];
  logic [7:0] preg [0:PSZ-1];
  logic [7:0] ft [0:1023];                       // 256 feature addresses of 4 bytes
  logic [7:0] ab [0:4];
  logic [7:0] fb [0:3];
  logic [7:0] id_bytes [0:4];
  logic [7:0] onfi_sig [0:3];
  // mode: 0 none, 1 ID addr, 2 ID out, 3 status, 4 read addr, 5 page out, 6 program addr/data,
  //       7 erase addr, 8 get-features addr, 9 features out, 10 set-features addr/data
  int         mode = 0, na = 0, ptr = 0, nd = 0, busy_left = 0, pend = 0;
  logic [7:0] st_noise = 0;
  bit         t_fail = 0, nx_fail = 0, nx_slow = 0;
  int         busy_min = 3, busy_max = 40;
  bit         p_we = 1, p_re = 1, p_rb = 1;
  int         t_we = 0, t_re = 0, t_lastca = -1000, t_rdy = -1000, cyc = 0, n_we_lo = 0, n_re_lo = 0;
  int         t_hi_we = 100, t_hi_re = 100;
  int         n_bad = 0;
  logic [7:0] dev_status;
  assign dev_status = {1'b1, rb_n, rb_n, st_noise[4:1], t_fail};

  function automatic int pg(input logic [7:0] r0, input logic [7:0] r1);
    return {r1, r0} % NPG;
  endfunction
  task automatic go_busy(input int what);
    busy_left = nx_slow ? TBUSY + 600 : busy_min + $urandom % (busy_max - busy_min + 1);
    pend = what;
    nx_slow = 0;
  endtask
  // what the target does when it becomes ready
  task automatic finish_op();
    int p;
    case (pend)
      1: begin                                   // read page
        p = pg(ab[2], ab[3]);
        for (int i = 0; i < PSZ; i++) preg[i] = fl[p * PSZ + i];
        mode = 5; ptr = {ab[1], ab[0]} % PSZ;
      end
      2: begin                                   // program
        p = pg(ab[2], ab[3]);
        t_fail = nx_fail;
        if (!nx_fail) for (int i = 0; i < PSZ; i++) fl[p * PSZ + i] = fl[p * PSZ + i] & preg[i];
        nx_fail = 0;
        mode = 0;
      end
      3: begin                                   // erase
        p = pg(ab[0], ab[1]) & ~3;
        t_fail = nx_fail;
        if (!nx_fail) for (int i = 0; i < 4 * PSZ; i++) fl[p * PSZ + i] = 8'hFF;
        nx_fail = 0;
        mode = 0;
      end
      4: begin mode = 9; ptr = 0; end            // get features
      5: begin for (int i = 0; i < 4; i++) ft[ab[0] * 4 + i] = fb[i]; mode = 0; end
      default: mode = 0;                         // reset
    endcase
    pend = 0;
  endtask
  function automatic logic [7:0] dev_out();
    case (mode)
      2: return ab[0] == 8'h20 ? onfi_sig[ptr % 4] : id_bytes[ptr % 5];
      3: return dev_status;
      5: return preg[ptr % PSZ];
      9: return ft[ab[0] * 4 + ptr % 4];
      default: begin
        errors++;
        $display("ERROR: RE# with nothing to read (mode %0d) @%0t", mode, $time);
        return 8'h00;
      end
    endcase
  endfunction

  int k;
  always @(posedge clk) begin
    cyc++;
    if (!rst_n) begin
      p_we = 1; p_re = 1; mode = 0; busy_left = 0; pend = 0;
    end else begin
      // pin rules
      if (cle && ale) fail("CLE and ALE together");
      if (!we_n && !re_n) fail("WE# and RE# low together");
      if ((!we_n || !re_n) && ce_n) fail("WE# / RE# low with CE# high");
      if (!we_n && !dq_oe) fail("WE# low with DQ not driven");
      if (!re_n && dq_oe) fail("RE# low with DQ driven");
      if (we_n != p_we) begin
        if (!we_n && cyc - t_we < TP) fail("WE# high too short");
        if (we_n && cyc - t_we < TP) fail("WE# low too short");
        t_we = cyc;
      end
      if (re_n != p_re) begin
        if (!re_n && cyc - t_re < TP) fail("RE# high too short");
        if (re_n && cyc - t_re < TP) fail("RE# low too short");
        if (!re_n && cyc - t_lastca < TWHR) fail("tWHR");
        if (!re_n && cyc - t_rdy < TRR) fail("tRR");
        if (!re_n && !rb_n && mode != 3) fail("RE# while busy");
        t_re = cyc;
      end
      // a cycle latched on WE# rising
      if (we_n && !p_we) begin
        if (!rb_n && !(cle && dq_o == 8'h70)) fail($sformatf("cycle while busy (%h)", dq_o));
        if (cle) begin
          t_lastca = cyc;
          case (dq_o)
            8'hFF: begin mode = 0; go_busy(0); end
            8'h90: begin mode = 1; na = 0; end
            8'h70: mode = 3;
            8'h00: begin mode = 4; na = 0; end
            8'h30: begin
              if (mode != 4 || na != 5) fail($sformatf("30h after %0d address cycles", na));
              go_busy(1);
            end
            8'h80: begin mode = 6; na = 0; nd = 0; for (int i = 0; i < PSZ; i++) preg[i] = 8'hFF; end
            8'h10: begin
              if (mode != 6 || na != 5) fail("10h out of place");
              go_busy(2);
            end
            8'h60: begin mode = 7; na = 0; end
            8'hD0: begin
              if (mode != 7 || na != 3) fail("D0h out of place");
              go_busy(3);
            end
            8'hEE: begin mode = 8; na = 0; end
            8'hEF: begin mode = 10; na = 0; nd = 0; end
            default: fail($sformatf("unknown command %h", dq_o));
          endcase
        end else if (ale) begin
          t_lastca = cyc;
          if (na > 4) fail("too many address cycles");
          else ab[na] = dq_o;
          na++;
          if (mode == 1) begin mode = 2; ptr = 0; end
          else if (mode == 8) go_busy(4);
          else if (!(mode == 4 || mode == 6 || mode == 7 || mode == 10)) fail("address cycle out of place");
        end else begin
          if (cyc - t_lastca < TADL && nd == 0) fail("tADL");
          if (mode == 6) begin
            k = {ab[1], ab[0]};
            k = (k + nd) % PSZ;
            preg[k] = dq_o;
            nd++;
          end
          else if (mode == 10) begin
            if (nd < 4) fb[nd] = dq_o;
            nd++;
            if (nd == 4) go_busy(5);
          end else fail("data-in cycle out of place");
        end
      end
      if (re_n && !p_re) ptr++;
      p_we = we_n; p_re = re_n;
      if (rb_n && !p_rb) t_rdy = cyc;
      p_rb = rb_n;
    end
  end
  always @(negedge clk) begin
    if (busy_left > 0) begin
      busy_left--;
      rb_n = 0;
      if (busy_left == 0) begin rb_n = 1; finish_op(); end
    end else rb_n = 1;
    if (!rst_n) rb_n = 1;
    dq_i = !re_n && !ce_n ? dev_out() : 8'($urandom);
  end

  // ---------------- host ----------------
  logic [7:0] rf [0:NPG*PSZ-1];                 // reference array
  logic [7:0] rft [0:1023];
  logic [7:0] pr [0:PSZ-1];                     // a page register, for the reference
  logic [7:0] wq [$], rq [$], xq [$];           // bytes to write; bytes read; bytes expected
  int         p_wr = 70, p_rd = 70, n_done = 0, n_cmds = 0, n_bytes = 0;
  bit         ev_f = 0, ev_t = 0;
  always @(negedge clk) begin
    wr_valid = 0;
    if (wq.size() != 0 && $urandom % 100 < p_wr) begin wr_valid = 1; wr_data = wq[0]; end
    else wr_data = $urandom;
    rd_ready = $urandom % 100 < p_rd;
  end
  always @(posedge clk) if (rst_n) begin
    if (wr_valid && wr_ready) void'(wq.pop_front());
    if (rd_valid && rd_ready) begin rq.push_back(rd_data); n_bytes++; end
    if (done) n_done++;
    if (ev_fail) ev_f = 1;
    if (ev_timeout) ev_t = 1;
  end
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask

  // one command; xq: the bytes it must read; xs: expected status (-1: any)
  task automatic run(input logic [2:0] op, input logic [23:0] row, input logic [15:0] col, input int len,
                     input bit xfail, input bit xto, input int xs);
    int         nd0, t, p, n, nbad, k;
    nbad = 0;
    n = op == 6 || op == 7 ? 4 : len;
    xq.delete();
    p = (row[15:0] % NPG);
    case (op)
      3'd1: for (int i = 0; i < n; i++) xq.push_back(col[7:0] == 8'h20 ? onfi_sig[i % 4] : id_bytes[i % 5]);
      3'd3: for (int i = 0; i < n; i++) xq.push_back(rf[p * PSZ + (col + i) % PSZ]);
      3'd4: for (int i = 0; i < n; i++) wq.push_back(8'($urandom));
      3'd6: for (int i = 0; i < 4; i++) xq.push_back(rft[col[7:0] * 4 + i]);
      3'd7: for (int i = 0; i < 4; i++) wq.push_back(8'($urandom));
      default: ;
    endcase
    // the reference
    if (op == 3'd4 && !xfail && !xto) begin
      for (int i = 0; i < PSZ; i++) pr[i] = 8'hFF;
      for (int i = 0; i < n; i++) begin
        k = wq.size() - n + i;
        pr[(col + i) % PSZ] = wq[k];
      end
      for (int i = 0; i < PSZ; i++) rf[p * PSZ + i] = rf[p * PSZ + i] & pr[i];
    end
    if (op == 3'd5 && !xfail && !xto) for (int i = 0; i < 4 * PSZ; i++) rf[(p & ~3) * PSZ + i] = 8'hFF;
    if (op == 3'd7 && !xto)
      for (int i = 0; i < 4; i++) begin
        k = wq.size() - 4 + i;
        rft[col[7:0] * 4 + i] = wq[k];
      end
    rq.delete();
    ev_f = 0; ev_t = 0;
    nd0 = n_done;
    cmd_valid = 1; cmd_op = op; cmd_row = row; cmd_col = col; cmd_len = LW'(len);
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    @(negedge clk);
    cmd_valid = 0; cmd_op = $urandom; cmd_row = $urandom; cmd_col = $urandom; cmd_len = $urandom;
    t = 0;
    while (n_done == nd0 && t < 200000) begin @(negedge clk); t++; end
    if (t == 200000) fail($sformatf("op %0d never done", op));
    while (rd_valid) @(negedge clk);              // the last byte may still wait in the read register
    wait_clk(3);
    n_cmds++;
    if (!xto) begin
      if (rq.size() != xq.size()) fail($sformatf("op %0d: %0d bytes read, expected %0d", op, rq.size(), xq.size()));
      for (int i = 0; i < rq.size() && i < xq.size(); i++)
        if (rq[i] !== xq[i]) begin
          if (nbad == 0) fail($sformatf("op %0d byte %0d: %h, expected %h", op, i, rq[i], xq[i]));
          nbad++;
        end
    end
    if (wq.size() != 0 && !xto) fail("write bytes left over");
    wq.delete();
    if (ev_f != xfail) fail($sformatf("op %0d: ev_fail %0b, expected %0b", op, ev_f, xfail));
    if (ev_t != xto) fail($sformatf("op %0d: ev_timeout %0b, expected %0b", op, ev_t, xto));
    if (xs >= 0 && status !== 8'(xs)) fail($sformatf("op %0d: status %h, expected %h", op, status, xs));
  endtask
  function automatic logic [23:0] rrow();
    return {8'($urandom), 16'($urandom % NPG + NPG * ($urandom % 2048))};
  endfunction

  task automatic rnd_cmd();
    int r, len;
    logic [23:0] row;
    logic [15:0] col;
    bit f;
    r = $urandom % 100;
    row = rrow();
    col = $urandom;
    len = $urandom % 100 < 10 ? 0 : $urandom % 100;
    f = $urandom % 100 < 15;
    if (r < 25) run(3, row, col, len, 0, 0, -1);
    else if (r < 50) begin
      nx_fail = f;
      st_noise = $urandom;
      run(4, row, col, len, f, 0, {3'b111, st_noise[4:1], f});
    end else if (r < 60) begin
      nx_fail = f;
      st_noise = $urandom;
      run(5, row, col, 0, f, 0, {3'b111, st_noise[4:1], f});
    end else if (r < 70) run(1, row, $urandom % 2 ? 16'h0020 : 16'(8'($urandom)), $urandom % 12, 0, 0, -1);
    else if (r < 78) begin st_noise = $urandom; run(2, row, col, 0, 0, 0, {3'b111, st_noise[4:1], t_fail}); end
    else if (r < 88) run(6, row, col, len, 0, 0, -1);
    else if (r < 96) run(7, row, col, len, 0, 0, -1);
    else run(0, row, col, len, 0, 0, -1);
  endtask

  initial begin
    id_bytes[0] = 8'h2C; id_bytes[1] = 8'hDA; id_bytes[2] = 8'h90; id_bytes[3] = 8'h95; id_bytes[4] = 8'h06;
    onfi_sig[0] = 8'h4F; onfi_sig[1] = 8'h4E; onfi_sig[2] = 8'h46; onfi_sig[3] = 8'h49;
    for (int i = 0; i < NPG * PSZ; i++) begin fl[i] = $urandom; rf[i] = fl[i]; end
    for (int i = 0; i < 1024; i++) begin ft[i] = $urandom; rft[i] = ft[i]; end
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    // ---- basics
    run(0, 0, 0, 0, 0, 0, -1);
    run(1, 0, 16'h0000, 5, 0, 0, -1);
    run(1, 0, 16'h0020, 4, 0, 0, -1);
    st_noise = 0;
    run(2, 0, 0, 0, 0, 0, 8'hE0);
    run(5, 24'h000004, 0, 0, 0, 0, 8'hE0);                  // erase block 1
    run(4, 24'h000005, 16'h0010, 64, 0, 0, 8'hE0);
    run(3, 24'h000005, 16'h0000, 128, 0, 0, -1);
    run(7, 0, 16'h0001, 0, 0, 0, -1);
    run(6, 0, 16'h0001, 0, 0, 0, -1);
    // ---- a whole page out and in (cmd_len at its top bits)
    run(5, 24'h000008, 0, 0, 0, 0, 8'hE0);
    p_wr = 100; p_rd = 100;
    run(4, 24'h000009, 16'h0000, PSZ - 1, 0, 0, 8'hE0);
    run(3, 24'h000009, 16'h0000, PSZ - 1, 0, 0, -1);
    run(3, 24'hFFFFFF, 16'hFFFF, 2049, 0, 0, -1);
    p_wr = 70; p_rd = 70;
    // ---- two Read Status commands back to back
    begin : b_b2b
      int nd0;
      nd0 = n_done;
      cmd_valid = 1; cmd_op = 2;
      @(posedge clk);
      while (!cmd_ready) @(posedge clk);
      @(posedge clk);
      while (!cmd_ready) @(posedge clk);
      @(negedge clk);
      cmd_valid = 0;
      while (n_done != nd0 + 2) @(negedge clk);
      if (status !== 8'hE0) fail("status after two Read Status");
      wait_clk(3);
    end
    // ---- failures, noise, stalls
    nx_fail = 1; st_noise = 8'h1E;
    run(4, 24'h00000A, 16'h0100, 8, 1, 0, 8'hFF);
    nx_fail = 1; st_noise = 8'h00;
    run(5, 24'h00000C, 0, 0, 1, 0, 8'hE1);
    st_noise = 0;
    run(2, 0, 0, 0, 0, 0, 8'hE1);
    p_wr = 15; p_rd = 15;
    for (int i = 0; i < 30; i++) rnd_cmd();
    p_wr = 90; p_rd = 90; busy_min = 1; busy_max = 4;
    for (int i = 0; i < 60; i++) rnd_cmd();
    p_wr = 60; p_rd = 60; busy_min = 20; busy_max = 300;
    for (int i = 0; i < 40; i++) rnd_cmd();
    busy_min = 3; busy_max = 40;
    // ---- busy past the timeout: the status shows busy, then ready
    t_fail = 0;
    nx_slow = 1;
    run(5, 24'h000010, 0, 0, 0, 1, -1);
    st_noise = 0;
    run(2, 0, 0, 0, 0, 0, 8'h80);
    while (!rb_n) @(negedge clk);
    wait_clk(5);
    run(2, 0, 0, 0, 0, 0, 8'hE0);
    for (int i = 0; i < 4 * PSZ; i++) rf[16 * PSZ + i] = 8'hFF;   // the erase did finish
    nx_slow = 1;
    run(3, 24'h000011, 0, 4, 0, 1, -1);
    while (!rb_n) @(negedge clk);
    wait_clk(5);
    mode = 0;
    nx_slow = 1;
    run(0, 0, 0, 0, 0, 1, -1);
    while (!rb_n) @(negedge clk);
    wait_clk(5);
    for (int i = 0; i < 20; i++) rnd_cmd();
    // ---- row 0 and a long program
    run(3, 24'h000000, 16'h0000, 4, 0, 0, -1);
    nx_fail = 0; st_noise = 0;
    run(4, 24'h000006, 16'h0000, 500, 0, 0, -1);
    // ---- a reset in the middle of a Program
    wq.delete();
    for (int i = 0; i < 300; i++) wq.push_back(8'($urandom));
    cmd_valid = 1; cmd_op = 4; cmd_row = 24'h000003; cmd_col = 0; cmd_len = 300;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    @(negedge clk);
    cmd_valid = 0;
    wait_clk(200 + $urandom % 200);
    rst_n = 0;
    wq.delete();
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    run(0, 0, 0, 0, 0, 0, -1);
    for (int i = 0; i < 20; i++) rnd_cmd();

    if (n_bad != 0) fail("target errors");
    if (errors == 0) $display("TEST PASSED: ONFI (%0d commands, %0d bytes read)", n_cmds, n_bytes);
    else $display("TEST FAILED: ONFI (%0d errors)", errors);
    $finish;
  end

  initial begin
    #40ms;
    $display("TEST FAILED: ONFI (timeout)");
    $finish;
  end
endmodule
