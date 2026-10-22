// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for DigRF_top v2.0
//  * Two endpoints back to back (0 = baseband, 1 = RF IC) through channels
//    with a 0..15 bit delay. Each side has a register file behind its
//    register slave port, a data host on dtx_* and a scoreboard on the
//    peer's drx_*, interrupt and control traffic in both directions.
//  * A BFM with its own 8b/10b tables (both columns transcribed from the
//    standard) can take over the lane into endpoint 1 to send hand-built
//    bursts: every data byte in both disparities, every frame type, and
//    errors (bad LCT, size 6/7, data between frames, foreign control
//    symbols, control symbols inside frames, code violations, disparity
//    errors, responses with a wrong tag or none outstanding).
//  * Line checks on both lanes: a stopped lane is 0; within a burst every
//    symbol is a valid code with the right running disparity.
//  * Scenarios: register writes / reads both ways, posted read responses
//    racing with interrupts and data, read timeouts and a late response,
//    data frames of every size and channel incl. sizes 6/7 (sent as 5),
//    underruns, sync lengths 0..15, hold 0..255, reset mid-burst.
// ============================================================================
`timescale 1ns/1ps
module DigRF_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 40) $display("ERROR: %s @%0t", m, $time);
  endfunction

  // ---------------- endpoints ----------------
  logic [3:0] cfg_sync [0:1];
  logic [7:0] cfg_hold [0:1], cfg_timeout [0:1];
  logic [1:0] ctl_valid = 0, ctl_rd = 0, int_valid = 0, dtx_valid = 0;
  logic [7:0] ctl_addr [0:1], ctl_wdata [0:1], reg_rdata [0:1], dtx_data [0:1];
  logic [4:0] int_vec [0:1];
  logic [2:0] dtx_size [0:1];
  logic [1:0] dtx_chan [0:1];
  wire  [1:0] tx_p, ctl_ready, rsp_valid, rsp_timeout, reg_we, reg_re, int_ready, int_rx;
  wire  [1:0] dtx_ready, drx_valid, drx_sof, drx_eof, drx_abort, tx_on, rx_locked;
  wire  [1:0] err_code, err_frame, tx_underrun;
  wire  [7:0] rsp_data [0:1], reg_addr [0:1], reg_wdata [0:1], drx_data [0:1];
  wire  [4:0] int_rx_vec [0:1];
  wire  [1:0] drx_chan [0:1];
  wire  [1:0] rx_p;

  for (genvar s = 0; s < 2; s++) begin : g_ep
    DigRF_top u (
      .clk, .rst_n, .tx_p(tx_p[s]), .rx_p(rx_p[s]),
      .cfg_sync(cfg_sync[s]), .cfg_hold(cfg_hold[s]), .cfg_timeout(cfg_timeout[s]),
      .ctl_valid(ctl_valid[s]), .ctl_ready(ctl_ready[s]), .ctl_rd(ctl_rd[s]), .ctl_addr(ctl_addr[s]),
      .ctl_wdata(ctl_wdata[s]), .rsp_valid(rsp_valid[s]), .rsp_data(rsp_data[s]), .rsp_timeout(rsp_timeout[s]),
      .reg_we(reg_we[s]), .reg_re(reg_re[s]), .reg_addr(reg_addr[s]), .reg_wdata(reg_wdata[s]),
      .reg_rdata(reg_rdata[s]),
      .int_valid(int_valid[s]), .int_ready(int_ready[s]), .int_vec(int_vec[s]), .int_rx(int_rx[s]),
      .int_rx_vec(int_rx_vec[s]),
      .dtx_valid(dtx_valid[s]), .dtx_ready(dtx_ready[s]), .dtx_data(dtx_data[s]), .dtx_size(dtx_size[s]),
      .dtx_chan(dtx_chan[s]), .drx_valid(drx_valid[s]), .drx_data(drx_data[s]), .drx_sof(drx_sof[s]),
      .drx_eof(drx_eof[s]), .drx_chan(drx_chan[s]), .drx_abort(drx_abort[s]),
      .tx_on(tx_on[s]), .rx_locked(rx_locked[s]), .err_code(err_code[s]), .err_frame(err_frame[s]),
      .tx_underrun(tx_underrun[s]));
  end

  // ---------------- channels ----------------
  logic [15:0] dl0 = 0, dl1 = 0;        // lane into 0 / into 1
  int          dly [0:1];
  logic [3:0]  dly0 = 0, dly1 = 0;
  logic [1:0]  cut = 0;                 // force the lane into s to 0
  logic        bfm_on = 0, bfm_bit = 0; // BFM drives the lane into 1
  always @(posedge clk) begin dl0 <= {dl0[14:0], tx_p[1]}; dl1 <= {dl1[14:0], tx_p[0]}; end
  always @(negedge clk) begin dly0 = 4'(dly[0]); dly1 = 4'(dly[1]); end   // set on a quiet link
  wire [16:0] ln0 = {dl0, tx_p[1]}, ln1 = {dl1, tx_p[0]};
  wire        rx0 = cut[0] ? 1'b0 : ln0[dly0];
  wire        rx1 = cut[1] ? 1'b0 : bfm_on ? bfm_bit : ln1[dly1];
  assign rx_p = {rx1, rx0};

  // ---------------- TB 8b/10b ----------------
  // 6b codes per x: {RD- form, RD+ form}, "abcdei"
  function automatic logic [11:0] c6(input int x);
    case (x)
      0: return {6'b100111, 6'b011000};  1: return {6'b011101, 6'b100010};
      2: return {6'b101101, 6'b010010};  3: return {6'b110001, 6'b110001};
      4: return {6'b110101, 6'b001010};  5: return {6'b101001, 6'b101001};
      6: return {6'b011001, 6'b011001};  7: return {6'b111000, 6'b000111};
      8: return {6'b111001, 6'b000110};  9: return {6'b100101, 6'b100101};
      10: return {6'b010101, 6'b010101}; 11: return {6'b110100, 6'b110100};
      12: return {6'b001101, 6'b001101}; 13: return {6'b101100, 6'b101100};
      14: return {6'b011100, 6'b011100}; 15: return {6'b010111, 6'b101000};
      16: return {6'b011011, 6'b100100}; 17: return {6'b100011, 6'b100011};
      18: return {6'b010011, 6'b010011}; 19: return {6'b110010, 6'b110010};
      20: return {6'b001011, 6'b001011}; 21: return {6'b101010, 6'b101010};
      22: return {6'b011010, 6'b011010}; 23: return {6'b111010, 6'b000101};
      24: return {6'b110011, 6'b001100}; 25: return {6'b100110, 6'b100110};
      26: return {6'b010110, 6'b010110}; 27: return {6'b110110, 6'b001001};
      28: return {6'b001110, 6'b001110}; 29: return {6'b101110, 6'b010001};
      30: return {6'b011110, 6'b100001}; 31: return {6'b101011, 6'b010100};
      default: return {6'b001111, 6'b110000};   // K28
    endcase
  endfunction
  // 4b codes per y: {RD- form, RD+ form}, "fghj"; 8 = A7, 9.. = K28.y
  function automatic logic [7:0] c4(input int y);
    case (y)
      0: return {4'b1011, 4'b0100}; 1: return {4'b1001, 4'b1001};
      2: return {4'b0101, 4'b0101}; 3: return {4'b1100, 4'b0011};
      4: return {4'b1101, 4'b0010}; 5: return {4'b1010, 4'b1010};
      6: return {4'b0110, 4'b0110}; 7: return {4'b1110, 4'b0001};
      8: return {4'b0111, 4'b1000};
      9: return {4'b1011, 4'b0100};  10: return {4'b0110, 4'b1001};
      11: return {4'b1010, 4'b0101}; 12: return {4'b1100, 4'b0011};
      13: return {4'b1101, 4'b0010}; 14: return {4'b0101, 4'b1010};
      15: return {4'b1001, 4'b0110}; default: return {4'b0111, 4'b1000};
    endcase
  endfunction
  function automatic int ones(input logic [9:0] v, input int n);
    int c;
    c = 0;
    for (int i = 0; i < n; i++) c += v[i];
    return c;
  endfunction
  // rd: 0 = RD-, 1 = RD+; returns {rd after, symbol}
  function automatic logic [10:0] tenc(input logic [7:0] d, input bit k, input bit rd);
    int x, y, y4;
    logic [11:0] p6;
    logic [7:0]  p4;
    logic [5:0]  s6;
    logic [3:0]  s4;
    x = d[4:0]; y = d[7:5];
    p6 = c6(k && x == 28 ? 32 : x);
    s6 = rd ? p6[5:0] : p6[11:6];
    if (ones({4'b0, s6}, 6) != 3) rd = !rd;
    if (k && x == 28) y4 = 9 + y;
    else if (y == 7 && (k || (!rd && (x == 17 || x == 18 || x == 20)) || (rd && (x == 11 || x == 13 || x == 14)))) y4 = 8;
    else y4 = y;
    p4 = c4(y4);
    s4 = rd ? p4[3:0] : p4[7:4];
    if (ones({6'b0, s4}, 4) != 2) rd = !rd;
    return {rd, s6, s4};
  endfunction

  // ---------------- line checks ----------------
  // valid[{rd, code}]: the code is a symbol for that running disparity;
  // rdn: the disparity after it (built once from the tables above)
  bit vtab [0:2047], rdn [0:2047];
  initial begin : b_tab
    logic [10:0] c;
    for (int i = 0; i < 2048; i++) begin vtab[i] = 0; rdn[i] = 0; end
    for (int r = 0; r < 2; r++)
      for (int k = 0; k < 2; k++)
        for (int d = 0; d < 256; d++)
          if (k == 0 || d == 8'h3C || d == 8'hBC || d == 8'hFD) begin
            c = tenc(d, k, r);
            vtab[r * 1024 + c[9:0]] = 1; rdn[r * 1024 + c[9:0]] = c[10];
          end
  end
  // on each lane from its burst start: valid codes, right disparity
  for (genvar s = 0; s < 2; s++) begin : g_line
    logic [9:0] sh;
    int  ph;
    bit  rd, on_q;
    always @(negedge clk) if (!rst_n) on_q = 0; else begin
      if (!tx_on[s] && tx_p[s]) fail($sformatf("lane %0d high while stopped", s));
      if (tx_on[s]) begin
        if (!on_q) begin ph = 0; rd = 0; end
        sh = {sh[8:0], tx_p[s]}; ph++;
        if (ph == 10) begin
          ph = 0;
          if (!vtab[{rd, sh}]) fail($sformatf("lane %0d sent %b, not a code for RD%s", s, sh, rd ? "+" : "-"));
          rd = rdn[{rd, sh}];
        end
      end
      on_q = tx_on[s];
    end
  end

  // ---------------- register files ----------------
  logic [7:0] regs [0:1][0:255];
  logic [7:0] mreg [0:1][0:255];        // TB copy of what the peer wrote
  for (genvar s = 0; s < 2; s++) begin : g_reg
    always @(posedge clk) begin
      if (reg_re[s]) reg_rdata[s] <= regs[s][reg_addr[s]];
      if (reg_we[s]) regs[s][reg_addr[s]] <= reg_wdata[s];
    end
  end

  // ---------------- data hosts and scoreboards ----------------
  // frames offered by side s; expected bytes at the peer:
  // {chan, eof, sof, byte}
  int  fb [0:1][0:16383];               // frame bytes
  int  flen [0:1][0:255], fsz [0:1][0:255], fch [0:1][0:255], fst [0:1][0:255];
  int  fh [0:1], ftl [0:1], fwp [0:1], fidx [0:1], fslot [0:1];
  int  ex [0:1][0:65535];
  int  exh [0:1], ext [0:1];
  bit  starve [0:1];
  bit  lax = 0;                          // fault phases: data / int losses allowed
  int  ixq [0:1][0:1023];
  int  ixh [0:1], ixt [0:1];
  int  n_rx [0:1], n_int [0:1], n_err [0:1];
  bit  cnt_err = 0;
  task automatic add_frame(input int s, input int size, input int chan);
    int n;
    n = 8 << (size > 5 ? 5 : size);
    flen[s][ftl[s] % 256] = n; fsz[s][ftl[s] % 256] = size; fch[s][ftl[s] % 256] = chan;
    fst[s][ftl[s] % 256] = fwp[s];
    for (int i = 0; i < n; i++) fb[s][(fwp[s] + i) % 16384] = $urandom % 256;
    fwp[s] += n; ftl[s]++;
  endtask
  function automatic int fcur(input int s, input int i); return fb[s][(fst[s][fh[s] % 256] + i) % 16384]; endfunction
  for (genvar s = 0; s < 2; s++) begin : g_host
    bit took;                            // dtx_valid && dtx_ready at the last posedge
    always @(posedge clk) took <= dtx_valid[s] && dtx_ready[s];
    always @(negedge clk) if (rst_n) begin : b_host
      int f, v;
      f = fh[s] % 256;
      if (took || tx_underrun[s]) begin
        v = took ? fcur(s, fidx[s]) : 0;
        if (took && tx_underrun[s]) fail("byte taken with tx_underrun");
        if (took) fidx[s]++;
        ex[1 - s][ext[1 - s] % 65536] = v | (fslot[s] == 0 ? 256 : 0) | (fslot[s] == flen[s][f] - 1 ? 512 : 0)
                                        | (fch[s][f] << 10);
        ext[1 - s]++;
        fslot[s]++;
        if (fslot[s] == flen[s][f]) begin fh[s]++; fidx[s] = 0; fslot[s] = 0; f = fh[s] % 256; end
      end
      dtx_valid[s] = fh[s] != ftl[s] && !starve[s] && fidx[s] < flen[s][f];
      dtx_data[s] = dtx_valid[s] ? 8'(fcur(s, fidx[s])) : 8'($urandom);
      dtx_size[s] = fh[s] != ftl[s] ? 3'(fsz[s][f]) : 3'($urandom);
      dtx_chan[s] = fh[s] != ftl[s] ? 2'(fch[s][f]) : 2'($urandom);
    end
    // receive side of s
    bit in_fr;
    always @(negedge clk) if (rst_n) begin : b_rx
      int e;
      if (err_code[s] || err_frame[s]) begin
        n_err[s]++;
        if (!cnt_err) fail($sformatf("side %0d: unexpected %s error", s, err_code[s] ? "code" : "frame"));
      end
      if (drx_abort[s]) begin
        if (!lax) fail($sformatf("side %0d: unexpected data abort", s));
        if (!in_fr) fail($sformatf("side %0d: abort outside a data frame", s));
        // drop the rest of the expected frame
        while (exh[s] != ext[s] && !(ex[s][exh[s] % 65536] & 256)) exh[s]++;
        in_fr = 0;
      end
      if (drx_valid[s]) begin
        if (drx_sof[s] && in_fr) fail($sformatf("side %0d: start of frame inside a frame", s));
        if (!drx_sof[s] && !in_fr) fail($sformatf("side %0d: data outside a frame", s));
        in_fr = !drx_eof[s];
        n_rx[s]++;
        if (exh[s] == ext[s]) begin
          if (!lax) fail($sformatf("side %0d: unexpected data %h", s, drx_data[s]));
        end
        else begin
          e = ex[s][exh[s] % 65536]; exh[s]++;
          if ({drx_chan[s], drx_eof[s], drx_sof[s], drx_data[s]} !== 12'(e))
            fail($sformatf("side %0d: data %h sof %b eof %b chan %0d, expected %h", s, drx_data[s], drx_sof[s],
                           drx_eof[s], drx_chan[s], e));
        end
      end
      if (int_rx[s]) begin
        n_int[s]++;
        if (ixh[s] == ixt[s]) fail($sformatf("side %0d: unexpected interrupt %0d", s, int_rx_vec[s]));
        else begin
          if (int_rx_vec[s] !== 5'(ixq[s][ixh[s] % 1024])) fail($sformatf("side %0d: interrupt %0d, expected %0d", s, int_rx_vec[s], ixq[s][ixh[s] % 1024]));
          ixh[s]++;
        end
      end
    end
  end

  // ---------------- control / interrupt tasks ----------------
  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  task automatic ctl(input int s, input bit rd, input logic [7:0] a, input logic [7:0] d, input bit exp_tmo);
    int g;
    g = 0;
    while (!ctl_ready[s]) @(negedge clk);
    ctl_valid[s] = 1; ctl_rd[s] = rd; ctl_addr[s] = a; ctl_wdata[s] = d;
    @(negedge clk);
    ctl_valid[s] = 0; ctl_rd[s] = $urandom; ctl_addr[s] = $urandom; ctl_wdata[s] = $urandom;
    if (!rd) mreg[1 - s][a] = d;
    else begin
      while (!rsp_valid[s] && !rsp_timeout[s] && g < 100_000) begin @(negedge clk); g++; end
      if (exp_tmo) begin
        if (!rsp_timeout[s]) fail($sformatf("side %0d: read of %h did not time out", s, a));
      end else if (!rsp_valid[s]) fail($sformatf("side %0d: read of %h got no response", s, a));
      else if (rsp_data[s] !== mreg[1 - s][a]) fail($sformatf("side %0d: read %h = %h, expected %h", s, a, rsp_data[s], mreg[1 - s][a]));
    end
  endtask
  task automatic irq(input int s, input logic [4:0] v);
    while (!int_ready[s]) @(negedge clk);
    int_valid[s] = 1; int_vec[s] = v;
    ixq[1 - s][ixt[1 - s] % 1024] = v; ixt[1 - s]++;
    @(negedge clk);
    int_valid[s] = 0; int_vec[s] = $urandom;
  endtask
  task automatic quiet(input int limit);
    int g;
    g = 0;
    while ((tx_on != 0 || fh[0] != ftl[0] || fh[1] != ftl[1] || !ctl_ready[0] || !ctl_ready[1]
            || !int_ready[0] || !int_ready[1]) && g < limit) begin @(negedge clk); g++; end
    if (g >= limit) fail("link did not go quiet");
    cycles(40);
    for (int s = 0; s < 2; s++) begin
      if (exh[s] != ext[s]) fail($sformatf("side %0d: %0d data bytes missing", s, ext[s] - exh[s]));
      if (ixh[s] != ixt[s]) fail($sformatf("side %0d: %0d interrupts missing", s, ixt[s] - ixh[s]));
      exh[s] = ext[s]; ixh[s] = ixt[s];
    end
  endtask

  // random traffic in both directions
  task automatic traffic(input int n_ctl, input int n_frames, input bit underruns);
    fork
      for (int s = 0; s < 2; s++) begin
        automatic int ss = s;
        fork
          for (int i = 0; i < n_ctl; i++) begin
            ctl(ss, $urandom % 2, $urandom, $urandom, 0);
            cycles($urandom % 30);
          end
          for (int i = 0; i < n_ctl / 2; i++) begin
            irq(ss, $urandom);
            cycles($urandom % 200);
          end
          for (int i = 0; i < n_frames; i++) begin
            add_frame(ss, $urandom % 8, $urandom % 4);
            cycles($urandom % 400);
          end
          if (underruns) for (int i = 0; i < 20; i++) begin
            cycles($urandom % 600);
            starve[ss] = 1; cycles($urandom % 40 + 1); starve[ss] = 0;
          end
        join
      end
    join
  endtask

  // ---------------- BFM into endpoint 1 ----------------
  bit brd;
  task automatic b_raw(input logic [9:0] v);
    for (int i = 9; i >= 0; i--) begin bfm_bit = v[i]; @(negedge clk); end
  endtask
  task automatic b_sym(input logic [7:0] d, input bit k);
    logic [10:0] c;
    c = tenc(d, k, brd); brd = c[10];
    b_raw(c[9:0]);
  endtask
  task automatic b_start(input int n); brd = 0; bfm_on = 1; repeat (n) b_sym(8'hBC, 1); endtask
  task automatic b_stop; b_sym(8'hFD, 1); bfm_bit = 0; cycles(5); bfm_on = 0; endtask
  task automatic b_data(input int size, input int chan, input bit expect_it);
    int n, v;
    n = 8 << size;
    b_sym(8'h3C, 1); b_sym({3'd0, 2'(chan), 3'(size)}, 0);
    for (int i = 0; i < n; i++) begin
      v = $urandom % 256;
      if (expect_it) begin
        ex[1][ext[1] % 65536] = v | (i == 0 ? 256 : 0) | (i == n - 1 ? 512 : 0) | (chan << 10); ext[1]++;
      end
      b_sym(v, 0);
    end
  endtask

  // ---------------- scenarios ----------------
  initial begin
    for (int s = 0; s < 2; s++) begin
      cfg_sync[s] = 2; cfg_hold[s] = 4; cfg_timeout[s] = 255; dly[s] = 0; starve[s] = 0;
      fh[s] = 0; ftl[s] = 0; fwp[s] = 0; fidx[s] = 0; fslot[s] = 0; exh[s] = 0; ext[s] = 0;
      ixh[s] = 0; ixt[s] = 0; n_rx[s] = 0; n_int[s] = 0; n_err[s] = 0;
      ctl_addr[s] = 0; ctl_wdata[s] = 0; int_vec[s] = 0; dtx_data[s] = 0; dtx_size[s] = 0; dtx_chan[s] = 0;
      reg_rdata[s] = 0;
      for (int a = 0; a < 256; a++) begin regs[s][a] = 0; mreg[s][a] = 0; end
    end
    #22 rst_n = 1;
    cycles(5);

    // 1. register access both ways, every address, at every lane delay
    for (int a = 0; a < 256; a++) begin
      if (a % 16 == 0) begin             // delays change only on a quiet link
        quiet(10_000);
        dly[0] = a / 16; dly[1] = (a / 16 * 7) % 16;
      end
      ctl(a % 2, 0, a, $urandom, 0);
      ctl(1 - a % 2, 1, $urandom, 0, 0);
    end
    for (int a = 0; a < 256; a++) ctl(0, 1, a, 0, 0);
    quiet(10_000);

    // 2. random traffic: control, interrupts, data of every size
    for (int r = 0; r < 4; r++) begin
      for (int s = 0; s < 2; s++) begin
        cfg_sync[s] = $urandom; cfg_hold[s] = r == 3 ? 255 : $urandom % 20; dly[s] = $urandom % 16;
      end
      traffic(30, 25, 0);
      quiet(500_000);
    end
    for (int s = 0; s < 2; s++) begin cfg_hold[s] = 4; cfg_sync[s] = 2; end
    // a read response, an interrupt and a control request pending together
    for (int i = 0; i < 4; i++) begin
      fork
        ctl(0, 1, 8'h30 + i, 0, 0);
        begin
          while (!reg_re[1]) @(negedge clk);
          fork irq(1, 5'(i)); ctl(1, 0, 8'h40 + i, 8'h5A, 0); join
        end
      join
      quiet(10_000);
    end
    // underruns
    traffic(10, 40, 1);
    quiet(500_000);

    // 3. read timeout, late response
    cut[0] = 1;                           // responses to 0 are lost
    ctl(0, 1, 8'h11, 0, 1);
    quiet(20_000);
    cut[0] = 0;
    cfg_timeout[0] = 1; cnt_err = 1;
    ctl(0, 1, 8'h22, 0, 1);               // answered after the timeout
    quiet(20_000);
    cfg_sync[0] = 1; cfg_hold[0] = 255;
    ctl(0, 1, 8'h24, 0, 1);               // times out; its response then meets
    cfg_timeout[0] = 255;                 // the next read (another tag)
    ctl(0, 1, 8'h25, 0, 0);
    cfg_hold[0] = 4;
    quiet(20_000);
    cfg_timeout[0] = 1;
    if (n_err[0] == 0) fail("late response not flagged");
    cfg_timeout[0] = 0;
    ctl(0, 1, 8'h23, 0, 1);
    quiet(20_000);
    cfg_timeout[0] = 255; cnt_err = 0; n_err[0] = 0;

    // 4. BFM: hand-built bursts into endpoint 1
    cycles(20);
    b_start(1);
    for (int i = 0; i < 40; i++) b_data(i % 6, i % 4, 1);     // all bytes, both disparities
    for (int i = 0; i < 4; i++) b_sym(8'hBC, 1);
    b_sym(8'h3C, 1); b_sym({3'd4, 5'h15}, 0); ixq[1][ixt[1] % 1024] = 5'h15; ixt[1]++;   // INT
    b_stop();
    quiet(10_000);
    // errors
    lax = 1; cnt_err = 1;
    b_start(3);
    b_sym(8'h55, 0);                                  // data between frames
    b_sym(8'h1C, 1);                                  // foreign control symbol (K28.0)
    b_sym(8'hF7, 1);                                  // K23.7
    b_sym(8'h3C, 1); b_sym({3'd5, 5'h0}, 0);          // bad LCT
    b_sym(8'h3C, 1); b_sym({3'd7, 5'h1F}, 0);
    b_sym(8'h3C, 1); b_sym({3'd0, 2'd1, 3'd6}, 0);    // size 6
    b_sym(8'h3C, 1); b_sym({3'd0, 2'd2, 3'd7}, 0);    // size 7
    b_sym(8'h3C, 1); b_sym({3'd3, 5'h3}, 0); b_sym(8'h12, 0);   // response, none outstanding
    b_sym(8'h3C, 1); b_sym(8'h3C, 1);                 // start of frame in the header
    b_sym(8'hBC, 1);                                  // control symbol in the header
    b_sym(8'h3C, 1); b_sym({3'd0, 2'd3, 3'd1}, 0); b_sym(8'h01, 0); b_sym(8'h02, 0);
    b_sym(8'hBC, 1);                                  // filler inside a data frame: abort
    b_sym(8'h3C, 1); b_sym({3'd1, 5'h2}, 0); b_sym(8'h40, 0);
    b_sym(8'h3C, 1);                                  // start of frame inside a write
    b_sym({3'd0, 2'd0, 3'd0}, 0); b_sym(8'h03, 0);
    b_sym(8'hFD, 1);                                  // end of burst inside a data frame
    bfm_bit = 0; cycles(30);
    b_start(1);
    b_sym(8'h3C, 1); b_sym({3'd0, 2'd0, 3'd0}, 0); b_sym(8'h04, 0);
    b_raw(10'b0000000000);                            // code violation inside a data frame
    bfm_bit = 0; cycles(30);
    b_start(1);
    b_sym(8'h3C, 1);
    brd = !brd; b_sym(8'h00, 0);                      // disparity error
    bfm_bit = 0; cycles(30);
    b_start(2);
    b_raw(10'b1111100000);                            // code violation between frames
    brd = 1; b_sym(8'hBC, 1);                        // realign on an RD+ comma
    b_sym(8'h3C, 1); b_sym({3'd4, 5'h0A}, 0); ixq[1][ixt[1] % 1024] = 5'h0A; ixt[1]++;
    b_stop();
    cycles(30);
    if (n_err[1] < 15) fail($sformatf("only %0d receive errors flagged", n_err[1]));
    lax = 0; cnt_err = 0;
    quiet(10_000);

    // 5. reset in the middle of a burst
    add_frame(0, 5, 1);
    while (!tx_on[0]) @(negedge clk);
    cycles(500);
    rst_n = 0; cycles(2);
    for (int s = 0; s < 2; s++) begin
      fh[s] = ftl[s]; fidx[s] = 0; fslot[s] = 0; exh[s] = ext[s]; ixh[s] = ixt[s]; starve[s] = 0;
    end
    rst_n = 1; cycles(10);
    ctl(1, 0, 8'h77, 8'h99, 0); ctl(1, 1, 8'h77, 0, 0);
    quiet(10_000);

    $display("rx bytes %0d / %0d, interrupts %0d / %0d", n_rx[0], n_rx[1], n_int[0], n_int[1]);
    if (errors == 0) $display("TEST PASSED: DigRF");
    else $display("TEST FAILED: DigRF (%0d errors)", errors);
    $finish;
  end
  initial begin #300ms; $display("TEST FAILED: DigRF (timeout)"); $finish; end
endmodule
