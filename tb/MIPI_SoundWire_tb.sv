// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for MIPI_SoundWire_top v2.0
//  * Endpoint 0 is the manager, 1 and 2 are peripherals (devices 1 and 5)
//    with a register bank each. DATA has a bus keeper; two drivers at once
//    is an error (except where a scenario forces the line).
//  * Line decoder of its own (from the manager's CLOCK): every frame's
//    static sync B1, dynamic sync (PRBS x^4 + x^3 + 1) and parity.
//  * Commands: READ / WRITE / PING to both devices, an absent device and a
//    reserved opcode; every response (ACK, NAK, read data, PING status)
//    and the banks are checked against a model; one command queued behind
//    another; a forced bad parity bit (NAK, par_err, no write).
//  * Data ports: every sample sent in a column arrives at its receiver;
//    underruns send zeros.
//  * Scenarios: every column count, bit times from the minimum up, two bad
//    frames (lost_sync and relock), one bad frame survived, resets.
// ============================================================================
`timescale 1ns/1ps
module MIPI_SoundWire_tb;
  localparam int N = 3;
  logic clk = 0;
  logic [N-1:0] rst_n = 0;
  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 40) $display("ERROR: %s @%0t", m, $time);
  endfunction

  // ---------------- endpoints and bus ----------------
  logic [4:0]  cfg_div = 11;
  logic [1:0]  cfg_cols = 0;
  logic [3:0]  txc [0:N-1], rxc [0:N-1];
  logic [1:0]  dev_status [0:N-1];
  logic        cmd_valid = 0;
  logic [1:0]  cmd_op = 0;
  logic [3:0]  cmd_dev = 0;
  logic [15:0] cmd_addr = 0;
  logic [7:0]  cmd_wdata = 0;
  logic [N-1:0] tx_valid = 0;
  logic [31:0] tx_data [0:N-1];
  logic [7:0]  reg_rdata [0:N-1];
  wire  [N-1:0] clk_o, clk_oe, dat_o, dat_oe, cmd_ready, rsp_valid, rsp_ack, rsp_nak, reg_we, reg_re;
  wire  [N-1:0] tx_ready, tx_underrun, rx_valid, locked, lost_sync, par_err;
  wire  [7:0]  rsp_rdata [0:N-1], reg_wdata [0:N-1];
  wire  [15:0] ping_status [0:N-1], reg_addr [0:N-1];
  wire  [31:0] rx_data [0:N-1];
  logic        keep_c = 0, keep_d = 0, force_on = 0, force_v = 0, allow_cont = 0;
  wire         line_c = clk_oe != 0 ? |(clk_oe & clk_o) : keep_c;
  wire         line_d = force_on ? force_v : (dat_oe != 0 ? |(dat_oe & dat_o) : keep_d);
  always @(posedge clk) if (!rst_n[0]) begin keep_c <= 0; keep_d <= 0; end else begin keep_c <= line_c; keep_d <= line_d; end
  logic [3:0]  devn [0:N-1];
  initial begin devn[0] = 0; devn[1] = 1; devn[2] = 5; end

  for (genvar i = 0; i < N; i++) begin : g_ep
    localparam bit MG = i == 0;
    MIPI_SoundWire_top u (
      .clk, .rst_n(rst_n[i]), .cfg_manager(MG), .cfg_div, .cfg_cols, .cfg_dev(devn[i]),
      .cfg_tx_col(txc[i]), .cfg_rx_col(rxc[i]),
      .sw_clk_o(clk_o[i]), .sw_clk_oe(clk_oe[i]), .sw_clk_i(line_c),
      .sw_dat_o(dat_o[i]), .sw_dat_oe(dat_oe[i]), .sw_dat_i(line_d),
      .cmd_valid(MG && cmd_valid), .cmd_ready(cmd_ready[i]), .cmd_op, .cmd_dev, .cmd_addr, .cmd_wdata,
      .rsp_valid(rsp_valid[i]), .rsp_ack(rsp_ack[i]), .rsp_nak(rsp_nak[i]), .rsp_rdata(rsp_rdata[i]),
      .ping_status(ping_status[i]), .dev_status(dev_status[i]), .reg_we(reg_we[i]), .reg_re(reg_re[i]),
      .reg_addr(reg_addr[i]), .reg_wdata(reg_wdata[i]), .reg_rdata(reg_rdata[i]),
      .tx_valid(tx_valid[i]), .tx_ready(tx_ready[i]), .tx_data(tx_data[i]), .tx_underrun(tx_underrun[i]),
      .rx_valid(rx_valid[i]), .rx_data(rx_data[i]), .locked(locked[i]), .lost_sync(lost_sync[i]),
      .par_err(par_err[i]));
  end

  // ---------------- register banks (combinational read) ----------------
  logic [7:0] bank [1:N-1][0:255];
  logic [7:0] mbank [1:N-1][0:255];      // model of the banks
  int         n_we [0:N-1], n_perr [0:N-1];
  for (genvar i = 1; i < N; i++) begin : g_bank
    always_comb reg_rdata[i] = bank[i][reg_addr[i][7:0]] ^ reg_addr[i][15:8];
    always @(posedge clk) if (reg_we[i]) begin bank[i][reg_addr[i][7:0]] <= reg_wdata[i] ^ reg_addr[i][15:8]; n_we[i]++; end
    always @(negedge clk) if (par_err[i]) n_perr[i]++;
  end
  initial reg_rdata[0] = 8'h00;

  // ---------------- line decoder ----------------
  logic        pc = 0, plv = 0;
  int          lrow = -1, lcol = 0, nfr = 0;
  logic [47:0] lw;
  logic [3:0]  ldyn;
  bit          ldyn_ok = 0, line_chk = 1;
  function automatic logic [3:0] prbs(input logic [3:0] d); return {d[2:0], d[3] ^ d[2]}; endfunction
  always @(negedge clk) begin
    if (!rst_n[0]) begin lrow = -1; ldyn_ok = 0; end
    else if (line_c != pc) begin : b_bit
      bit b;
      int nc;
      b = line_d ^ plv;
      plv = line_d;
      nc = 2 << cfg_cols;
      if (lrow < 0) begin
        if (g_ep[0].u.row == 0 && g_ep[0].u.col == 0) begin lrow = 0; lcol = 0; end
      end else begin
        if (lcol == 0) lw[47 - lrow] = b;
        if (lcol == 0 && lrow == 47 && line_chk) begin
          nfr++;
          if (lw[13:6] != 8'hB1) fail($sformatf("static sync %h", lw[13:6]));
          if (ldyn_ok && lw[5:2] != prbs(ldyn)) fail($sformatf("dynamic sync %h after %h", lw[5:2], ldyn));
          if (lw[1:0] != 0) fail("reserved control bits");
          if (lw[46:46] == 1'b1 && lw[16] != ((^lw[47:25]) ^ (lw[45] ? ^lw[24:17] : 1'b0)))
            fail("parity");
          ldyn = lw[5:2]; ldyn_ok = 1;
        end
        if (lcol == 0 && lrow == 47 && !line_chk) ldyn_ok = 0;
        lcol++;
        if (lcol == nc) begin lcol = 0; lrow = (lrow + 1) % 48; end
      end
    end
    pc = line_c;
    if (!allow_cont && !force_on && $countones(dat_oe) > 1) fail($sformatf("DATA driven by %b", dat_oe));
  end

  // ---------------- commands ----------------
  // expected responses, in order: {ack, nak, rdata}
  logic [9:0]  rq [0:255];
  int          rqh = 0, rqt = 0, n_rsp = 0;
  bit          bad_par = 0;              // the next command's parity bit is forced
  always @(negedge clk) if (rst_n[0] && rsp_valid[0]) begin
    n_rsp++;
    if (rqh == rqt) fail("response with no command");
    else begin
      if ({rsp_ack[0], rsp_nak[0], rsp_rdata[0]} !== rq[rqh % 256])
        fail($sformatf("response %b %b %h, expected %h", rsp_ack[0], rsp_nak[0], rsp_rdata[0], rq[rqh % 256]));
      rqh++;
    end
  end
  function automatic logic [3:0] absent(input int k); return k == 0 ? 4'd3 : (k == 1 ? 4'd9 : 4'd14); endfunction
  function automatic int dev_idx(input logic [3:0] d);
    for (int i = 1; i < N; i++) if (devn[i] == d) return i;
    return 0;
  endfunction
  function automatic void expect_rsp(input logic [1:0] op, input logic [3:0] dv, input logic [15:0] a, input logic [7:0] wd);
    int k;
    logic [9:0] e;
    k = dev_idx(dv);
    e = 0;
    if (op == 2 && k != 0) e = {2'b10, mbank[k][a[7:0]] ^ a[15:8]};
    if (op == 3 && k != 0) begin e = {2'b10, 8'h00}; mbank[k][a[7:0]] = wd ^ a[15:8]; end
    if (op == 3) e[7:0] = wd;
    rq[rqt % 256] = e; rqt++;
  endfunction
  // issue a command; the model decides the response now (commands run in order)
  task automatic cmd(input logic [1:0] op, input logic [3:0] dv, input logic [15:0] a, input logic [7:0] wd);
    expect_rsp(op, dv, a, wd);
    @(negedge clk);
    while (!cmd_ready[0]) @(negedge clk);
    cmd_valid = 1; cmd_op = op; cmd_dev = dv; cmd_addr = a; cmd_wdata = wd;
    @(negedge clk);
    // sometimes a command held while not ready: it must be ignored
    if ($urandom % 2) begin
      cmd_op = $urandom; cmd_dev = $urandom; cmd_addr = $urandom; cmd_wdata = $urandom;
      @(negedge clk);
    end
    cmd_valid = 0; cmd_op = $urandom; cmd_dev = $urandom; cmd_addr = $urandom; cmd_wdata = $urandom;
  endtask
  // a command presented in the clock that starts a frame: it waits for the next frame
  task automatic cmd_at_frame(input logic [1:0] op, input logic [3:0] dv, input logic [15:0] a, input logic [7:0] wd);
    expect_rsp(op, dv, a, wd);
    while (!cmd_ready[0]) @(negedge clk);
    frames(1);
    cmd_valid = 1; cmd_op = op; cmd_dev = dv; cmd_addr = a; cmd_wdata = wd;
    @(negedge clk);
    cmd_valid = 0;
  endtask
  task automatic line_on;
    lrow = -1; ldyn_ok = 0; line_chk = 1;
  endtask
  // waits until every endpoint is locked and the line decoder can follow
  task automatic relock;
    frames(4);
    wait_lock(400_000);
    frames(2);
    line_on();
  endtask
  task automatic wait_rsp;
    int g;
    g = 0;
    while (rqh != rqt && g < 200_000) begin @(negedge clk); g++; end
    if (g >= 200_000) fail($sformatf("%0d responses missing", rqt - rqh));
  endtask
  // PING status: each device's dev_status in its slot
  always @(negedge clk) if (rst_n[0] && g_ep[0].u.edge_now && g_ep[0].u.col == 0 && g_ep[0].u.row == 22 &&
                             g_ep[0].u.rw[47:45] == 3'b000 && line_chk && locked[1] && locked[2]) begin
    // checked one clock later, once ping_status has updated
    #10;
    for (int i = 1; i < N; i++)
      if (devn[i] >= 1 && devn[i] <= 8 && ping_status[0][17 - 2 * devn[i] -: 2] !== dev_status[i])
        fail($sformatf("PING status %h, device %0d", ping_status[0], devn[i]));
  end

  // ---------------- data ports ----------------
  logic [31:0] sq [0:N-1][0:4095];
  int          stl [0:N-1], rhd [0:N-1], src [0:N-1], n_rx [0:N-1], n_under [0:N-1];
  int          busy_pct [0:N-1];
  bit          allow_skip = 0, pat = 0, pat_ph = 0;
  longint      f_tx = -1;                 // forced sample (directed)
  bit [N-1:0]  took = 0;
  always @(posedge clk) took <= tx_valid & tx_ready;
  for (genvar i = 0; i < N; i++) begin : g_host
    always @(negedge clk) if (!rst_n[i]) tx_valid[i] = 0; else begin
      if (took[i]) begin sq[i][stl[i] % 4096] = tx_data[i]; stl[i]++; tx_valid[i] = 0; end
      if (tx_underrun[i] && busy_pct[i] == 0) begin sq[i][stl[i] % 4096] = 0; stl[i]++; n_under[i]++; end
      if (!tx_valid[i] && ($urandom % 100) < busy_pct[i]) begin
        tx_valid[i] = 1; tx_data[i] = f_tx >= 0 ? 32'(f_tx) : $urandom;
        // a static sync pattern in every other sample
        if (pat && i == 0) begin tx_data[i][31:24] = pat_ph ? 8'hB1 : 8'h00; pat_ph = !pat_ph; end
      end
      if (rx_valid[i]) begin
        n_rx[i]++;
        if (src[i] < 0) fail($sformatf("ep %0d: data with no source", i));
        else if (rhd[i] == stl[src[i]]) begin if (!allow_skip) fail($sformatf("ep %0d: unexpected sample %h", i, rx_data[i])); end
        else if (rx_data[i] == sq[src[i]][rhd[i] % 4096]) rhd[i]++;
        else begin : b_find
          int k;
          k = rhd[i];
          while (k < stl[src[i]] && sq[src[i]][k % 4096] != rx_data[i]) k++;
          if (!allow_skip || k == stl[src[i]]) fail($sformatf("ep %0d: sample %h, expected %h", i, rx_data[i], sq[src[i]][rhd[i] % 4096]));
          else rhd[i] = k + 1;
        end
      end
    end
  end

  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  // returns at the negedge before the manager starts a frame
  task automatic frames(input int n);
    repeat (n) begin
      @(negedge clk);
      while (!(g_ep[0].u.edge_now && g_ep[0].u.row == 47 && g_ep[0].u.col == {g_ep[0].u.lastc_hi, 1'b1})) @(negedge clk);
    end
  endtask
  task automatic wait_lock(input int limit);
    int g;
    g = 0;
    while (locked != '1 && g < limit) begin @(negedge clk); g++; end
    if (g >= limit) fail($sformatf("no lock (%b)", locked));
  endtask
  task automatic chan_off;
    for (int i = 0; i < N; i++) begin txc[i] = 0; rxc[i] = 0; src[i] = -1; busy_pct[i] = 0; end
  endtask
  task automatic chan(input int t, input int c, input int r);
    txc[t] = c; rxc[r] = c; src[r] = t; rhd[r] = stl[t]; busy_pct[t] = 100;
  endtask
  task automatic settle;
    for (int i = 0; i < N; i++) busy_pct[i] = 0;
    frames(2);
    for (int i = 0; i < N; i++) if (src[i] >= 0) rhd[i] = stl[src[i]];
  endtask
  wire [47:0] cw_full = {1'b0, g_ep[0].u.cw, 2'b00, 8'hB1, g_ep[0].u.dyn_m, 2'b00};
  // invert control bit ci of the frame (NRZI from the line)
  task automatic force_ctl(input int ci);
    int r;
    r = 47 - ci;
    while (!(g_ep[0].u.m_mid && g_ep[0].u.row == r && g_ep[0].u.col == 0)) @(negedge clk);
    @(negedge clk);
    force_v = keep_d ^ !cw_full[ci]; force_on = 1;
    while (!g_ep[0].u.m_edge) @(negedge clk);
    @(negedge clk);
    force_on = 0;
  endtask
  // a random command mix
  task automatic cmds(input int n);
    for (int i = 0; i < n; i++) begin : b_c
      int d;
      logic [1:0] op;
      d = $urandom % 4;
      op = $urandom % 4;
      cmd(op, d == 0 ? devn[1] : (d == 1 ? devn[2] : (d == 2 ? absent($urandom % 3) : devn[1])), $urandom, $urandom);
      if ($urandom % 2) wait_rsp();
    end
    wait_rsp();
  endtask

  initial begin
    for (int i = 0; i < N; i++) begin
      stl[i] = 0; rhd[i] = 0; n_rx[i] = 0; n_under[i] = 0; n_we[i] = 0; n_perr[i] = 0; tx_data[i] = 0;
      dev_status[i] = 2'(i);
    end
    for (int i = 1; i < N; i++) for (int a = 0; a < 256; a++) begin bank[i][a] = 8'(a * 7 + i); mbank[i][a] = 8'(a * 7 + i); end
    chan_off();
    #22 rst_n = '1;
    wait_lock(200_000);
    // 1. commands at every column count, data ports in the free columns
    for (int c = 0; c < 4; c++) begin
      cfg_cols = c;
      if (c > 0) begin wait_lock(200_000); frames(1); end
      allow_skip = 1;
      chan_off();
      chan(0, 1, 1);
      if (c > 0) begin chan(1, 2, 0); chan(2, 3, 2); end
      if (c > 1) begin chan_off(); chan(0, 7, 2); chan(2, 5, 1); chan(1, 4, 0); end
      if (c > 2) begin chan_off(); chan(0, 15, 1); chan(1, 9, 2); chan(2, 12, 0); end
      frames(2);
      allow_skip = 0;
      for (int i = 0; i < N; i++) if (src[i] >= 0) rhd[i] = stl[src[i]];
      cmds(25);
      for (int k = 0; k < 4; k++) begin dev_status[1] = k; dev_status[2] = 3 - k; cmd(0, 0, 0, 0); wait_rsp(); end
      frames(2);
      settle();
      // changing the frame shape breaks the devices' frames for a while
      line_chk = 0; allow_skip = 1;
    end
    wait_lock(200_000);
    frames(2);
    line_chk = 1; allow_skip = 0;
    // every data bit both ways, all-ones and all-zeros registers
    cfg_cols = 3; chan_off();
    cmd(3, 1, 16'hFFFF, 8'hFF); cmd(2, 1, 16'hFFFF, 0); cmd(3, 5, 16'h0000, 8'h00); cmd(2, 5, 16'h0000, 0);
    cmd(3, 1, 16'h0055, 8'h55); cmd(2, 1, 16'h0055, 0); cmd(3, 5, 16'h00AA, 8'hAA); cmd(2, 5, 16'h00AA, 0);
    wait_rsp();
    // samples of each data pattern both ways
    for (int k = 0; k < 4; k++) begin
      f_tx = k == 0 ? 32'h0000_0000 : k == 1 ? 32'hFFFF_FFFF : k == 2 ? 32'h5555_5555 : 32'hAAAA_AAAA;
      chan(0, 6, 1); chan(1, 7, 0);
      frames(3); settle(); chan_off();
    end
    f_tx = -1;
    // underruns send zeros
    chan(0, 6, 1); busy_pct[0] = 0; frames(4); settle();
    chan_off();

    // 2. bad parity: NAK, par_err, no write
    begin : b_par
      int w;
      w = n_we[1];
      line_chk = 0;
      rq[rqt % 256] = {2'b01, mbank[1][8'h33] ^ 8'h00}; rqt++;
      fork
        begin
          @(negedge clk) while (!cmd_ready[0]) @(negedge clk);
          cmd_valid = 1; cmd_op = 2; cmd_dev = 1; cmd_addr = 16'h0033; cmd_wdata = 0;
          @(negedge clk) cmd_valid = 0;
        end
      join
      frames(1);
      force_ctl(16);
      wait_rsp();
      rq[rqt % 256] = {2'b01, 8'h5A}; rqt++;
      @(negedge clk) while (!cmd_ready[0]) @(negedge clk);
      cmd_valid = 1; cmd_op = 3; cmd_dev = 5; cmd_addr = 16'h0044; cmd_wdata = 8'h5A;
      @(negedge clk) cmd_valid = 0;
      frames(1);
      force_ctl(16);
      wait_rsp();
      frames(1);
      line_chk = 1; ldyn_ok = 0;
      if (n_we[1] != w || n_perr[1] != 1 || n_perr[2] != 1) fail("bad parity: writes or par_err");
    end

    // 3. sync: one bad frame survived (static, then dynamic sync), two in a row lose the lock
    line_chk = 0;
    frames(1); force_ctl(9);
    frames(2); force_ctl(3);
    frames(2);
    if (locked != '1) fail("one bad frame lost the lock");
    frames(1); force_ctl(9); force_ctl(4);    // the same frame: one miss
    frames(1); force_ctl(9); force_ctl(9);    // two frames in a row
    frames(1);
    if (locked[1] || locked[2]) fail("two bad frames kept the lock");
    relock();
    cmds(6);
    // a command in the clock that starts a frame
    cmd_at_frame(2, devn[1], 16'h0102, 0); wait_rsp();
    cmd(2, devn[2], 16'h0003, 0); cmd_at_frame(3, devn[1], 16'h0004, 8'h77); wait_rsp();

    // 4. bit times, fewer columns, another device number
    line_chk = 0;
    cfg_div = 31; cfg_cols = 1; devn[2] = 10;
    relock();
    cmds(6);
    for (int k = 0; k < 2; k++) begin dev_status[2] = 2'(k + 1); cmd(0, 0, 0, 0); wait_rsp(); end
    cfg_div = 16; frames(3); cmds(4);
    // every PING slot: the second device moves through device numbers 2 to 8
    for (int d = 2; d <= 8; d++) begin
      devn[2] = 4'(d); dev_status[2] = 3; frames(2); dev_status[2] = 0; frames(2);
    end
    // a frame whose opcode MSB is set (forced): no device answers
    line_chk = 0;
    expect_rsp(1, 0, 0, 0);
    @(negedge clk) while (!cmd_ready[0]) @(negedge clk);
    cmd_valid = 1; cmd_op = 2; cmd_dev = devn[1]; cmd_addr = 16'h0011; cmd_wdata = 0;
    @(negedge clk) cmd_valid = 0;
    frames(1); force_ctl(47);
    wait_rsp();
    frames(1); line_on();
    line_chk = 0;
    cfg_div = 11; cfg_cols = 3; devn[2] = 5;
    relock();

    // 5. a hunting device meets a static sync pattern in a data column, then the real one
    // (the device also receives that column: nothing until it is locked)
    chan_off(); chan(0, 1, 1); pat = 1; allow_skip = 1;
    rxc[2] = 1; src[2] = 0; rhd[2] = stl[0];
    rst_n[2] = 0;
    frames(1);
    while (tx_data[0][31:24] != 8'hB1) frames(1);
    rst_n[2] = 1;
    frames(6);
    pat = 0;
    wait_lock(200_000);
    settle(); chan_off(); allow_skip = 0;
    cmds(4);
    // resets: the manager, with two columns
    cfg_cols = 0;
    line_chk = 0; allow_cont = 1;
    rst_n[0] = 0; cycles(3); rst_n[0] = 1;
    begin : b_lose
      int g;
      g = 0;
      while ((locked[1] || locked[2]) && g < 100_000) begin @(negedge clk); g++; end
    end
    wait_lock(400_000);
    frames(2);
    line_chk = 1; allow_cont = 0;
    cmds(6);

    $display("frames %0d responses %0d writes %0d/%0d samples %0d/%0d/%0d", nfr, n_rsp, n_we[1], n_we[2], n_rx[0], n_rx[1], n_rx[2]);
    if (errors == 0) $display("TEST PASSED: MIPI_SoundWire");
    else $display("TEST FAILED: MIPI_SoundWire (%0d errors)", errors);
    $finish;
  end
  initial begin #200ms; $display("TEST FAILED: MIPI_SoundWire (timeout)"); $finish; end
endmodule
