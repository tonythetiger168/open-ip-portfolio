// SPDX-License-Identifier: Apache-2.0
// Self-checking unit testbench of soc_ss_axi_engine, the AXI4 manager data
// mover shared by the SoC subsystem IPs. The IPs close their own datapaths
// and list the engine under COVLIB; this bench closes the engine itself.
// Random jobs of every kind (read only, write only, read + write, neither),
// 0 to 300 words plus a few long ones (up to the 65535-word maximum), at
// buffers in low memory, at the top of the address space and across 4 KB
// boundaries, against soc_ss_axi_mem with random or zero stalls. The datapath
// is a TB FIFO with random backpressure between the read and write streams
// (read + write), a random-rate sink (read only) or a random-rate source
// (write only); every streamed and written word is checked. Also: START while
// busy is ignored, every non-OKAY response code (EXOKAY, SLVERR, DECERR) on a
// read and on a write sets ERR, DONE pulses once per job, reset mid-job.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module soc_ss_axi_engine_tb;
  `include "soc_ss_tb_common.svh"
  logic        start = 0, rd_en = 0, wr_en = 0;
  logic [31:0] src = 0, dst = 0;
  logic [15:0] len = 0;
  wire         busy, done, err;
  wire  [31:0] cycles;
  wire         rs_valid, ws_ready;
  wire  [31:0] rs_data;
  logic        rs_ready = 0, ws_valid = 0;
  logic [31:0] ws_data = 0;

  soc_ss_axi_engine #(.ID(4'hA), .PROT(3'b101)) dut (
    .clk, .rst_n, .start, .rd_en, .wr_en, .src, .dst, .len,
    .busy, .done, .err, .cycles,
    .rs_valid, .rs_data, .rs_ready, .ws_valid, .ws_data, .ws_ready,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  int n_done = 0;
  always @(posedge clk) if (rst_n) n_done += done;

  // ---------------------------------------------------------------- datapath
  // mode 3 (read + write): rs -> TB FIFO -> ws, data XOR KEY
  // mode 1 (read only):    rs -> sink, every word checked against memory
  // mode 2 (write only):   source -> ws, words KEY ^ index
  localparam logic [31:0] KEY = 32'h5A5A_0F0F;
  logic [1:0]  dp_mode = 0;
  int          rate = 100;          // % of clocks the TB side is ready / valid
  logic [31:0] q [$];
  int          n_rs = 0, n_ws = 0;
  logic [31:0] exp_rs [];
  bit          sink_on = 0, src_on = 0;
  logic hs_q;   // write stream handshake at the last posedge
  always @(negedge clk)
    rs_ready <= (dp_mode == 1 && sink_on) ? ($urandom % 100) < rate :
                (dp_mode == 3 && src_on)  ? ($urandom % 100) < rate && q.size() < 40 : 1'b0;
  always @(posedge clk) begin
    hs_q <= rst_n && ws_valid && ws_ready;
    if (rst_n && rs_valid && rs_ready) begin
      if (n_rs < exp_rs.size() && rs_data !== exp_rs[n_rs])
        fail($sformatf("read stream word %0d: %h, expected %h", n_rs, rs_data, exp_rs[n_rs]));
      if (dp_mode == 3) q.push_back(rs_data ^ KEY);
      n_rs++;
    end
    if (rst_n && ws_valid && ws_ready) begin
      n_ws++;
      if (dp_mode == 3) void'(q.pop_front());
    end
  end
  // write stream source: VALID and DATA held until accepted
  always @(negedge clk) begin
    if (!src_on) ws_valid <= 0;
    else if (!ws_valid || hs_q) begin
      if (dp_mode == 3) begin
        ws_valid <= q.size() > 0 && ($urandom % 100) < rate;
        ws_data  <= q.size() > 0 ? q[0] : 32'h0;
      end else begin
        ws_valid <= ($urandom % 100) < rate;
        ws_data  <= KEY ^ 32'(n_ws);
      end
    end
  end

  // ---------------------------------------------------------------- jobs
  // inject: 0 none, 1 read error, 2 write error (at word n/2)
  task automatic run(input int n, input bit rd, input bit wr, input int inject,
                     input bit restart, input logic [1:0] resp = 2'b10);
    logic [31:0] s, d;
    int t, nd0, nbad;
    s = pick_addr(n); d = dst_of(s);
    fill_rand(s, n);
    if (n > 2 && n % 5 == 0) mem.poke(s + 4, 32'h0);   // an all-zero word now and then
    for (int i = 0; i < n; i++) mem.poke(d + 32'(4 * i), 32'hBAD0_0000 ^ i);
    exp_rs = new[rd ? n : 0];
    for (int i = 0; i < (rd ? n : 0); i++) exp_rs[i] = mem.peek(s + 32'(4 * i));
    if (inject == 1 && !rd) inject = 0;
    if (inject == 2 && !wr) inject = 0;
    if (inject != 0 && n != 0) begin
      mem.err_lo = (inject == 1 ? s : d) + 32'(4 * (n / 2));
      mem.err_hi = mem.err_lo + 4;
      mem.err_resp = resp;
      if (inject == 1) for (int i = n / 2; i < n / 2 + 1; i++) exp_rs[i] = 32'hDEAD_BEEF;
    end
    @(negedge clk);
    q.delete(); n_rs = 0; n_ws = 0;
    dp_mode = {wr, rd};
    sink_on = rd; src_on = wr;
    src = s | 32'($urandom % 4); dst = d | 32'($urandom % 4);   // bits 1:0 ignored
    len = 16'(n); rd_en = rd; wr_en = wr;
    nd0 = n_done;
    start = 1;
    @(negedge clk);
    start = 0;
    if (!busy) fail("busy low after start");
    if (restart) begin
      clks(2);
      if (busy) begin   // ignored: the job in progress keeps its settings
        src = 32'h1234_5678; len = 16'd5; rd_en = !rd; wr_en = !wr;
        start = 1; @(negedge clk); start = 0;
      end
    end
    // read + write: the TB FIFO consumes the read stream
    t = 0;
    while (busy && t < 2000000) begin
      @(negedge clk); t++;
    end
    if (busy) fail($sformatf("job of %0d words (rd %0d wr %0d rate %0d) timed out: rstate %0d wstate %0d rf %0d wf %0d rleft %0d wleft %0d wtake %0d q %0d hs %0d wsv %0d", n, rd, wr, rate, dut.rstate, dut.wstate, dut.rf_cnt, dut.wf_cnt, dut.rleft, dut.wleft, dut.wtake, q.size(), hs_q, ws_valid));
    sink_on = 0; src_on = 0;
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one job", n_done - nd0));
    if (err !== (inject != 0 && n != 0)) fail($sformatf("ERR = %b, inject %0d", err, inject));
    if (cycles == 0) fail("CYCLES = 0");
    if (rd && n_rs != n) fail($sformatf("%0d read stream words, expected %0d", n_rs, n));
    if (wr && n_ws != n) fail($sformatf("%0d write stream words, expected %0d", n_ws, n));
    mem.err_lo = '1; mem.err_hi = '1;
    if (inject != 0 || !wr) return;
    nbad = 0;
    for (int i = 0; i < n; i++) begin
      logic [31:0] e;
      e = rd ? (mem.peek(s + 32'(4 * i)) ^ KEY) : (KEY ^ 32'(i));
      if (mem.peek(d + 32'(4 * i)) !== e && nbad++ < 5)
        fail($sformatf("word %0d of %0d at %h: %h, expected %h", i, n, d + 32'(4 * i),
                       mem.peek(d + 32'(4 * i)), e));
    end
  endtask

  int lens[7] = '{0, 1, 9, 16, 700, 1500, 65535};
  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    mem.rand_id = 1;
    run(0, 1, 1, 0, 0);
    run(0, 0, 0, 0, 0);
    run(5, 0, 0, 0, 0);
    run(1, 1, 1, 0, 0);
    run(16, 1, 0, 0, 0);
    run(17, 0, 1, 0, 1);
    for (int k = 0; k < 120; k++) begin
      mem.stall = (k % 4) != 3;
      rate = (k % 5 == 0) ? 100 : (k % 5 == 1) ? 10 : 30 + $urandom % 70;
      run(1 + $urandom % 300, $urandom % 2, $urandom % 2, 0, k % 9 == 0);
    end
    // every response code on both sides
    mem.stall = 1; rate = 80;
    for (int k = 0; k < 12; k++)   // side 1 read / 2 write x EXOKAY, SLVERR, DECERR
      run(5 + $urandom % 60, 1, k % 4 >= 2, 1 + k % 2, 0, 2'(1 + k % 3));
    // START held high: each job starts the clock after the last one's DONE
    @(negedge clk);
    rd_en = 0; wr_en = 0; len = 3; start = 1;
    clks(8);
    start = 0;
    clks(3);
    // long jobs: deep FIFO occupancy and the high bits of the counters
    mem.stall = 0; rate = 100;
    run(65535, 1, 1, 0, 0);
    rate = 5;
    run(400, 1, 0, 0, 0);
    run(400, 0, 1, 0, 0);
    rate = 100;
    run(4000, 0, 1, 0, 0);
    // every job kind at every length class (a job of neither kind ends at once)
    foreach (lens[i]) for (int kd = 0; kd < 4; kd++) run(lens[i], kd[0], kd[1], 0, 0);
    // reset in the middle of a job: the engine and the bus go idle
    @(negedge clk);
    src = 32'h0000_2000; dst = 32'h4000_2000; len = 200; rd_en = 1; wr_en = 1;
    dp_mode = 3; src_on = 1;
    start = 1; @(negedge clk); start = 0;
    clks(40);
    rst_n = 0; clks(2);
    if (busy || done || err || m_awvalid || m_arvalid || m_wvalid || rs_valid) fail("not idle in reset");
    src_on = 0;
    rst_n = 1; clks(10);
    mem.stall = 1;
    run(20, 1, 1, 0, 0);
    finish("soc_ss_axi_engine");
  end
endmodule
