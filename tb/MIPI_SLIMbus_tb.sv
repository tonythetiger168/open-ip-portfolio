// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for MIPI_SLIMbus_top v2.0
//  * Three endpoints on one bus: 0 is the framer, 1 and 2 are devices.
//    The DATA line has a bus keeper; two drivers at once is an error
//    (except where a scenario forces the line).
//  * Line checks of its own: the frame sync 1011 decoded from the line
//    (NRZI) at every frame start, the FI word {96, cfg_fi, count} with the
//    count going up by one each superframe.
//  * Data channels: every sample a transmitter hands over must arrive, in
//    order, at every receiver of that segment; underruns send nothing.
//  * Scenarios: lock after reset, every segment length and the segments
//    that just fit before slot 96 / 192, loopback, underruns, bad segment
//    configurations (cfg_err), a TAG with reserved bits (rx_err), one and
//    two corrupted frame syncs (lost_sync and relock), a corrupted FI,
//    the superframe count loaded and wrapping, a slower CLK, device and
//    framer resets.
// ============================================================================
`timescale 1ns/1ps
module MIPI_SLIMbus_tb;
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
  logic [3:0]  cfg_div = 3;
  logic [7:0]  cfg_fi = 8'h5A;
  logic        sf_set = 0;
  logic [15:0] sf_set_val = 0;
  logic [7:0]  txs [0:N-1], rxs [0:N-1];
  logic [2:0]  txl [0:N-1], rxl [0:N-1];
  logic [N-1:0] tx_valid = 0;
  logic [31:0] tx_data [0:N-1];
  wire  [N-1:0] cfg_err, clk_o, clk_oe, dat_o, dat_oe, tx_ready, tx_underrun, rx_valid, rx_err;
  wire  [N-1:0] locked, sf_locked, lost_sync, fi_valid;
  wire  [31:0] rx_data [0:N-1];
  wire  [7:0]  fi_info [0:N-1];
  wire  [15:0] sf_count [0:N-1];
  logic        keep_c = 0, keep_d = 0, force_on = 0, force_v = 0, allow_cont = 0;
  wire         line_c = clk_oe != 0 ? |(clk_oe & clk_o) : keep_c;
  wire         line_d = force_on ? force_v : (dat_oe != 0 ? |(dat_oe & dat_o) : keep_d);
  always @(posedge clk) begin keep_c <= line_c; keep_d <= line_d; end

  for (genvar i = 0; i < N; i++) begin : g_ep
    localparam bit FR = i == 0;
    MIPI_SLIMbus_top u (
      .clk, .rst_n(rst_n[i]), .cfg_framer(FR), .cfg_div, .cfg_fi, .sf_set(FR && sf_set), .sf_set_val,
      .cfg_tx_slot(txs[i]), .cfg_tx_len(txl[i]), .cfg_rx_slot(rxs[i]), .cfg_rx_len(rxl[i]), .cfg_err(cfg_err[i]),
      .slim_clk_o(clk_o[i]), .slim_clk_oe(clk_oe[i]), .slim_clk_i(line_c),
      .slim_dat_o(dat_o[i]), .slim_dat_oe(dat_oe[i]), .slim_dat_i(line_d),
      .tx_valid(tx_valid[i]), .tx_ready(tx_ready[i]), .tx_data(tx_data[i]), .tx_underrun(tx_underrun[i]),
      .rx_valid(rx_valid[i]), .rx_data(rx_data[i]), .rx_err(rx_err[i]),
      .locked(locked[i]), .sf_locked(sf_locked[i]), .lost_sync(lost_sync[i]), .fi_valid(fi_valid[i]),
      .fi_info(fi_info[i]), .sf_count(sf_count[i]));
  end

  // ---------------- line checker (from the framer's CLK) ----------------
  // cells decoded at CLK falling; the frame start is found from the
  // framer's own count once, then followed independently
  logic        pc = 0, plv = 0;
  int          lpos = -1, lfno = 0, n_frames = 0, n_sf = 0;
  logic [3:0]  lsync;
  logic [31:0] lfi;
  logic [15:0] lcnt;
  bit          lcnt_ok = 0, sync_chk = 1;
  int          sf_skip = 0;
  always @(negedge clk) begin
    if (!rst_n[0]) begin lpos = -1; lcnt_ok = 0; end
    else if (pc && !line_c) begin : b_cell
      bit b;
      b = line_d ^ plv;
      plv = line_d;
      if (lpos < 0 && g_ep[0].u.cpos == 0) begin lpos = 0; lfno = g_ep[0].u.fno; end
      else if (lpos >= 0) begin
        lpos = (lpos + 1) % 768;
        if (lpos == 0) lfno = (lfno + 1) % 8;
      end
      if (lpos >= 0) begin
        if (lpos < 4) lsync[3 - lpos] = b;
        if (lpos == 3) begin
          n_frames++;
          if (lsync != 4'b1011 && sync_chk) fail($sformatf("frame sync %b", lsync));
        end
        if (lpos >= 384 && lpos < 388) lfi[31 - 4 * lfno - (lpos - 384)] = b;
        if (lpos == 387 && lfno == 7 && !sync_chk) lcnt_ok = 0;
        if (lpos == 387 && lfno == 7 && sync_chk) begin
          n_sf++;
          if (lfi[31:24] != 8'h96 || lfi[23:16] != fi_exp) fail($sformatf("FI %h", lfi));
          // after sf_set: the superframe in progress keeps its count, the next
          // one carries the loaded value
          if (sf_skip == 1 && lfi[15:0] != sf_set_val) fail($sformatf("FI count %h, loaded %h", lfi[15:0], sf_set_val));
          if (sf_skip == 0 && lcnt_ok && lfi[15:0] != 16'(lcnt + 1)) fail($sformatf("FI count %h after %h", lfi[15:0], lcnt));
          if (sf_skip > 0) sf_skip--;
          lcnt = lfi[15:0]; lcnt_ok = 1;
        end
      end
    end
    pc = line_c;
    if (!allow_cont && !force_on && $countones(dat_oe) > 1) fail($sformatf("DATA driven by %b", dat_oe));
  end
  always @(negedge clk) if (sf_set) sf_skip = 2;
  // cfg_fi is sent from the next superframe on
  logic [7:0] fi_exp;
  always @(posedge clk) if (g_ep[0].u.rise && g_ep[0].u.cnext == 0 && g_ep[0].u.fno == 7) fi_exp <= cfg_fi;

  // ---------------- FI reports ----------------
  logic [15:0] f_cnt;
  bit          f_ok = 0;
  for (genvar i = 0; i < N; i++) begin : g_fi
    always @(negedge clk) if (rst_n[i] && fi_valid[i] && sync_chk) begin
      if (fi_info[i] != fi_exp) fail($sformatf("ep %0d: FI info %h", i, fi_info[i]));
      if (i == 0) begin f_cnt = sf_count[0]; f_ok = 1; end
      else if (f_ok && sf_count[i] != f_cnt) fail($sformatf("ep %0d: count %h, framer %h", i, sf_count[i], f_cnt));
    end
  end

  // ---------------- data channels ----------------
  logic [31:0] sq [0:N-1][0:4095];
  int          stl [0:N-1], rhd [0:N-1], src [0:N-1], n_rx [0:N-1], n_under [0:N-1], n_rxerr [0:N-1];
  int          busy_pct [0:N-1];
  longint      f_tx = -1;                  // forced sample (directed)
  bit          allow_skip = 0, allow_rxerr = 0;
  bit [N-1:0]  took = 0;
  always @(posedge clk) took <= tx_valid & tx_ready;
  function automatic logic [31:0] lmask(input logic [2:0] l, input logic [31:0] d);
    return l >= 4 ? d : d & ((32'd1 << (8 * l)) - 1);
  endfunction
  for (genvar i = 0; i < N; i++) begin : g_host
    always @(negedge clk) if (!rst_n[i]) begin tx_valid[i] = 0; end else begin
      if (took[i]) begin
        sq[i][stl[i] % 4096] = lmask(txl[i], tx_data[i]); stl[i]++;
        tx_valid[i] = 0;
      end
      if (!tx_valid[i] && ($urandom % 100) < busy_pct[i]) begin tx_valid[i] = 1; tx_data[i] = f_tx >= 0 ? 32'(f_tx) : $urandom; end
      if (tx_underrun[i]) n_under[i]++;
      if (rx_err[i]) begin n_rxerr[i]++; if (!allow_rxerr) fail($sformatf("ep %0d: rx_err", i)); end
      if (rx_valid[i]) begin
        n_rx[i]++;
        if (src[i] < 0) fail($sformatf("ep %0d: data with no source", i));
        else if (rhd[i] == stl[src[i]]) fail($sformatf("ep %0d: unexpected sample %h", i, rx_data[i]));
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
  // returns at the negedge before the framer starts a frame (sampled at
  // negedges, free of races with the RTL)
  task automatic frames(input int n);
    repeat (n) begin
      @(negedge clk);
      while (!(g_ep[0].u.rise && g_ep[0].u.cpos == 767)) @(negedge clk);
    end
  endtask
  task automatic wait_lock(input int limit);
    int g;
    g = 0;
    while (sf_locked != {N{1'b1}} && g < limit) begin @(negedge clk); g++; end
    if (g >= limit) fail($sformatf("no lock (%b / %b)", locked, sf_locked));
  endtask
  // set the channel map: transmitter t on (slot, len), receivers listen
  task automatic chan_off;
    for (int i = 0; i < N; i++) begin txl[i] = 0; rxl[i] = 0; txs[i] = 1; rxs[i] = 1; src[i] = -1; busy_pct[i] = 0; end
  endtask
  task automatic chan(input int t, input int slot, input int len, input int r);
    txs[t] = slot; txl[t] = len; rxs[r] = slot; rxl[r] = len; src[r] = t; rhd[r] = stl[t]; busy_pct[t] = 60;
  endtask
  // stop the hosts, let the last samples through, and check every receiver
  task automatic settle;
    for (int i = 0; i < N; i++) busy_pct[i] = 0;
    frames(2);
    for (int i = 0; i < N; i++)
      if (src[i] >= 0 && rhd[i] != stl[src[i]] && !allow_skip)
        fail($sformatf("ep %0d: %0d samples missing", i, stl[src[i]] - rhd[i]));
    for (int i = 0; i < N; i++) if (src[i] >= 0) rhd[i] = stl[src[i]];
  endtask

  // a driver of our own for cells of the framer's frame: NRZI from the line
  task automatic force_cells(input int pos, input logic [7:0] bits, input int n);
    while (!(g_ep[0].u.rise && g_ep[0].u.cnext == 10'(pos))) @(negedge clk);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);                          // the cell has started
      force_v = (i == 0 ? keep_d : force_v) ^ bits[n - 1 - i]; force_on = 1;
      while (!g_ep[0].u.rise) @(negedge clk);
    end
    @(negedge clk) force_on = 0;
  endtask

  initial begin
    for (int i = 0; i < N; i++) begin stl[i] = 0; rhd[i] = 0; n_rx[i] = 0; n_under[i] = 0; n_rxerr[i] = 0; tx_data[i] = 0; end
    chan_off();
    #22 rst_n = '1;
    // 1. lock
    wait_lock(400_000);
    // 2. channels: framer to device 1, device 1 to the framer, device 2 loopback
    chan(0, 5, 4, 1); chan(1, 120, 1, 0); chan(2, 40, 3, 2);
    frames(40);
    settle();
    // every length; segments that end exactly at slot 96 and 192
    chan_off(); chan(0, 87, 4, 2); chan(2, 183, 4, 1); chan(1, 1, 2, 0); frames(20); settle();
    chan_off(); chan(1, 97, 1, 2); chan(2, 60, 2, 0); chan(0, 150, 3, 1); frames(20); settle();
    // underruns: transmitters with nothing to send
    chan_off(); chan(0, 10, 2, 1); busy_pct[0] = 0; frames(4);
    if (n_under[0] < 3) fail("no underruns");
    settle();
    // 3. bad segment configurations
    chan_off();
    txs[1] = 0;   txl[1] = 1; cycles(2); if (!cfg_err[1]) fail("slot 0 accepted");
    txs[1] = 96;  txl[1] = 1; cycles(2); if (!cfg_err[1]) fail("slot 96 accepted");
    txs[1] = 90;  txl[1] = 3; cycles(2); if (!cfg_err[1]) fail("segment across slot 96 accepted");
    txs[1] = 188; txl[1] = 2; cycles(2); if (!cfg_err[1]) fail("segment across slot 192 accepted");
    txs[1] = 20;  txl[1] = 5; cycles(2); if (!cfg_err[1]) fail("length 5 accepted");
    rxs[2] = 191; rxl[2] = 1; cycles(2); if (!cfg_err[2]) fail("rx segment across slot 192 accepted");
    busy_pct[1] = 100;
    begin : b_bad
      int u;
      u = n_under[1];
      frames(3);
      if (n_under[1] != u || tx_ready[1]) fail("a channel with a bad segment ran");
    end
    chan_off();
    // 4. TAG with reserved bits, and a TAG without data, into the framer
    rxs[0] = 30; rxl[0] = 1; src[0] = -1;
    allow_rxerr = 1;
    force_cells(120, 8'b0000_0101, 4);
    force_cells(120, 8'b0000_0000, 4);
    frames(1);
    allow_rxerr = 0;
    if (n_rxerr[0] != 1) fail($sformatf("rx_err %0d", n_rxerr[0]));
    chan_off();

    // 5. sync loss: one corrupted frame sync is survived, two are not
    chan(0, 5, 4, 1); chan(1, 120, 2, 2);
    frames(4);
    sync_chk = 0;
    force_cells(0, 8'b0000_0000, 4);
    frames(2);
    if (sf_locked != '1) fail("one missed frame sync lost the lock");
    allow_skip = 1;
    force_cells(0, 8'b0000_0000, 4);
    frames(1);
    force_cells(0, 8'b0000_0000, 4);
    frames(1);
    if (locked[1] || locked[2]) fail("two missed frame syncs kept the lock");
    sync_chk = 1;
    wait_lock(400_000);
    frames(10);
    settle();
    // a corrupted FI sync nibble drops the superframe lock only
    while (g_ep[0].u.fno != 0) @(negedge clk);
    sync_chk = 0;
    force_cells(384, 8'b0000_0000, 4);
    frames(1);
    if (sf_locked[1] || !locked[1]) fail("bad FI did not drop only the superframe lock");
    wait_lock(400_000);
    // no FI at all: a device gives up the frame lock after 16 frames
    begin : b_nofi
      int l;
      l = 0;
      for (int f = 0; f < 22; f++) begin
        force_cells(384, 8'b0000_0000, 4);
        if (lost_sync[1]) l++;
      end
      frames(1);
    end
    wait_lock(400_000);
    sync_chk = 1;
    frames(10);
    settle();
    allow_skip = 0;

    // 6. superframe count: load near the top and wrap
    chan_off();
    @(negedge clk) sf_set = 1; sf_set_val = 16'hFFFE; @(negedge clk) sf_set = 0;
    frames(8 * 3);
    @(negedge clk) sf_set = 1; sf_set_val = 16'h7FFF; @(negedge clk) sf_set = 0;
    frames(8 * 2);
    @(negedge clk) sf_set = 1; sf_set_val = 16'h0000; @(negedge clk) sf_set = 0;
    frames(8 * 2);

    // 7. slower CLK, then the fastest
    cfg_div = 15;
    chan(0, 5, 4, 1);
    frames(10);
    cfg_div = 4;
    frames(4);
    cfg_div = 3;
    frames(4);
    settle();
    // other FI information
    cfg_fi = 8'hFF; frames(8 * 2);
    cfg_fi = 8'h00; frames(8 * 2);
    cfg_fi = 8'hA5; frames(8 * 2);

    // 8. resets: a device, then the framer
    rst_n[2] = 0; cycles(5); rst_n[2] = 1;
    wait_lock(400_000);
    allow_skip = 1;
    chan(0, 5, 4, 1);
    frames(2);
    // the devices keep their old frame until they lose it: their drives
    // collide with the new frame meanwhile
    sync_chk = 0; allow_cont = 1; allow_rxerr = 1;
    rst_n[0] = 0; cycles(5); rst_n[0] = 1; f_ok = 0; lpos = -1;
    begin : b_lose
      int g;
      g = 0;
      while ((locked[1] || locked[2]) && g < 100_000) begin @(negedge clk); g++; end
      if (g >= 100_000) fail("devices kept the lock after a framer reset");
    end
    wait_lock(400_000);
    sync_chk = 1; allow_cont = 0; allow_rxerr = 0;
    frames(10);
    settle();
    // every segment length with each data pattern, both ways
    for (int l = 1; l <= 4; l++)
      for (int k = 0; k < 5; k++) begin
        f_tx = k == 0 ? 32'h0000_0000 : k == 1 ? 32'hFFFF_FFFF : k == 2 ? 32'h5555_5555 :
               k == 3 ? 32'hAAAA_AAAA : -1;
        chan_off(); chan(0, 5, l, 1); chan(1, 120, l, 0);
        frames(4); settle();
      end
    f_tx = -1; chan_off();

    $display("frames %0d superframes %0d samples %0d/%0d/%0d", n_frames, n_sf, n_rx[0], n_rx[1], n_rx[2]);
    if (errors == 0) $display("TEST PASSED: MIPI_SLIMbus");
    else $display("TEST FAILED: MIPI_SLIMbus (%0d errors)", errors);
    $finish;
  end
  initial begin #200ms; $display("TEST FAILED: MIPI_SLIMbus (timeout)"); $finish; end
endmodule
