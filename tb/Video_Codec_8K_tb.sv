// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Video_Codec_8K_top (TV SoC video decoder
// traffic shape, AXI4 manager). An independent model replays the CTU loop
// (bitstream words, motion-compensated reference blocks with the xorshift32
// motion vectors and picture clamping, luma and chroma reconstruction rows)
// and gives the exact order of word addresses read and written; monitors on
// the AXI4 channels collect the addresses of every read and write beat and
// compare them with the model, the write data with address ^ SEED and the
// read data sum with RD_SUM. Small pictures are also checked in memory.
// Covers: CTU 16 / 32 / 64, PU 8 .. CTU, 0 / 1 / 2 references, small and
// large motion vectors (clamping at all four picture edges), no bitstream,
// an 8K (7680 x 4320, CTU 64) geometry sampled with CTU_LIMIT, CTU_GAP rate
// shaping (no LATE when the slot is long, every CTU LATE when it is short),
// CFG_ERR cases, an AXI read error, START while busy, reset in the middle of
// a job, random and zero memory stalls. Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Video_Codec_8K_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic [31:0] bs_addr = 0, ref0_addr = 0, ref1_addr = 0, recon_addr = 0, chroma_addr = 0, seed = 0;
  logic [15:0] stride = 0, ctu_gap = 0, ctu_limit = 0;
  logic [7:0]  pic_w_ctu = 1, pic_h_ctu = 1, bs_words = 0;
  logic [2:0]  ctu_log2 = 4, pu_log2 = 3, mv_log2 = 2;
  logic [1:0]  n_refs = 0;
  logic        start = 0;
  wire         busy, err, cfg_err, done, late, err_irq;
  wire  [15:0] ctus, late_cnt;
  wire  [31:0] rd_words, wr_words, rd_sum, cycles;
  Video_Codec_8K_top dut (.*);

  int n_done = 0, n_err_irq = 0, n_late = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; n_late += late; end

  // ---------------- channel monitors ----------------
  logic [31:0] got_rd [$], got_wr [$];
  logic [31:0] ar_q_a [$], aw_q_a [$];
  int          ar_q_l [$], aw_q_l [$];
  int          rbeat = 0, wbeat = 0, n_wdata_bad = 0;
  logic [31:0] mon_sum = 0;
  always @(posedge clk) if (rst_n) begin
    if (m_arvalid && m_arready) begin ar_q_a.push_back(m_araddr); ar_q_l.push_back(m_arlen); end
    if (m_awvalid && m_awready) begin aw_q_a.push_back(m_awaddr); aw_q_l.push_back(m_awlen); end
    if (m_rvalid && m_rready) begin
      if (ar_q_a.size() == 0) fail("R beat without AR");
      else begin
        got_rd.push_back(ar_q_a[0] + 32'(4 * rbeat));
        mon_sum += m_rdata;
        if (rbeat == ar_q_l[0]) begin rbeat = 0; void'(ar_q_a.pop_front()); void'(ar_q_l.pop_front()); end
        else rbeat++;
      end
    end
    if (m_wvalid && m_wready) begin
      // the AW of this burst may be accepted in the same clock
      logic [31:0] a;
      if (aw_q_a.size() == 0 && !(m_awvalid && m_awready)) fail("W beat without AW");
      else begin
        a = (aw_q_a.size() != 0 ? aw_q_a[0] : m_awaddr) + 32'(4 * wbeat);
        got_wr.push_back(a);
        if (m_wdata !== (a ^ seed) && n_wdata_bad++ < 5) fail($sformatf("write data at %h = %h", a, m_wdata));
        if (m_wlast) begin wbeat = 0; void'(aw_q_a.pop_front()); void'(aw_q_l.pop_front()); end
        else wbeat++;
      end
    end
  end
  task automatic mon_clear;
    got_rd.delete(); got_wr.delete(); ar_q_a.delete(); ar_q_l.delete(); aw_q_a.delete(); aw_q_l.delete();
    rbeat = 0; wbeat = 0; mon_sum = 0;
  endtask

  // ---------------- reference model ----------------
  logic [31:0] ex_rd [$], ex_wr [$];
  int          ex_ctus;
  function automatic logic [31:0] xs32(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13); y = y ^ (y >> 17); return y ^ (y << 5);
  endfunction
  task automatic model;
    int ctu, pu, w, h, n, ox, oy, dx, dy;
    logic [31:0] lf, bsp, rb;
    ex_rd.delete(); ex_wr.delete();
    ctu = 1 << ctu_log2; pu = 1 << pu_log2;
    w = pic_w_ctu * ctu; h = pic_h_ctu * ctu;
    lf = seed == 0 ? 1 : seed; bsp = bs_addr; n = 0;
    for (int cy = 0; cy < pic_h_ctu; cy++) for (int cx = 0; cx < pic_w_ctu; cx++) begin
      if (ctu_limit != 0 && n >= ctu_limit) break;
      for (int i = 0; i < bs_words; i++) begin ex_rd.push_back(bsp); bsp += 4; end
      for (int py = 0; py < ctu / pu; py++) for (int px = 0; px < ctu / pu; px++)
        for (int r = 0; r < n_refs; r++) begin
          lf = xs32(lf);
          dx = $signed(lf[15:0]) >>> (15 - mv_log2);
          dy = $signed(lf[31:16]) >>> (15 - mv_log2);
          ox = cx * ctu + px * pu + dx - 3; oy = cy * ctu + py * pu + dy - 3;
          if (ox > w - pu - 7) ox = w - pu - 7;
          if (ox < 0) ox = 0;
          if (oy > h - pu - 7) oy = h - pu - 7;
          if (oy < 0) oy = 0;
          rb = r == 0 ? ref0_addr : ref1_addr;
          for (int row = 0; row < pu + 7; row++)
            for (int x = ox >> 2; x <= (ox + pu + 6) >> 2; x++)
              ex_rd.push_back(rb + 32'(oy + row) * 32'(stride) + 32'(4 * x));
        end
      for (int row = 0; row < ctu; row++) for (int x = 0; x < ctu / 4; x++)
        ex_wr.push_back(recon_addr + 32'(cy * ctu + row) * 32'(stride) + 32'(cx * ctu + 4 * x));
      for (int row = 0; row < ctu / 2; row++) for (int x = 0; x < ctu / 4; x++)
        ex_wr.push_back(chroma_addr + 32'(cy * ctu / 2 + row) * 32'(stride) + 32'(cx * ctu + 4 * x));
      n++;
    end
    ex_ctus = n;
  endtask

  // ---------------- one job ----------------
  task automatic go;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
  endtask
  task automatic wait_idle(input string what);
    int t;
    t = 0;
    while (busy && t < 3000000) begin @(negedge clk); t++; end
    if (busy) fail({what, ": job did not finish"});
  endtask
  task automatic cmp_list(input string what, input bit wr);
    int nbad, gn, en;
    logic [31:0] g, e;
    nbad = 0;
    gn = wr ? got_wr.size() : got_rd.size();
    en = wr ? ex_wr.size() : ex_rd.size();
    if (gn != en) fail($sformatf("%s: %0d %s words, expected %0d", what, gn, wr ? "write" : "read", en));
    for (int i = 0; i < gn && i < en; i++) begin
      g = wr ? got_wr[i] : got_rd[i];
      e = wr ? ex_wr[i] : ex_rd[i];
      if (g !== e && nbad++ < 4) fail($sformatf("%s: %s word %0d at %h, expected %h", what, wr ? "write" : "read", i, g, e));
    end
  endtask
  // run a job with the current registers and check it; check_mem for small pictures
  task automatic job(input string what, input bit check_mem);
    int nd0;
    model();
    mon_clear();
    if (check_mem) foreach (ex_wr[i]) mem.poke(ex_wr[i], 32'hBAD0_0000);
    nd0 = n_done;
    go();
    if (!busy) fail({what, ": not busy after START"});
    wait_idle(what);
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%s: %0d DONE pulses", what, n_done - nd0));
    if (err || cfg_err) fail({what, ": ERR / CFG_ERR"});
    if (ctus !== 16'(ex_ctus)) fail($sformatf("%s: CTUS %0d, expected %0d", what, ctus, ex_ctus));
    cmp_list(what, 0);
    cmp_list(what, 1);
    if (rd_words !== 32'(ex_rd.size())) fail($sformatf("%s: RD_WORDS %0d", what, rd_words));
    if (wr_words !== 32'(ex_wr.size())) fail($sformatf("%s: WR_WORDS %0d", what, wr_words));
    if (rd_sum !== mon_sum) fail($sformatf("%s: RD_SUM %h, expected %h", what, rd_sum, mon_sum));
    if (check_mem) begin
      int nbad;
      nbad = 0;
      foreach (ex_wr[i]) if (mem.peek(ex_wr[i]) !== (ex_wr[i] ^ seed) && nbad++ < 4)
        fail($sformatf("%s: memory at %h = %h", what, ex_wr[i], mem.peek(ex_wr[i])));
    end
  endtask
  // a small picture; the planes are 256 MB apart, which puts them 16 K
  // entries apart in the memory model's hash (no collisions up to 64 KB each)
  task automatic pic(input int wc, input int hc, input int cl2, input int pl2, input int nr, input int mvl,
                       input int bsw, input string what);
    pic_w_ctu = 8'(wc); pic_h_ctu = 8'(hc); ctu_log2 = 3'(cl2); pu_log2 = 3'(pl2);
    n_refs = 2'(nr); mv_log2 = 3'(mvl); bs_words = 8'(bsw);
    stride = 16'((wc << cl2) + 4 * ($urandom % 4));
    bs_addr = 32'h1000_0000 + 32'(4 * ($urandom % 64));
    ref0_addr = 32'h2000_0000; ref1_addr = 32'h3000_0000;
    recon_addr = 32'h4000_0000 + 32'(4 * ($urandom % 16)); chroma_addr = 32'h5000_0000;
    seed = $urandom;
    for (int i = 0; i < 64 * bsw; i++) mem.poke(bs_addr + 32'(4 * i), $urandom);
    for (int y = 0; y < (hc << cl2); y++) for (int x = 0; x < stride / 4; x++) begin
      mem.poke(ref0_addr + 32'(y) * 32'(stride) + 32'(4 * x), $urandom);
      mem.poke(ref1_addr + 32'(y) * 32'(stride) + 32'(4 * x), $urandom);
    end
    job(what, 1);
  endtask

  initial begin
    lat_master = "vdec8k";
    clks(3);
    rst_n = 1;
    clks(2);
    ctu_gap = 0; ctu_limit = 0;
    // geometry sweep on small pictures
    mem.stall = 0;
    pic(1, 1, 4, 4, 0, 2, 0, "intra only, no bitstream");
    pic(2, 2, 4, 3, 1, 2, 8, "CTU 16 PU 8 one ref");
    pic(3, 2, 4, 4, 2, 3, 5, "CTU 16 PU 16 two refs");
    mem.stall = 1;
    pic(2, 2, 5, 3, 2, 7, 16, "CTU 32 PU 8 large MV (clamping)");
    pic(2, 1, 5, 5, 1, 7, 3, "CTU 32 PU 32 large MV");
    pic(1, 1, 6, 6, 2, 0, 1, "CTU 64 PU 64 smallest MV");
    for (int k = 0; k < 6; k++) begin
      int cl2;
      mem.stall = k % 2;
      cl2 = 4 + $urandom % 3;
      pic(1 + $urandom % 3, 1 + $urandom % 2, cl2, 3 + $urandom % (cl2 - 2), $urandom % 3, $urandom % 8,
            $urandom % 20, $sformatf("random %0d", k));
    end
    // 8K picture: 120 x 68 CTUs of 64, sampled with CTU_LIMIT (first CTUs of
    // the top row and the wrap would take too long: two CTU rows on 16 CTUs wide)
    mem.stall = 0;
    pic_w_ctu = 120; pic_h_ctu = 68; ctu_log2 = 6; pu_log2 = 4; n_refs = 2; mv_log2 = 6; bs_words = 64;
    stride = 7680; ctu_limit = 3; seed = 32'h8C0D_EC8C;
    bs_addr = 32'h1000_0000; ref0_addr = 32'h2000_0000; ref1_addr = 32'h2400_0000;
    recon_addr = 32'h3000_0000; chroma_addr = 32'h3000_0000 + 32'd7680 * 32'd4320;
    job("8K geometry, first 3 CTUs", 0);
    ctu_limit = 0;
    pic(16, 2, 4, 4, 1, 4, 2, "CTU row wrap");
    ctu_limit = 5;
    pic(3, 3, 4, 4, 1, 2, 2, "CTU_LIMIT inside the picture");
    ctu_limit = 0;
    // rate shaping: a long slot never runs late, a 1-clock slot always does
    begin
      int nl0;
      pic_w_ctu = 2; pic_h_ctu = 2; ctu_log2 = 4; pu_log2 = 4; n_refs = 1; bs_words = 4;
      ctu_gap = 2000; nl0 = n_late;
      job("CTU_GAP 2000", 0);
      if (late_cnt != 0 || n_late != nl0) fail("LATE with a long CTU slot");
      if (cycles < 4 * 2000 - 2) fail($sformatf("CTU_GAP 2000: CYCLES %0d below 4 slots", cycles));
      ctu_gap = 1; nl0 = n_late;
      job("CTU_GAP 1", 0);
      if (late_cnt != 4 || n_late != nl0 + 4) fail($sformatf("CTU_GAP 1: LATE_CNT %0d", late_cnt));
      ctu_gap = 0;
      job("CTU_GAP 0", 0);
      if (late_cnt != 0) fail("LATE with CTU_GAP 0");
    end
    // CFG_ERR
    for (int t = 0; t < 7; t++) begin
      int nd0, nb0;
      pic_w_ctu = 2; pic_h_ctu = 2; ctu_log2 = 4; pu_log2 = 3; n_refs = 1;
      case (t)
        0: ctu_log2 = 3;
        1: ctu_log2 = 7;
        2: pu_log2 = 2;
        3: pu_log2 = 5;
        4: n_refs = 3;
        5: pic_w_ctu = 0;
        default: pic_h_ctu = 0;
      endcase
      nd0 = n_done; nb0 = mem.n_rd_bursts + mem.n_wr_bursts;
      go(); clks(3);
      if (busy || !cfg_err || n_done != nd0 + 1) fail($sformatf("CFG_ERR case %0d", t));
      if (mem.n_rd_bursts + mem.n_wr_bursts != nb0) fail($sformatf("CFG_ERR case %0d moved data", t));
    end
    // START while busy is ignored
    begin
      int nd0;
      pic(2, 2, 4, 4, 1, 2, 4, "before START while busy");
      nd0 = n_done;
      go(); clks(20); go();
      wait_idle("start while busy"); clks(2);
      if (n_done != nd0 + 1 || ctus != 4) fail("START while busy restarted the job");
    end
    // AXI read error on a bitstream word
    begin
      int ne0;
      mem.err_lo = bs_addr + 8; mem.err_hi = bs_addr + 12;
      ne0 = n_err_irq;
      mon_clear();
      go(); wait_idle("axi error"); clks(2);
      if (!err) fail("no ERR after an AXI error response");
      if (n_err_irq != ne0 + 1) fail("ERR interrupt count");
      if (ctus != 4) fail("AXI error: the job did not run to the end");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // ERR clears on the next START
    pic(2, 1, 4, 3, 2, 3, 2, "clean after error");
    // reset in the middle of a job
    pic_w_ctu = 4; pic_h_ctu = 4;
    go(); clks(300);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(4);
    pic(2, 2, 5, 4, 2, 5, 6, "after reset");
    lat_summary();
    finish("Video_Codec_8K");
  end
endmodule
