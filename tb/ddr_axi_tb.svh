// SPDX-License-Identifier: Apache-2.0
// Shared body of the self-checking testbenches of DDR4_AXI_top and
// LPDDR4_AXI_top (included inside the TB module after DDR_AXI_NAME, DDR_AXI_NCH
// and DDR_AXI_LP are defined).
// - Random AXI4 bursts: INCR / FIXED / WRAP, 1..32 beats (WRAP 2/4/8/16),
//   AxSIZE 0..2 at random addresses and random byte strobes, random IDs,
//   random BREADY / RREADY stalls and random gaps between requests.
// - Reference model: the core's halfword array (it aliases: NCH = 1 keeps
//   column h[7:0], NCH = 2 channel h[8] and column h[7:0]); LPDDR4 column
//   0xF0 writes are the MR7 frequency-set write and leave the array alone.
//   Every read beat is compared, as are RID / BID, RLAST, RRESP / BRESP.
// - Errors: AxSIZE = 3 on a read and on a write, WLAST early on a write:
//   SLVERR, and the array is unchanged.
// - Counters N_RD / N_WR / N_RMW / N_ERR against the TB's own counts.
// - Latency of every burst (first request clock to RLAST / B) is printed as
//   "LAT tb <DUT> R|W <cycles>" lines for the regression suite's lat_db.
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction

  logic [3:0]  s_awid = 0, s_arid = 0;
  logic [31:0] s_awaddr = 0, s_araddr = 0, s_wdata = 0;
  logic [7:0]  s_awlen = 0, s_arlen = 0;
  logic [2:0]  s_awsize = 0, s_arsize = 0;
  logic [1:0]  s_awburst = 0, s_arburst = 0;
  logic        s_awvalid = 0, s_wvalid = 0, s_wlast = 0, s_bready = 0, s_arvalid = 0, s_rready = 0;
  logic [3:0]  s_wstrb = 0;
  wire         s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
  wire  [3:0]  s_bid, s_rid;
  wire  [1:0]  s_bresp, s_rresp;
  wire  [31:0] s_rdata;
  wire         trace_valid;
  wire  [2:0]  trace_cmd;
  wire  [31:0] trace_addr;
  wire  [15:0] n_rd, n_wr, n_rmw, n_err;
  wire         err_irq;
  int          n_irq = 0;
  always @(posedge clk) if (rst_n && err_irq) n_irq++;

  logic [15:0] ref_mem [0:511];
  int exp_rd = 0, exp_wr = 0, exp_err = 0;
  int lat_min [2], lat_max [2], lat_sum [2], lat_n [2];

  function automatic int ridx(input logic [31:0] a);   // byte address -> array index
    logic [30:0] h;
    h = a[31:1];
    return (`DDR_AXI_NCH == 1) ? int'(h[7:0]) : int'({h[8], h[7:0]});
  endfunction
  function automatic logic [31:0] ref_word(input logic [31:0] a);
    return {ref_mem[ridx({a[31:2], 2'b10})], ref_mem[ridx({a[31:2], 2'b00})]};
  endfunction
  // AXI4 A3.4.1 beat addresses, written from the spec, independent of the RTL
  function automatic logic [31:0] beat_addr(input logic [31:0] start, input int sz, input int bt,
                                            input int len, input int n);
    longint unsigned nb, aligned, lower, wsize, a;
    nb = 64'd1 << sz;
    aligned = (start / nb) * nb;
    if (bt == 0) return start;
    if (n == 0) return start;
    if (bt == 1) return 32'(aligned + 64'(n) * nb);
    wsize = nb * 64'(len + 1);
    lower = (64'(start) / wsize) * wsize;
    a = aligned + 64'(n) * nb;
    if (a >= lower + wsize) a = a - wsize;
    return 32'(a);
  endfunction
  function automatic void lat(input int w, input int c);
    $display("LAT tb %s %s %0d", `DDR_AXI_NAME, w ? "W" : "R", c);
    if (lat_n[w] == 0 || c < lat_min[w]) lat_min[w] = c;
    if (lat_n[w] == 0 || c > lat_max[w]) lat_max[w] = c;
    lat_sum[w] += c; lat_n[w]++;
  endfunction

  int unsigned cyc = 0;
  always @(posedge clk) cyc++;

  task automatic gap; repeat ($urandom % 4) @(negedge clk); endtask

  // one write burst; early_last: WLAST on beat 0 of a longer burst
  task automatic wr(input logic [31:0] a, input int len, input int sz, input int bt, input bit early_last);
    logic [3:0] id;
    int t0, nb;
    bit bad;
    logic [31:0] ba;
    logic [31:0] d [];
    logic [3:0]  st [];
    id = $urandom; nb = early_last ? 1 : len + 1;
    bad = (sz > 2) || early_last;
    d = new[nb]; st = new[nb];
    for (int n = 0; n < nb; n++) begin
      logic [3:0] lanes;
      ba = beat_addr(a, sz, bt, len, n);
      lanes = (sz >= 2) ? 4'hF : (sz == 1) ? (ba[1] ? 4'hC : 4'h3) : (4'h1 << ba[1:0]);
      d[n] = $urandom;
      st[n] = ($urandom % 3 == 0) ? lanes : (4'($urandom) & lanes);
    end
    @(negedge clk);
    s_awid = id; s_awaddr = a; s_awlen = 8'(len); s_awsize = 3'(sz); s_awburst = 2'(bt); s_awvalid = 1;
    t0 = cyc;
    @(posedge clk); while (!s_awready) @(posedge clk);
    @(negedge clk); s_awvalid = 0;
    for (int n = 0; n < nb; n++) begin
      if ($urandom % 4 == 0) begin s_wvalid = 0; gap; end
      s_wdata = d[n]; s_wstrb = st[n]; s_wlast = early_last || (n == len); s_wvalid = 1;
      @(posedge clk); while (!s_wready) @(posedge clk);
      @(negedge clk);
    end
    s_wvalid = 0; s_wlast = 0;
    gap; s_bready = 1;
    @(posedge clk); while (!s_bvalid) @(posedge clk);
    lat(1, cyc - t0);
    if (s_bid != id) fail($sformatf("BID %0h, expected %0h", s_bid, id));
    if (s_bresp != (bad ? 2'b10 : 2'b00)) fail($sformatf("BRESP %0d (bad=%0d)", s_bresp, bad));
    @(negedge clk); s_bready = 0;
    exp_wr++; if (bad) exp_err++;
    if (!bad)
      for (int n = 0; n < nb; n++) begin
        logic [3:0]  sn;
        logic [31:0] dn;
        ba = beat_addr(a, sz, bt, len, n);
        sn = st[n]; dn = d[n];
        for (int b = 0; b < 4; b++) if (sn[b]) begin
          logic [31:0] bb;
          int i;
          bb = {ba[31:2], 2'(b)};
          i = ridx(bb);
          if (!(`DDR_AXI_LP && i[7:0] == 8'hF0)) begin
            if (b[0]) ref_mem[i][15:8] = dn[8*b +: 8]; else ref_mem[i][7:0] = dn[8*b +: 8];
          end
        end
      end
  endtask

  task automatic rd(input logic [31:0] a, input int len, input int sz, input int bt);
    logic [3:0] id;
    int t0;
    bit bad;
    id = $urandom; bad = (sz > 2);
    @(negedge clk);
    s_arid = id; s_araddr = a; s_arlen = 8'(len); s_arsize = 3'(sz); s_arburst = 2'(bt); s_arvalid = 1;
    t0 = cyc;
    @(posedge clk); while (!s_arready) @(posedge clk);
    @(negedge clk); s_arvalid = 0;
    for (int n = 0; n <= len; n++) begin
      logic [31:0] ba, e;
      if ($urandom % 3 == 0) begin s_rready = 0; gap; end
      s_rready = 1;
      @(posedge clk); while (!s_rvalid) @(posedge clk);
      ba = beat_addr(a, sz, bt, len, n);
      e = ref_word(ba);
      if (s_rid != id) fail($sformatf("RID %0h, expected %0h", s_rid, id));
      if (s_rlast != (n == len)) fail($sformatf("RLAST %0d on beat %0d of %0d", s_rlast, n, len + 1));
      if (s_rresp != (bad ? 2'b10 : 2'b00)) fail($sformatf("RRESP %0d (bad=%0d)", s_rresp, bad));
      if (!bad && s_rdata != e)
        fail($sformatf("read %08h beat %0d: %08h, expected %08h", ba, n, s_rdata, e));
      if (n == len) lat(0, cyc - t0);
      @(negedge clk);
    end
    s_rready = 0;
    exp_rd++; if (bad) exp_err++;
  endtask

  function automatic logic [31:0] rnd_addr(input int sz);
    logic [31:0] a;
    a = $urandom;
    if ($urandom % 2) a[31:10] = '0;
    return a & ~((32'd1 << sz) - 32'd1);
  endfunction

  task automatic rnd_burst;
    int sz, bt, len;
    logic [31:0] a;
    sz = ($urandom % 4 == 0) ? $urandom % 2 : 2;
    bt = $urandom % 3;
    len = (bt == 2) ? (2 << ($urandom % 4)) - 1 : ($urandom % 4 == 0) ? $urandom % 32 : $urandom % 4;
    a = rnd_addr(sz);
    if ($urandom % 2) wr(a, len, sz, bt, 0); else rd(a, len, sz, bt);
    gap;
  endtask

  initial begin
    for (int i = 0; i < 512; i++) ref_mem[i] = '0;
    repeat (4) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);
    // directed: full-word write / read-back, then halfword and byte merges
    wr(32'h0000_0100, 3, 2, 1, 0); rd(32'h0000_0100, 3, 2, 1);
    wr(32'h0000_0102, 0, 1, 1, 0); wr(32'h0000_0101, 0, 0, 1, 0); rd(32'h0000_0100, 0, 2, 1);
    // WRAP across its boundary, FIXED repeated
    wr(32'h0000_0038, 7, 2, 2, 0); rd(32'h0000_0030, 7, 2, 1);
    wr(32'h0000_0200, 4, 2, 0, 0); rd(32'h0000_0200, 2, 2, 0);
    // errors: AxSIZE 3, early WLAST
    wr(32'h0000_0040, 1, 3, 1, 0); rd(32'h0000_0040, 1, 3, 1);
    wr(32'h0000_0040, 3, 2, 1, 1); rd(32'h0000_0040, 3, 2, 1);
    repeat (600) rnd_burst;
    // read back the whole array
    for (int a = 0; a < 1024; a += 64) rd(32'(a), 15, 2, 1);
    repeat (5) @(negedge clk);
    if (n_rd != 16'(exp_rd)) fail($sformatf("N_RD %0d, expected %0d", n_rd, exp_rd));
    if (n_wr != 16'(exp_wr)) fail($sformatf("N_WR %0d, expected %0d", n_wr, exp_wr));
    if (n_err != 16'(exp_err)) fail($sformatf("N_ERR %0d, expected %0d", n_err, exp_err));
    if (n_rmw == 0) fail("no read-modify-write was exercised");
    if (n_irq != exp_err) fail($sformatf("ERR_IRQ pulsed %0d times, expected %0d", n_irq, exp_err));
    $display("%s: %0d reads, %0d writes, %0d RMW, %0d SLVERR", `DDR_AXI_NAME, n_rd, n_wr, n_rmw, n_err);
    for (int w = 0; w < 2; w++)
      $display("latency %s: min %0d avg %0d max %0d cycles over %0d bursts", w ? "W" : "R",
               lat_min[w], lat_sum[w] / (lat_n[w] ? lat_n[w] : 1), lat_max[w], lat_n[w]);
    if (errors == 0) $display("TEST PASSED: %s", `DDR_AXI_NAME);
    else $display("TEST FAILED: %s (%0d errors)", `DDR_AXI_NAME, errors);
    $finish;
  end
  initial begin #50ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
