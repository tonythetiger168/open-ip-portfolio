// SPDX-License-Identifier: Apache-2.0
// JESD204C_top testbench: two link ends A and B cross-connected. The line
// A -> B runs through a TB channel with a variable bit delay (bits added or
// dropped, whole blocks dropped or repeated) and bit flips.
//  - host drivers give random blocks (with gaps: underruns) and random
//    commands; a monitor records every block each transmitter sends
//  - receive scoreboards: from the first block after a lock, every block
//    must be the next one sent (data, multiblock and extended multiblock
//    start), every multiblock its command, and no CRC error unless the
//    channel corrupted something
//  - alignment: slides at every bit offset, invalid headers below and at
//    the unlock threshold, multiblock and extended multiblock errors from
//    dropped / repeated blocks and from cfg_e differing between the ends
// The bound checker (tb/cov/JESD204C_sva.sv) checks every output of both
// ends on every clock.
`timescale 1ns/1ps
module JESD204C_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- ends: index 0 = A, 1 = B ----------------
  logic [1:0]       tx_valid = 0;
  logic [1:0][63:0] tx_data = 0;
  logic [1:0][6:0]  tx_cmd = 0;
  logic [1:0][3:0]  cfg_e = 0;
  wire  [1:0]       tx_ready, tx_mb_start, tx_underrun, rx_valid, rx_mb_start, rx_emb_start, rx_mb_valid;
  wire  [1:0]       rx_crc_err, sh_lock, emb_lock, err_sh, err_emb;
  wire  [1:0][63:0] rx_data;
  wire  [1:0][6:0]  rx_cmd;
  wire              a_tx, b_tx;
  // channel A -> B
  logic [511:0]     dl = 0;
  int               dly = 0;
  logic             flip = 0;
  always @(posedge clk) dl <= {dl[510:0], a_tx};
  wire              b_rx = dl[dly] ^ flip;

  JESD204C_top u_a (.clk(clk), .rst_n(rst_n), .tx_p(a_tx), .rx_p(b_tx), .cfg_e(cfg_e[0]),
    .tx_valid(tx_valid[0]), .tx_ready(tx_ready[0]), .tx_data(tx_data[0]), .tx_cmd(tx_cmd[0]),
    .tx_mb_start(tx_mb_start[0]), .tx_underrun(tx_underrun[0]), .rx_valid(rx_valid[0]), .rx_data(rx_data[0]),
    .rx_mb_start(rx_mb_start[0]), .rx_emb_start(rx_emb_start[0]), .rx_mb_valid(rx_mb_valid[0]), .rx_cmd(rx_cmd[0]),
    .rx_crc_err(rx_crc_err[0]), .sh_lock(sh_lock[0]), .emb_lock(emb_lock[0]), .err_sh(err_sh[0]), .err_emb(err_emb[0]));
  JESD204C_top u_b (.clk(clk), .rst_n(rst_n), .tx_p(b_tx), .rx_p(b_rx), .cfg_e(cfg_e[1]),
    .tx_valid(tx_valid[1]), .tx_ready(tx_ready[1]), .tx_data(tx_data[1]), .tx_cmd(tx_cmd[1]),
    .tx_mb_start(tx_mb_start[1]), .tx_underrun(tx_underrun[1]), .rx_valid(rx_valid[1]), .rx_data(rx_data[1]),
    .rx_mb_start(rx_mb_start[1]), .rx_emb_start(rx_emb_start[1]), .rx_mb_valid(rx_mb_valid[1]), .rx_cmd(rx_cmd[1]),
    .rx_crc_err(rx_crc_err[1]), .sh_lock(sh_lock[1]), .emb_lock(emb_lock[1]), .err_sh(err_sh[1]), .err_emb(err_emb[1]));

  // ---------------- host drivers ----------------
  int gap_pct = 0;                      // chance of no block offered
  int dpat = -1, cpat = -1;             // >= 0: payload class (0, ones, 0x55.., 0xAA..) / fixed command
  function automatic logic [63:0] pl;
    case (dpat)
      0: return 64'd0;
      1: return '1;
      2: return {32{2'b01}};
      3: return {32{2'b10}};
      default: return {$urandom, $urandom};
    endcase
  endfunction
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin
      tx_valid[p] = ($urandom % 100) >= gap_pct;
      if (!tx_valid[p] || $urandom % 2) tx_data[p] = pl();
    end
  // a new command at every multiblock start
  always @(posedge clk) for (int p = 0; p < 2; p++) if (tx_mb_start[p]) tx_cmd[p] <= cpat >= 0 ? 7'(cpat) : 7'($urandom);

  // ---------------- what each transmitter sent ----------------
  // per end: {command of its multiblock, emb start, mb start, data},
  // recorded as the payload is taken
  logic [72:0] sent0 [$];
  logic [72:0] sent1 [$];
  int          tj [0:1], te [0:1];
  logic [6:0]  scmd [0:1];
  initial for (int p = 0; p < 2; p++) begin tj[p] = 0; te[p] = 0; scmd[p] = 0; end
  function automatic int ssize(input int p);
    return p == 0 ? sent0.size() : sent1.size();
  endfunction
  function automatic logic [72:0] sfront(input int p);
    return p == 0 ? sent0[0] : sent1[0];
  endfunction
  function automatic logic [63:0] sdata(input int p);
    logic [72:0] e;
    e = sfront(p);
    return e[63:0];
  endfunction
  task automatic spop(input int p);
    if (p == 0) void'(sent0.pop_front()); else void'(sent1.pop_front());
  endtask
  always @(posedge clk)
    if (!rst_n) begin
      for (int p = 0; p < 2; p++) begin tj[p] = 0; te[p] = 0; end
      sent0.delete(); sent1.delete();
    end else
      for (int p = 0; p < 2; p++)
        if (p == 0 ? u_a.tc == 7'd0 : u_b.tc == 7'd0) begin : b_rec
          logic [72:0] b;
          if (tj[p] == 0) scmd[p] = tx_cmd[p];
          b = {scmd[p], tj[p] == 0 && te[p] == 0, tj[p] == 0, tx_valid[p] ? tx_data[p] : 64'd0};
          if (p == 0) begin sent0.push_back(b); if (sent0.size() > 3000) void'(sent0.pop_front()); end
          else begin sent1.push_back(b); if (sent1.size() > 3000) void'(sent1.pop_front()); end
          tj[p] = (tj[p] + 1) % 32;
        end
        // the extended multiblock count moves at the end of block 31, with
        // cfg_e as it is then
        else if ((p == 0 ? u_a.tc == 7'd65 : u_b.tc == 7'd65) && tj[p] == 0)
          te[p] = te[p] >= int'(cfg_e[p]) ? 0 : te[p] + 1;

  // ---------------- receive scoreboards ----------------
  // end p receives what end 1-p sent
  bit   [1:0]  synced = 0, dirty = 0;
  int          ncrc_ok [0:1];
  logic [72:0] cur [0:1];
  initial for (int p = 0; p < 2; p++) begin ncrc_ok[p] = 0; cur[p] = 0; end
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin
      if (!rst_n || !emb_lock[p] && !rx_valid[p]) synced[p] = 0;
      if (rx_valid[p]) begin
        if (!synced[p] && rx_data[p] != 64'd0) begin
          // the first nonzero block after a lock: find it among those sent
          while (ssize(1 - p) != 0 && sdata(1 - p) !== rx_data[p]) spop(1 - p);
          if (ssize(1 - p) != 0) synced[p] = 1;
          else if (!dirty[p]) fail($sformatf("end %0d: first block %h was never sent", p, rx_data[p]));
        end
        if (synced[p]) begin
          cur[p] = sfront(1 - p);
          spop(1 - p);
          if (!dirty[p] && (rx_data[p] !== cur[p][63:0] || rx_mb_start[p] !== cur[p][64] || rx_emb_start[p] !== cur[p][65]))
            fail($sformatf("end %0d: block %h %b%b, expected %h %b%b", p, rx_data[p], rx_mb_start[p], rx_emb_start[p],
                           cur[p][63:0], cur[p][64], cur[p][65]));
          if (ssize(1 - p) == 0) synced[p] = 0;
        end
      end
      if (rx_mb_valid[p] && synced[p]) begin
        if (!dirty[p] && rx_cmd[p] !== cur[p][72:66]) fail($sformatf("end %0d: command %h, expected %h", p, rx_cmd[p], cur[p][72:66]));
        if (!dirty[p] && rx_crc_err[p]) fail($sformatf("end %0d: CRC error on a clean line", p));
        if (!rx_crc_err[p]) ncrc_ok[p]++;
      end
    end

  // ---------------- helpers ----------------
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic wait_lock(input int p, input int n_mb = 40);
    int t;
    t = 0;
    while (!emb_lock[p] && t < n_mb * 2112) begin @(negedge clk); t++; end
    if (!emb_lock[p]) fail($sformatf("end %0d: no lock", p));
  endtask
  // B's line: dirty while the channel misbehaves, clean once relocked and
  // two whole multiblocks are through
  task automatic clean_b;
    wait_lock(1);
    wait_clk(3 * 2112);
    dirty[1] = 0;
  endtask
  task automatic clean_both;
    wait_lock(0); wait_lock(1);
    wait_clk(3 * 2112);
    dirty = 0;
  endtask
  task automatic flip_at(input int n);
    wait_clk(n);
    flip = 1; @(negedge clk); flip = 0;
  endtask
  task automatic do_reset;
    @(negedge clk);
    rst_n = 0;
    wait_clk(3);
    rst_n = 1;
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    // ---- lock both ends, run with gaps, every cfg_e on both ends alike
    wait_lock(0); wait_lock(1);
    wait_clk(4 * 2112);
    gap_pct = 10;
    for (int e = 0; e < 16; e += 5) begin
      dirty = 2'b11;
      cfg_e[0] = e; cfg_e[1] = e;
      wait_clk(2 * 2112 * (e + 1));
      dirty = 0;
      wait_clk(2112 * (e + 2));
      if (!emb_lock[0] || !emb_lock[1]) fail($sformatf("lock lost at cfg_e %0d", e));
    end
    cfg_e = 0;
    wait_clk(3 * 2112);
    gap_pct = 50;
    wait_clk(2 * 2112);
    gap_pct = 0;
    wait_clk(2 * 2112);

    // ---- payload bit flips: CRC errors, the lock holds
    dirty[1] = 1;
    for (int i = 0; i < 4; i++) begin
      flip_at(200 + $urandom % 2000);
      while (!rx_mb_valid[1]) @(negedge clk);
      while (!rx_mb_valid[1]) @(negedge clk);
      wait_clk(3);
    end
    if (!emb_lock[1]) fail("lock lost over payload errors");
    wait_clk(3 * 2112);
    dirty[1] = 0;
    // ---- header errors: a few per window (counter reset), then 16 in a row
    dirty[1] = 1;
    for (int w = 0; w < 3; w++)
      for (int i = 0; i < 5; i++) begin
        while (u_b.rc != 7'd65) @(negedge clk);
        flip = 1; @(negedge clk); flip = 0;
        wait_clk(66 * (2 + $urandom % 10));
      end
    if (!sh_lock[1]) fail("lock lost below the error threshold");
    // from the start of a window: 15 invalid headers keep the lock, the 16th drops it
    while (!(u_b.rc == 7'd65 && u_b.wcnt == 6'd0)) @(negedge clk);
    for (int i = 0; i < 16; i++) begin
      while (u_b.rc != 7'd65) @(negedge clk);
      if (i == 15 && !sh_lock[1]) fail("unlocked before the 16th header error");
      flip = 1; @(negedge clk); flip = 0;
    end
    wait_clk(200);
    if (sh_lock[1]) fail("still locked after 16 header errors");
    clean_b();
    // ---- the line slides by 1..65 bits: B hunts at every offset
    for (int s = 1; s < 66; s += 7) begin
      dirty[1] = 1;
      dly = (dly + s) % 400;
      clean_b();
    end
    // ---- whole blocks dropped and repeated: multiblock alignment errors
    for (int i = 0; i < 4; i++) begin
      dirty[1] = 1;
      while (!(u_b.rc == 7'd30 && u_b.rj == 5'(8 * i + 3))) @(negedge clk);
      if (i[0]) dly = dly + 66; else dly = dly >= 66 ? dly - 66 : dly + 2 * 66;
      clean_b();
    end
    // ---- cfg_e differs between the ends: EoEMB unexpected / missing
    dirty = 2'b11;
    cfg_e[1] = 3;
    wait_clk(10 * 2112);
    cfg_e[0] = 3;
    clean_both();
    dirty = 2'b11;
    cfg_e[1] = 0;
    wait_clk(10 * 2112);
    cfg_e[1] = 3;
    clean_both();
    dirty = 2'b11;
    cfg_e[0] = 15; cfg_e[1] = 15;
    wait_clk(34 * 2112);
    clean_both();
    wait_clk(34 * 2112);
    if (ncrc_ok[1] == 0) fail("no clean multiblock seen");
    // ---- payload and command classes
    for (int k = 0; k < 4; k++) begin dpat = k; wait_clk(2112); end
    dpat = -1;
    cpat = 0; wait_clk(3 * 2112);
    cpat = 7'h7F; wait_clk(3 * 2112);
    cpat = -1;
    // ---- reset while locked
    do_reset();
    cfg_e = 0;
    wait_lock(0); wait_lock(1);
    wait_clk(4 * 2112);

    if (errors == 0) $display("TEST PASSED: JESD204C");
    else $display("TEST FAILED: JESD204C (%0d errors)", errors);
    $finish;
  end

  initial begin
    #80ms;
    $display("TEST FAILED: JESD204C (timeout)");
    $finish;
  end
endmodule
