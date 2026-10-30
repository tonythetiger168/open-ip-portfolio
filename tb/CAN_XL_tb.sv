// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for CAN_XL_top v1.0
//  * Two controllers on one wired-AND bus, on clocks that differ by 0.3%:
//    A (2048-byte buffers, the largest) and B (64-byte buffers).
//  * A bus-functional node (BFM) on A's clock encodes frames itself (own
//    stuffing, SBC and CRCs, both bit rates), with fault injection: a
//    flipped raw bit, a missing stuff bit, a wrong SBC with a matching
//    PCRC, a wrong FCRC, a dominant bit after the CRC, a CAN FD start.
//  * A bus monitor decodes every frame on the bus independently (switching
//    to the data bit rate where the format says so); after each valid frame
//    the transmitter's tx_done must match it, and each active controller
//    that did not send it must deliver it (header and buffer contents, cut
//    at its buffer size) exactly when its filter matches.
//  * Directed scenarios: CC and XL frames of many lengths both ways,
//    filters, arbitration (XL against XL and CC), errors in every field and
//    in the data phase, protocol exceptions, error passive, bus-off and
//    recovery, abort, refused frames, reset in the middle of a frame.
// ============================================================================
`timescale 1ns/1ps
module CAN_XL_tb;
  localparam int TIMEOUT_BITS = 30000;
  localparam int MAXA = 2048, MAXB = 64, FS = 10;
  typedef struct packed {
    logic        xl;
    logic [28:0] id;
    logic        ide, rtr;
    logic [10:0] dlc;
    logic [7:0]  sdt;
    logic        sec;
    logic [7:0]  vcid;
    logic [31:0] af;
  } hdr_t;
  // frame slots: 0 A's buffer, 1 B's buffer, 2 BFM, 3 monitor, 4 A rx, 5 B rx
  hdr_t       sh [0:7];
  logic [7:0] sd [0:7][0:2047];

  logic clk_a = 0, clk_b = 0;
  logic rst_a = 0, rst_b = 0;
  real  hb = 5.015;
  always #5 clk_a = ~clk_a;
  always #(hb) clk_b = ~clk_b;

  logic [5:0] cfg_brp = 1, cfg_dbrp = 0;
  logic [3:0] cfg_tseg1 = 5, cfg_dtseg1 = 3;
  logic [2:0] cfg_tseg2 = 2, cfg_dtseg2 = 1;
  logic [1:0] cfg_sjw = 1, cfg_dsjw = 0;

  // ---------------- node ports ----------------
  logic        a_txd, b_txd, a_tx_fast, a_rx_fast, b_tx_fast, b_rx_fast;
  logic [28:0] a_acc_code = 0, a_acc_mask = 0, b_acc_code = 0, b_acc_mask = 0;
  logic        a_hb_wen = 0, b_hb_wen = 0;
  logic [8:0]  a_hb_waddr = 0, a_hb_raddr = 0;
  logic [3:0]  b_hb_waddr = 0, b_hb_raddr = 0;
  logic [31:0] a_hb_wdata = 0, b_hb_wdata = 0, a_hb_rdata, b_hb_rdata;
  logic        a_tx_valid = 0, b_tx_valid = 0, a_tx_abort = 0, b_tx_abort = 0;
  hdr_t        a_th = '0, b_th = '0;
  logic        a_tx_ready, b_tx_ready, a_tx_done, b_tx_done, a_tx_aborted, b_tx_aborted;
  logic        a_tx_rejected, b_tx_rejected;
  logic        a_rx_valid, b_rx_valid, a_rx_trunc, b_rx_trunc;
  hdr_t        a_rh, b_rh;
  logic        a_arb_lost, b_arb_lost, a_pexc, b_pexc;
  logic        a_err_bit, a_err_stuff, a_err_crc, a_err_form, a_err_ack;
  logic        b_err_bit, b_err_stuff, b_err_crc, b_err_form, b_err_ack;
  logic [8:0]  a_tec, b_tec;
  logic [7:0]  a_rec, b_rec;
  logic        a_err_passive, b_err_passive, a_bus_off, b_bus_off;

  // ---------------- bus ----------------
  logic bfm_drv = 1;
  logic dis_a = 1, dis_b = 1;
  wire  bus  = a_txd & b_txd & bfm_drv;
  wire  rx_a = bus & dis_a;
  wire  rx_b = bus & dis_b;

  CAN_XL_top #(.MAX_BYTES(MAXA), .FS(FS)) u_a (
    .clk(clk_a), .rst_n(rst_a), .rxd(rx_a), .txd(a_txd), .tx_fast(a_tx_fast), .rx_fast(a_rx_fast),
    .cfg_brp(cfg_brp), .cfg_tseg1(cfg_tseg1), .cfg_tseg2(cfg_tseg2), .cfg_sjw(cfg_sjw),
    .cfg_dbrp(cfg_dbrp), .cfg_dtseg1(cfg_dtseg1), .cfg_dtseg2(cfg_dtseg2), .cfg_dsjw(cfg_dsjw),
    .acc_code(a_acc_code), .acc_mask(a_acc_mask),
    .hb_wen(a_hb_wen), .hb_waddr(a_hb_waddr), .hb_wdata(a_hb_wdata), .hb_raddr(a_hb_raddr), .hb_rdata(a_hb_rdata),
    .tx_valid(a_tx_valid), .tx_ready(a_tx_ready), .tx_xl(a_th.xl), .tx_id(a_th.id), .tx_ide(a_th.ide),
    .tx_rtr(a_th.rtr), .tx_dlc(a_th.dlc), .tx_sdt(a_th.sdt), .tx_sec(a_th.sec), .tx_vcid(a_th.vcid),
    .tx_af(a_th.af), .tx_abort(a_tx_abort), .tx_done(a_tx_done), .tx_aborted(a_tx_aborted),
    .tx_rejected(a_tx_rejected),
    .rx_valid(a_rx_valid), .rx_xl(a_rh.xl), .rx_id(a_rh.id), .rx_ide(a_rh.ide), .rx_rtr(a_rh.rtr),
    .rx_dlc(a_rh.dlc), .rx_sdt(a_rh.sdt), .rx_sec(a_rh.sec), .rx_vcid(a_rh.vcid), .rx_af(a_rh.af),
    .rx_trunc(a_rx_trunc), .arb_lost(a_arb_lost),
    .err_bit(a_err_bit), .err_stuff(a_err_stuff), .err_crc(a_err_crc), .err_form(a_err_form),
    .err_ack(a_err_ack), .pexc(a_pexc), .tec(a_tec), .rec(a_rec), .err_passive(a_err_passive),
    .bus_off(a_bus_off));

  CAN_XL_top #(.MAX_BYTES(MAXB), .FS(FS)) u_b (
    .clk(clk_b), .rst_n(rst_b), .rxd(rx_b), .txd(b_txd), .tx_fast(b_tx_fast), .rx_fast(b_rx_fast),
    .cfg_brp(cfg_brp), .cfg_tseg1(cfg_tseg1), .cfg_tseg2(cfg_tseg2), .cfg_sjw(cfg_sjw),
    .cfg_dbrp(cfg_dbrp), .cfg_dtseg1(cfg_dtseg1), .cfg_dtseg2(cfg_dtseg2), .cfg_dsjw(cfg_dsjw),
    .acc_code(b_acc_code), .acc_mask(b_acc_mask),
    .hb_wen(b_hb_wen), .hb_waddr(b_hb_waddr), .hb_wdata(b_hb_wdata), .hb_raddr(b_hb_raddr), .hb_rdata(b_hb_rdata),
    .tx_valid(b_tx_valid), .tx_ready(b_tx_ready), .tx_xl(b_th.xl), .tx_id(b_th.id), .tx_ide(b_th.ide),
    .tx_rtr(b_th.rtr), .tx_dlc(b_th.dlc), .tx_sdt(b_th.sdt), .tx_sec(b_th.sec), .tx_vcid(b_th.vcid),
    .tx_af(b_th.af), .tx_abort(b_tx_abort), .tx_done(b_tx_done), .tx_aborted(b_tx_aborted),
    .tx_rejected(b_tx_rejected),
    .rx_valid(b_rx_valid), .rx_xl(b_rh.xl), .rx_id(b_rh.id), .rx_ide(b_rh.ide), .rx_rtr(b_rh.rtr),
    .rx_dlc(b_rh.dlc), .rx_sdt(b_rh.sdt), .rx_sec(b_rh.sec), .rx_vcid(b_rh.vcid), .rx_af(b_rh.af),
    .rx_trunc(b_rx_trunc), .arb_lost(b_arb_lost),
    .err_bit(b_err_bit), .err_stuff(b_err_stuff), .err_crc(b_err_crc), .err_form(b_err_form),
    .err_ack(b_err_ack), .pexc(b_pexc), .tec(b_tec), .rec(b_rec), .err_passive(b_err_passive),
    .bus_off(b_bus_off));

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  // a for loop: Verilator 5.020 shares a repeat count between concurrent calls
  task automatic ca(input int n); for (int i = 0; i < n; i++) @(negedge clk_a); endtask

  // bit time / sample point in clk_a cycles, nominal (dp = 0) or data phase
  function automatic int bt_c(input bit dp);
    return dp ? (cfg_dbrp + 1) * (cfg_dtseg1 + cfg_dtseg2 + 3) : (cfg_brp + 1) * (cfg_tseg1 + cfg_tseg2 + 3);
  endfunction
  function automatic int spt_c(input bit dp);
    return dp ? (cfg_dbrp + 1) * (cfg_dtseg1 + 2) : (cfg_brp + 1) * (cfg_tseg1 + 2);
  endfunction
  function automatic int bt(); return bt_c(0); endfunction
  task automatic bits(input int n); ca(n * bt()); endtask

  // ---------------- frame format helpers ----------------
  function automatic int nbytes(input hdr_t h);
    if (h.xl) return int'(h.dlc) + 1;
    if (h.rtr) return 0;
    return h.dlc[3:0] > 8 ? 8 : int'(h.dlc[3:0]);
  endfunction
  function automatic hdr_t norm(input hdr_t h);
    hdr_t g;
    g = h;
    if (g.xl) begin g.id = {18'h0, h.id[10:0]}; g.ide = 0; g.rtr = 0; end
    else begin
      if (!g.ide) g.id = {18'h0, h.id[10:0]};
      g.dlc = {7'h0, h.dlc[3:0]}; g.sdt = 0; g.sec = 0; g.vcid = 0; g.af = 0;
    end
    return g;
  endfunction
  function automatic string fs(input hdr_t h);
    string s;
    if (h.xl) s = $sformatf("XL id %h sdt %h sec %b dlc %0d vcid %h af %h", h.id[10:0], h.sdt, h.sec, h.dlc, h.vcid, h.af);
    else s = $sformatf("CC id %h ide %b rtr %b dlc %0d", h.id, h.ide, h.rtr, h.dlc[3:0]);
    return s;
  endfunction
  function automatic bit acc(input hdr_t h, input logic [28:0] code, input logic [28:0] mask);
    hdr_t g;
    g = norm(h);
    return ((g.id ^ code) & mask) == 0;
  endfunction
  function automatic logic [14:0] crc15(input logic [14:0] c, input logic b);
    return {c[13:0], 1'b0} ^ ((b ^ c[14]) ? 15'h4599 : 15'h0);
  endfunction
  function automatic logic [12:0] crc13(input logic [12:0] c, input logic b);
    return {c[11:0], 1'b0} ^ ((b ^ c[12]) ? 13'h19E7 : 13'h0);
  endfunction
  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    return {c[30:0], 1'b0} ^ ((b ^ c[31]) ? 32'hF4ACFB13 : 32'h0);
  endfunction

  // ---------------- BFM encoder ----------------
  logic raw [0:20000];
  bit   raw_dp [0:20000];                // sent at the data bit rate
  int   raw_ix [0:20000];                // de-stuffed index (-1: stuff bit)
  int   n_raw, n_arb;
  bit   enc_sbc_bad = 0, enc_crc_bad = 0, enc_fd = 0, enc_r1 = 0;
  logic e_last;
  int   e_run, e_fs, e_dsc;
  logic [12:0] e_pcrc;
  logic [31:0] e_fcrc;
  logic [14:0] e_crc;
  function automatic void e_put(input logic v, input bit dp, input int ix);
    raw[n_raw] = v; raw_dp[n_raw] = dp; raw_ix[n_raw] = ix; n_raw++;
    if (v == e_last) e_run++; else begin e_run = 1; e_last = v; end
  endfunction
  task automatic build(input int s);
    hdr_t h;
    int nb, last, cst, fixl, ix;
    logic v;
    logic [1:0] g;
    logic [2:0] sbv;
    logic [28:0] hid;
    logic [10:0] hdlc;
    logic [7:0]  hsdt, hvcid;
    logic [31:0] haf;
    h = sh[s]; nb = nbytes(h);
    hid = h.id; hdlc = h.dlc; hsdt = h.sdt; hvcid = h.vcid; haf = h.af;
    n_raw = 0; e_last = 1'bx; e_run = 0; e_fs = 0; e_dsc = 0; e_pcrc = 0; e_fcrc = 0; e_crc = 0;
    cst  = h.xl ? 97 + 8 * nb : (h.ide ? 39 : 19) + 8 * nb;      // first CRC bit
    last = h.xl ? cst + 35 : cst + 14;                            // last body bit
    fixl = cst + 31;
    n_arb = h.ide ? 32 : 12;
    for (ix = 0; ix <= last; ix++) begin
      // the de-stuffed bit
      if (ix == 0) v = 0;
      else if (ix <= 11) v = h.ide && !h.xl ? hid[29 - ix] : hid[11 - ix];
      else if (ix == 12) v = h.ide && !h.xl ? 1'b1 : h.rtr && !h.xl;
      else if (ix == 13) v = h.ide && !h.xl;
      else if (h.xl) begin
        if (ix == 14) v = 1;
        else if (ix == 15) v = 1;
        else if (ix == 16) v = 0;
        else if (ix <= 19) v = 1;
        else if (ix == 20) v = 0;
        else if (ix <= 28) v = hsdt[28 - ix];
        else if (ix == 29) v = h.sec;
        else if (ix <= 40) v = hdlc[40 - ix];
        else if (ix <= 43) begin
          g = 2'(e_dsc) ^ (2'(e_dsc) >> 1);
          sbv = {g, ^g};
          v = sbv[43 - ix] ^ (enc_sbc_bad && ix == 43);
        end
        else if (ix <= 56) v = e_pcrc[56 - ix];
        else if (ix <= 64) v = hvcid[64 - ix];
        else if (ix <= 96) v = haf[96 - ix];
        else if (ix < cst) v = sd[s][(ix - 97) / 8][7 - (ix - 97) % 8];
        else if (ix < cst + 32) v = e_fcrc[31 - (ix - cst)] ^ (enc_crc_bad && ix == cst + 31);
        else v = ix < cst + 34;
      end
      else if (!h.ide && ix == 14) v = enc_fd;
      else if (!h.ide && ix == 15) v = enc_fd ? 1'b0 : hdlc[3];
      else if (!h.ide && ix <= 18) v = hdlc[18 - ix];
      else if (h.ide && ix <= 31) v = hid[31 - ix];
      else if (h.ide && ix == 32) v = h.rtr;
      else if (h.ide && ix == 33) v = enc_r1;
      else if (h.ide && ix == 34) v = 0;
      else if (h.ide && ix <= 38) v = hdlc[38 - ix];
      else if (ix < cst) v = sd[s][(ix - (h.ide ? 39 : 19)) / 8][7 - (ix - (h.ide ? 39 : 19)) % 8];
      else v = e_crc[14 - (ix - cst)] ^ (enc_crc_bad && ix == cst + 14);
      e_put(v, h.xl && ix >= 18, ix);
      if (ix <= 43) e_pcrc = crc13(e_pcrc, v);
      if (ix < cst) begin e_fcrc = crc32(e_fcrc, v); e_crc = crc15(e_crc, v); end
      // dynamic stuffing (CC: to the CRC end; XL: up to the stuff bit after resXL)
      if (e_run == 5 && ix <= (h.xl ? 16 : last)) begin
        e_put(~v, 0, -1); e_run = 1; e_dsc++;
        e_pcrc = crc13(e_pcrc, ~v);
      end
      // fixed stuffing from DL1 to the last FCRC bit
      if (h.xl && ix >= 20 && ix <= fixl) begin
        e_fs++;
        if (e_fs == FS && ix + 1 <= fixl) begin e_put(~raw[n_raw - 1], 1, -1); e_run = 1; e_fs = 0; end
      end
    end
  endtask

  // ---------------- BFM ----------------
  int bfm_flip = -1;                     // raw index to invert
  int bfm_skip = -1;                     // raw index of a stuff bit to drop
  int bfm_tail_dom = -1;                 // 0 CRC delim / DAH, 2 ACK delim, 3..9 EOF: dominant
  int bfm_stop = -1;                     // stop after this raw index (protocol exception)
  bit bfm_ack, bfm_lost, bfm_err, bfm_sync = 0;
  task automatic bfm_bit(input logic v, input bit dp, output logic seen);
    bfm_drv = v;
    ca(spt_c(dp));
    seen = bus;
    ca(bt_c(dp) - spt_c(dp));
  endtask
  task automatic bfm_send(input bit chk = 1);
    logic s;
    if (!bfm_sync) idle(3);
    bfm_sync = 0;
    build(2);
    bfm_ack = 0; bfm_lost = 0; bfm_err = 0;
    for (int i = 0; i < n_raw && !bfm_lost && !bfm_err && (bfm_stop < 0 || i <= bfm_stop); i++)
      if (i != bfm_skip) begin
        bfm_bit(i == bfm_flip ? ~raw[i] : raw[i], raw_dp[i], s);
        if (raw[i] && !s && i != bfm_flip) begin
          if (raw_ix[i] >= 1 && raw_ix[i] <= n_arb) begin bfm_lost = 1; bfm_drv = 1; end
          else bfm_err = 1;
        end
        if (i == bfm_flip || (bfm_skip >= 0 && i == bfm_skip + 1)) bfm_err = 1;
      end
    for (int t = 0; t < 10 && !bfm_lost && !bfm_err && bfm_stop < 0; t++) begin
      bfm_bit(t == bfm_tail_dom ? 1'b0 : 1'b1, 0, s);
      if (t == bfm_tail_dom) bfm_err = 1;
      else if (t == 1) begin bfm_ack = !s; if (s) bfm_err = 1; end
      else if (!s) bfm_err = 1;
    end
    bfm_drv = 1;
    if (chk && !bfm_lost && !bfm_err && bfm_stop < 0) begin
      bits(2);
      if (mon_last_n == mon_n_at_bfm) fail("BFM frame not seen by the monitor");
      else check_same(2, 3, 0, "BFM frame on the bus");
    end
    bfm_flip = -1; bfm_skip = -1; bfm_tail_dom = -1; bfm_stop = -1;
    enc_sbc_bad = 0; enc_crc_bad = 0; enc_fd = 0; enc_r1 = 0;
  endtask
  task automatic idle(input int n);
    int r, guard;
    r = 0; guard = 0;
    while (r < n * bt() && guard < TIMEOUT_BITS * bt()) begin
      @(negedge clk_a);
      r = bus ? r + 1 : 0;
      guard++;
    end
    if (guard >= TIMEOUT_BITS * bt()) fail("bus never idle");
    mon_n_at_bfm = mon_last_n;
  endtask

  // compare slot a with slot b (cut at max bytes when max > 0)
  task automatic check_same(input int a, input int b, input int max, input string what);
    int nb, nc;
    bit bad;
    if (norm(sh[a]) !== norm(sh[b])) fail($sformatf("%s: %s, expected %s", what, fs(sh[a]), fs(sh[b])));
    else begin
      nb = nbytes(sh[b]); nc = (max > 0 && nb > max) ? max : nb;
      bad = 0;
      for (int i = 0; i < nc && !bad; i++)
        if (sd[a][i] !== sd[b][i]) begin
          fail($sformatf("%s: byte %0d = %h, expected %h", what, i, sd[a][i], sd[b][i]));
          bad = 1;
        end
    end
  endtask

  // ---------------- bus monitor ----------------
  int   mon_n = 0, mon_bad = 0, mon_pexc = 0, mon_last_n = 0, mon_n_at_bfm = 0, mon_xl = 0;
  event mon_done;
  logic m_prev = 1;
  int   m_cyc = 0;
  bit   m_sof = 0;                       // the last bit ended on a falling edge
  task automatic mbit(input bit dp, output logic v);
    bit sampled, done, fe;
    sampled = 0; done = 0;
    while (!done) begin
      if (!sampled && m_cyc == spt_c(dp)) begin v = bus; sampled = 1; end
      @(negedge clk_a);
      m_cyc++;
      fe = m_prev && !bus;
      m_prev = bus;
      if (fe) begin m_cyc = 0; done = sampled; end       // resynchronise; after the sample: next bit
      else if (m_cyc >= bt_c(dp)) begin m_cyc = 0; done = sampled; end
    end
    m_sof = fe;
  endtask
  // n consecutive recessive bits at the nominal rate
  task automatic m_recessive(input int n);
    int r;
    logic v;
    r = 0;
    while (r < n) begin mbit(0, v); r = v ? r + 1 : 0; end
  endtask
  initial forever begin : monitor
    logic v0;
    if (m_sof) begin                       // an SOF right after 11 recessive bits
      m_sof = 0;
      mbit(0, v0);
      if (!v0) mon_frame();
    end else begin
    @(negedge clk_a);
    if (m_prev && !bus) begin
      m_prev = bus; m_cyc = 0;
      mbit(0, v0);
      if (!v0) mon_frame();
    end else m_prev = bus;
    end
  end
  task automatic mon_frame();
    logic v, last;
    int ix, run, fsn, dsc, cst, lastb, fixl, nb;
    bit ok, xl, ide, fdf, pexc;
    logic [12:0] pc;
    logic [31:0] fc;
    logic [14:0] cc;
    logic [7:0]  byt;
    hdr_t h;
    logic [1:0] g;
    logic [2:0] sbv;
    ix = 1; run = 1; last = 0; fsn = 0; dsc = 0; ok = 1; xl = 0; ide = 0; fdf = 0; pexc = 0;
    pc = 0; fc = 0; cc = 0; h = '0; nb = 0; cst = 99999; lastb = 99999; fixl = 99999;
    // (a CC frame can end with a stuff bit after the last CRC bit)
    while (ok && !pexc && (ix <= lastb || (!xl && ix == lastb + 1 && run == 5))) begin
      if (run == 5 && ix <= (xl ? 17 : lastb + 1)) begin                     // dynamic stuff
        mbit(0, v);
        if (v == last) ok = 0;
        last = v; run = 1; dsc++; pc = crc13(pc, v);
      end
      else if (xl && ix >= 21 && ix <= fixl && fsn == FS) begin              // fixed stuff
        mbit(1, v);
        if (v == last) ok = 0;
        last = v; run = 1; fsn = 0;
      end
      else begin
      mbit(xl && ix >= 18, v);
      if (v == last) run++; else begin run = 1; last = v; end
      if (ix <= 43) pc = crc13(pc, v);
      if (ix <= 11) h.id = {h.id[27:0], v};
      else if (ix == 12) h.rtr = v;
      else if (ix == 13) ide = v;
      else if (!ide && ix == 14) fdf = v;
      else if (!ide && ix == 15 && fdf) begin
        if (!v) pexc = 1;
        else begin xl = 1; h.xl = 1; h.rtr = 0; end
      end
      else if (xl) begin
        if ((ix == 16 || ix == 20) && v) ok = 0;
        else if (ix >= 17 && ix <= 19 && !v) ok = 0;
        else if (ix >= 21 && ix <= 28) h.sdt = {h.sdt[6:0], v};
        else if (ix == 29) h.sec = v;
        else if (ix >= 30 && ix <= 40) begin
          h.dlc = {h.dlc[9:0], v};
          if (ix == 40) begin
            nb = int'(h.dlc) + 1; cst = 97 + 8 * nb; lastb = cst + 35; fixl = cst + 31;
          end
        end
        else if (ix >= 41 && ix <= 43) begin
          g = 2'(dsc) ^ (2'(dsc) >> 1);
          sbv = {g, ^g};
          if (v != sbv[43 - ix]) ok = 0;
        end
        else if (ix >= 44 && ix <= 56) begin if (v != pc[56 - ix]) ok = 0; end
        else if (ix >= 57 && ix <= 64) h.vcid = {h.vcid[6:0], v};
        else if (ix >= 65 && ix <= 96) h.af = {h.af[30:0], v};
        else if (ix < cst) begin
          byt = {byt[6:0], v};
          if ((ix - 97) % 8 == 7) sd[3][(ix - 97) / 8] = byt;
        end
        else if (ix < cst + 32) begin if (v != fc[31 - (ix - cst)]) ok = 0; end
        else if (v != (ix < cst + 34)) ok = 0;
        if (ix >= 20 && ix <= fixl) fsn++;
      end
      else if (ide && ix == 33 && v) pexc = 1;
      else if (ide && ix <= 31) h.id = {h.id[27:0], v};
      else if (ide && ix == 32) h.rtr = v;
      else if ((ide && ix >= 35 && ix <= 38) || (!ide && ix >= 15 && ix <= 18)) begin
        h.dlc = {h.dlc[9:0], v};
        if (ix == (ide ? 38 : 18)) begin
          h.ide = ide;
          nb = nbytes(h); cst = (ide ? 39 : 19) + 8 * nb; lastb = cst + 14;
        end
      end
      else if (ix >= (ide ? 39 : 19) && ix < cst) begin
        byt = {byt[6:0], v};
        if ((ix - (ide ? 39 : 19)) % 8 == 7) sd[3][(ix - (ide ? 39 : 19)) / 8] = byt;
      end
      else if (ix >= cst && !xl) begin if (v != cc[14 - (ix - cst)]) ok = 0; end
      if (ix < cst) begin fc = crc32(fc, v); cc = crc15(cc, v); end
      ix++;
      end
    end
    if (pexc) begin mon_pexc++; m_recessive(11); end
    else begin
    // CRC delimiter / DAH, ACK slot, ACK delimiter, EOF 1..6
    if (ok) begin mbit(0, v); if (!v) ok = 0; end
    if (ok) begin mbit(0, v); if (v) ok = 0; end                              // no ACK: error frame
    if (ok) begin mbit(0, v); if (!v) ok = 0; end
    for (int e = 0; e < 6 && ok; e++) begin mbit(0, v); if (!v) ok = 0; end
    if (!ok) begin mon_bad++; m_recessive(11); end
    else begin
      sh[3] = h; mon_n++; mon_last_n = mon_n;
      if (xl) mon_xl++;
      -> mon_done;
      mbit(0, v);                                                            // EOF 7
    end
    end
  endtask

  // ---------------- delivery scoreboard ----------------
  int  a_rxn = 0, b_rxn = 0, a_txn = 0, b_txn = 0, a_got = 0, b_got = 0, a_rej = 0, b_rej = 0;
  int  a_abn = 0, b_abn = 0;
  int  a_ne [0:5], b_ne [0:5];             // error pulses: bit, stuff, crc, form, ack, pexc
  initial for (int i = 0; i < 6; i++) begin a_ne[i] = 0; b_ne[i] = 0; end
  always @(posedge clk_a) if (rst_a) begin
    if (a_err_bit) a_ne[0]++;
    if (a_err_stuff) a_ne[1]++;
    if (a_err_crc) a_ne[2]++;
    if (a_err_form) a_ne[3]++;
    if (a_err_ack) a_ne[4]++;
    if (a_pexc) a_ne[5]++;
  end
  always @(posedge clk_b) if (rst_b) begin
    if (b_err_bit) b_ne[0]++;
    if (b_err_stuff) b_ne[1]++;
    if (b_err_crc) b_ne[2]++;
    if (b_err_form) b_ne[3]++;
    if (b_err_ack) b_ne[4]++;
    if (b_pexc) b_ne[5]++;
  end
  // both receivers saw exactly one error pulse since the last call, of kind k
  int a_ne0 [0:5], b_ne0 [0:5];
  task automatic err_sync;
    for (int i = 0; i < 6; i++) begin a_ne0[i] = a_ne[i]; b_ne0[i] = b_ne[i]; end
  endtask
  task automatic exp_err(input int k, input string what);
    for (int i = 0; i < 6; i++) begin
      if (a_ne[i] - a_ne0[i] != (i == k) || b_ne[i] - b_ne0[i] != (i == k))
        fail($sformatf("%s: error pulse %0d: A %0d B %0d, expected kind %0d", what, i, a_ne[i] - a_ne0[i], b_ne[i] - b_ne0[i], k));
      a_ne0[i] = a_ne[i]; b_ne0[i] = b_ne[i];
    end
  endtask
  bit  a_trunc_q, b_trunc_q;
  hdr_t a_cur, b_cur, a_last, b_last;
  realtime a_done_t = 0, b_done_t = 0;
  always @(posedge clk_a) if (rst_a) begin
    if (a_tx_done) begin a_txn++; a_last = a_cur; a_done_t = $time; end
    if (a_tx_valid && a_tx_ready && !a_tx_rejected) a_cur = a_th;
    if (a_tx_rejected) a_rej++;
    if (a_tx_aborted) a_abn++;
    if (a_rx_valid) begin
      #1;
      sh[4] = a_rh; a_trunc_q = a_rx_trunc; a_got++; a_rxn++;
      for (int w = 0; w < MAXA / 4; w++) begin
        a_hb_raddr = 9'(w); #0.01;
        for (int i = 0; i < 4; i++) sd[4][4 * w + i] = a_hb_rdata[8 * i +: 8];
      end
    end
  end
  always @(posedge clk_b) if (rst_b) begin
    if (b_tx_done) begin b_txn++; b_last = b_cur; b_done_t = $time; end
    if (b_tx_valid && b_tx_ready && !b_tx_rejected) b_cur = b_th;
    if (b_tx_rejected) b_rej++;
    if (b_tx_aborted) b_abn++;
    if (b_rx_valid) begin
      #1;
      sh[5] = b_rh; b_trunc_q = b_rx_trunc; b_got++; b_rxn++;
      for (int w = 0; w < MAXB / 4; w++) begin
        b_hb_raddr = 4'(w); #0.01;
        for (int i = 0; i < 4; i++) sd[5][4 * w + i] = b_hb_rdata[8 * i +: 8];
      end
    end
  end
  bit chk_on = 1;
  initial forever begin : deliveries
    bit ta, tb, fa, fb;
    realtime t0;
    @(mon_done);
    t0 = $realtime;
    ta = rst_a && u_a.is_tx;
    tb = rst_b && u_b.is_tx;
    fa = acc(sh[3], a_acc_code, a_acc_mask);
    fb = acc(sh[3], b_acc_code, b_acc_mask);
    ca(bt() + 6);
    if (chk_on) begin
      if (ta) begin
        if (a_done_t < t0 - 3.0 * bt() * 10) fail("A sent a frame without tx_done");
        else if (norm(a_last) !== norm(sh[3])) fail($sformatf("A sent %s, bus had %s", fs(a_last), fs(sh[3])));
        else check_same(3, 0, 0, "A's frame on the bus");
      end
      if (tb) begin
        if (b_done_t < t0 - 3.0 * bt() * 10) fail("B sent a frame without tx_done");
        else if (norm(b_last) !== norm(sh[3])) fail($sformatf("B sent %s, bus had %s", fs(b_last), fs(sh[3])));
        else check_same(3, 1, 0, "B's frame on the bus");
      end
      if (rst_a && !ta && !a_bus_off && fa) begin
        if (a_got != 1) fail($sformatf("A did not deliver %s (%0d)", fs(sh[3]), a_got));
        else begin
          check_same(4, 3, MAXA, "A delivered");
          if (a_trunc_q != (nbytes(sh[3]) > MAXA)) fail("A rx_trunc");
        end
      end else if (a_got != 0) fail("A delivered a frame it should not");
      if (rst_b && !tb && !b_bus_off && fb) begin
        if (b_got != 1) fail($sformatf("B did not deliver %s (%0d)", fs(sh[3]), b_got));
        else begin
          check_same(5, 3, MAXB, "B delivered");
          if (b_trunc_q != (nbytes(sh[3]) > MAXB)) fail("B rx_trunc");
        end
      end else if (b_got != 0) fail("B delivered a frame it should not");
    end
    a_got = 0; b_got = 0;
  end

  // ---------------- host tasks ----------------
  function automatic hdr_t mk_cc(input logic [28:0] id, input bit ide, input bit rtr, input int dlc);
    hdr_t h;
    h = '0; h.id = id; h.ide = ide; h.rtr = rtr; h.dlc = 11'(dlc);
    return h;
  endfunction
  function automatic hdr_t mk_xl(input logic [10:0] id, input int nb, input logic [7:0] sdt = 8'h01,
                                 input logic [7:0] vcid = 8'h00, input logic [31:0] af = 32'h0, input bit sec = 0);
    hdr_t h;
    h = '0; h.xl = 1; h.id = {18'h0, id}; h.dlc = 11'(nb - 1); h.sdt = sdt; h.vcid = vcid; h.af = af; h.sec = sec;
    return h;
  endfunction
  // fill slot s with h and data: kind 0 random, 1 zeros, 2 ones, 3 count, 4 0x55
  task automatic fill(input int s, input hdr_t h, input int kind = 0);
    sh[s] = h;
    for (int i = 0; i < 2048; i++)
      case (kind)
        1: sd[s][i] = 8'h00;
        2: sd[s][i] = 8'hFF;
        3: sd[s][i] = 8'(i);
        4: sd[s][i] = 8'h55;
        default: sd[s][i] = 8'($urandom);
      endcase
  endtask
  function automatic hdr_t rnd_cc();
    hdr_t h;
    h = '0; h.ide = $urandom_range(1); h.rtr = $urandom_range(3) == 0;
    h.id = h.ide ? 29'($urandom) : {18'h0, 11'($urandom)};
    h.dlc = 11'($urandom_range(15));
    return h;
  endfunction
  function automatic hdr_t rnd_xl(input int maxb);
    return mk_xl(11'($urandom), $urandom_range(1, maxb), 8'($urandom), 8'($urandom), $urandom, $urandom_range(1));
  endfunction
  task automatic a_send(input hdr_t h, input int kind = 0);
    a_load(h, kind);
    a_go(h);
  endtask
  task automatic a_load(input hdr_t h, input int kind = 0);   // payload into A's buffer
    fill(0, h, kind);
    @(negedge clk_a);
    while (!a_tx_ready) @(negedge clk_a);
    for (int w = 0; w < MAXA / 4; w++) begin
      a_hb_wen = 1; a_hb_waddr = 9'(w);
      a_hb_wdata = {sd[0][4 * w + 3], sd[0][4 * w + 2], sd[0][4 * w + 1], sd[0][4 * w]};
      @(negedge clk_a);
    end
    a_hb_wen = 0;
  endtask
  task automatic a_go(input hdr_t h);
    a_th = h; a_tx_valid = 1;
    @(negedge clk_a);
    a_tx_valid = 0; a_th = hdr_t'({$urandom, $urandom, $urandom});
  endtask
  task automatic b_send(input hdr_t h, input int kind = 0);
    fill(1, h, kind);
    @(negedge clk_b);
    while (!b_tx_ready) @(negedge clk_b);
    for (int w = 0; w < MAXB / 4; w++) begin
      b_hb_wen = 1; b_hb_waddr = 4'(w);
      b_hb_wdata = {sd[1][4 * w + 3], sd[1][4 * w + 2], sd[1][4 * w + 1], sd[1][4 * w]};
      @(negedge clk_b);
    end
    b_hb_wen = 0;
    b_th = h; b_tx_valid = 1;
    @(negedge clk_b);
    b_tx_valid = 0; b_th = hdr_t'({$urandom, $urandom, $urandom});
  endtask
  task automatic wait_ready(input bit a, input bit b);
    int g;
    g = 0;
    while (((a && !a_tx_ready) || (b && !b_tx_ready)) && g < TIMEOUT_BITS * bt()) begin
      @(negedge clk_a); g++;
    end
    if (g >= TIMEOUT_BITS * bt()) fail("transmit never completed");
    bits(3);
  endtask
  task automatic a_abort; @(negedge clk_a); a_tx_abort = 1; @(negedge clk_a); a_tx_abort = 0; endtask
  task automatic b_abort; @(negedge clk_b); b_tx_abort = 1; @(negedge clk_b); b_tx_abort = 0; endtask
  task automatic reset_all;
    rst_a = 0; rst_b = 0;
    ca(5);
    if (a_txd !== 1 || b_txd !== 1 || a_tec !== 0 || a_rec !== 0 || !a_tx_ready || a_tx_fast || a_rx_fast)
      fail("reset values");
    if ({a_tx_done, a_tx_aborted, a_tx_rejected, a_rx_valid, a_rh, a_rx_trunc, a_arb_lost, a_err_bit,
         a_err_stuff, a_err_crc, a_err_form, a_err_ack, a_pexc, a_err_passive, a_bus_off} !== '0)
      fail("reset values of the pulses and the received header");
    rst_a = 1; rst_b = 1;
    idle(12);
  endtask
  task automatic exp_cnt(input int at, input int ar, input int bt_, input int br);
    if (at >= 0 && a_tec != at) fail($sformatf("A TEC %0d, expected %0d", a_tec, at));
    if (ar >= 0 && a_rec != ar) fail($sformatf("A REC %0d, expected %0d", a_rec, ar));
    if (bt_ >= 0 && b_tec != bt_) fail($sformatf("B TEC %0d, expected %0d", b_tec, bt_));
    if (br >= 0 && b_rec != br) fail($sformatf("B REC %0d, expected %0d", b_rec, br));
  endtask
  // drive A's input dominant for n bits once A is at de-stuffed index k of its own frame
  task automatic hit_a(input int k, input int n, input bit dp = 0);
    while (!(u_a.is_tx && u_a.mode == 2 && u_a.pos == 15'(k) && u_a.bit_start)) @(negedge clk_a);
    @(negedge clk_a);
    dis_a = 0; ca(n * bt_c(dp)); dis_a = 1;
  endtask
  // BFM frame in slot 2, raw index of de-stuffed index k
  function automatic int raw_of(input int k);
    for (int i = 0; i < n_raw; i++) if (raw_ix[i] == k) return i;
    return -1;
  endfunction
  function automatic int raw_stuff_after(input int k);
    for (int i = 0; i < n_raw; i++) if (raw_ix[i] == -1 && i > 0 && raw_ix[i - 1] >= k) return i;
    return -1;
  endfunction

  // ---------------- scenarios ----------------
  initial begin
    hdr_t h, g;
    int m0, k;
    ca(4);
    rst_a = 1; rst_b = 1;
    idle(12);

    // 1. CC frames both ways: base/extended, data/remote, DLC 0..15
    $display("[%0t] section 1: CC frames", $time);
    for (int i = 0; i < 16; i++) begin
      h = rnd_cc(); h.dlc = 11'(i); h.rtr = 0; h.ide = i[0];
      a_send(h); wait_ready(1, 0);
      g = rnd_cc(); g.dlc = 11'(15 - i); g.ide = ~i[0];
      b_send(g); wait_ready(0, 1);
    end
    a_send(mk_cc(29'h1FFF_FFFF, 1, 0, 8), 2); wait_ready(1, 0);
    b_send(mk_cc(29'h0, 1, 0, 8), 1); wait_ready(0, 1);
    a_send(mk_cc(29'h7FF, 0, 1, 0)); wait_ready(1, 0);
    b_send(mk_cc(29'h0, 0, 0, 8), 1); wait_ready(0, 1);
    // ID corners of every CC kind towards A
    for (int i = 0; i < 6; i++) begin
      case (i)
        0: h = mk_cc(29'h1FFF_FFFF, 1, 0, 3);
        1: h = mk_cc(29'h1FFF_FFFF, 1, 1, 3);
        2: h = mk_cc(29'h0, 1, 1, 0);
        3: h = mk_cc(29'h7FF, 0, 0, 1);
        4: h = mk_cc(29'h7FF, 0, 1, 2);
        default: h = mk_cc(29'h0, 0, 1, 8);
      endcase
      b_send(h); wait_ready(0, 1);
    end
    exp_cnt(0, 0, 0, 0);

    // 2. XL frames both ways: lengths, field corners, payload patterns
    $display("[%0t] section 2: XL frames", $time);
    for (int i = 0; i < 12; i++) begin
      k = i == 0 ? 1 : i == 1 ? 2 : i == 2 ? 7 : i == 3 ? 8 : i == 4 ? 9 : i == 5 ? 31 : i == 6 ? 63 : i == 7 ? 64 : $urandom_range(1, 64);
      a_send(mk_xl(11'($urandom), k, 8'($urandom), 8'($urandom), $urandom, i[0]), i % 5); wait_ready(1, 0);
      b_send(mk_xl(11'($urandom), 65 - k, 8'($urandom), 8'($urandom), $urandom, ~i[0]), i % 5); wait_ready(0, 1);
    end
    a_send(mk_xl(11'h7FF, 256, 8'hFF, 8'hFF, 32'hFFFF_FFFF, 1), 2); wait_ready(1, 0);       // B cuts at 64
    a_send(mk_xl(11'h1C3, 2048, 8'h3C, 8'hC3, 32'h1234_5678, 0), 3); wait_ready(1, 0);     // the longest
    a_send(mk_xl(11'h1C4, 1600, 8'h3D, 8'hC4, 32'h8765_4321, 1)); wait_ready(1, 0);
    a_send(mk_xl(11'h000, 200, 8'h00, 8'h00, 32'h0, 0), 1); wait_ready(1, 0);
    a_send(mk_xl(11'h555, 65, 8'hAA, 8'h55, 32'hAAAA_5555, 1), 4); wait_ready(1, 0);
    b_send(mk_xl(11'h2AA, 64, 8'h55, 8'hAA, 32'h5555_AAAA, 0), 3); wait_ready(0, 1);
    b_send(mk_xl(11'h000, 1, 8'h00, 8'h00, 32'h0, 0), 1); wait_ready(0, 1);
    b_send(mk_xl(11'h7FF, 64, 8'hFF, 8'hFF, 32'hFFFF_FFFF, 1), 2); wait_ready(0, 1);
    b_send(mk_xl(11'h078, 3), 3); wait_ready(0, 1);              // three dynamic stuff bits
    // frames longer than the buffer are refused
    @(negedge clk_b); b_th = mk_xl(11'h10, 65); b_tx_valid = 1; @(negedge clk_b); b_tx_valid = 0;
    bits(2);
    if (a_rej != 0 || b_rej != 1 || !a_tx_ready || !b_tx_ready) fail("oversized frame not refused");
    // BFM: XL frames from 1 to 2048 bytes (B cuts at 64)
    for (int i = 0; i < 6; i++) begin
      fill(2, mk_xl(11'($urandom), i == 0 ? 2048 : i == 1 ? 257 : i == 2 ? 256 : i == 3 ? 300 : $urandom_range(1, 100),
                    8'($urandom), 8'($urandom), $urandom, i[0]), i % 5);
      bfm_send();
      if (!bfm_ack) fail("BFM XL frame not acknowledged");
    end
    for (int i = 0; i < 10; i++) begin
      if (i % 2) a_send(rnd_xl(MAXB)); else b_send(rnd_xl(MAXB));
      wait_ready(1, 1);
      if (i % 3 == 0) begin a_send(rnd_cc()); wait_ready(1, 0); end
    end
    exp_cnt(0, 0, 0, 0);

    // 3. acceptance filters (XL frames filter on the priority ID)
    $display("[%0t] section 3: filters", $time);
    b_acc_mask = 29'h7FF; b_acc_code = 29'h123;
    a_send(mk_xl(11'h123, 4)); wait_ready(1, 0);
    a_send(mk_xl(11'h124, 4)); wait_ready(1, 0);
    a_send(mk_cc(29'h123, 0, 0, 2)); wait_ready(1, 0);
    a_send(mk_cc(29'h1FFF_F923, 1, 0, 1)); wait_ready(1, 0);
    b_acc_mask = 0; a_acc_mask = 29'h1FFF_FFFF; a_acc_code = 29'h0000_0456;
    b_send(mk_xl(11'h456, 9)); wait_ready(0, 1);
    b_send(mk_xl(11'h457, 9)); wait_ready(0, 1);
    a_acc_mask = 29'h1FFF_FFFF; a_acc_code = 29'h1FFF_FFFF;
    b_send(mk_cc(29'h1FFF_FFFF, 1, 0, 2)); wait_ready(0, 1);
    b_send(mk_cc(29'h1FFF_FFFE, 1, 0, 2)); wait_ready(0, 1);
    a_acc_mask = 0; a_acc_code = 0; b_acc_code = 0;

    // 4. arbitration: queued while the bus is busy, so both start together
    $display("[%0t] section 4: arbitration", $time);
    for (int i = 0; i < 8; i++) begin
      case (i)
        0: begin h = mk_xl(11'h100, 8); g = mk_xl(11'h101, 8); end
        1: begin h = mk_xl(11'h300, 3); g = mk_cc(29'h0FF, 0, 0, 1); end
        2: begin h = mk_cc(29'h155 << 18, 1, 0, 2); g = mk_xl(11'h155, 2); end
        3: begin h = mk_cc(29'h2AA, 0, 1, 2); g = mk_xl(11'h2AA, 20); end      // RTR against RRS
        4: begin h = mk_xl(11'h0F0, 64); g = mk_cc(29'h0F1, 0, 0, 8); end
        5: begin h = mk_cc(29'h0AA << 18 | 29'h3, 1, 1, 0); g = mk_cc(29'h0AA, 0, 1, 0); end   // IDE
        6: begin h = mk_cc(29'h0AA << 18 | 29'h3, 1, 0, 1); g = mk_cc(29'h0AA << 18 | 29'h2, 1, 0, 1); end
        default: begin h = mk_xl(11'h7FE, 40); g = mk_xl(11'h7FF, 40); end
      endcase
      // both frames queued during a BFM frame
      fork
        begin fill(2, rnd_cc()); bfm_send(0); end
        begin bits(5); a_send(h); end
        begin @(negedge clk_b); while (bus) @(negedge clk_b); b_send(g); end
      join
      wait_ready(1, 1);
      idle(11);
    end
    // the BFM loses arbitration against A's XL frame
    a_send(mk_xl(11'h010, 3));
    @(negedge bus);
    bfm_sync = 1;
    fill(2, mk_xl(11'h011, 3)); bfm_send(0);
    if (!bfm_lost) fail("BFM should have lost arbitration");
    wait_ready(1, 0);
    idle(11);
    // A pending at the end of a BFM frame: the BFM's next SOF comes at the
    // 3rd intermission bit, A joins with its first ID bit and loses
    fork
      begin fill(2, mk_xl(11'h020, 2)); bfm_send(0); end
      begin bits(10); a_send(mk_xl(11'h030, 2)); end
    join
    ca(2 * bt());
    bfm_sync = 1;
    fill(2, mk_xl(11'h021, 2)); bfm_send();
    if (bfm_lost || bfm_err || !bfm_ack) fail("BFM frame at the 3rd intermission bit");
    wait_ready(1, 0);
    idle(11);
    // A queues its frame after the BFM's SOF edge but before A samples it:
    // A joins that SOF and wins with the lower ID
    a_load(mk_xl(11'h040, 2));
    fork
      begin fill(2, mk_xl(11'h050, 2)); bfm_send(); end
      begin @(negedge bus); @(negedge clk_a); a_go(mk_xl(11'h040, 2)); end
    join
    if (!bfm_lost) fail("A did not join the BFM's SOF");
    wait_ready(1, 0);
    idle(11);

    // 5. receive errors from the BFM: each +1 REC at A and B
    $display("[%0t] section 5: receive errors", $time);
    exp_cnt(0, 0, 0, 0);
    m0 = 0;
    err_sync();
    fill(2, mk_xl(11'h3C3, 20)); build(2);
    bfm_flip = raw_of(25);    fill(2, mk_xl(11'h3C3, 20)); bfm_send(); idle(11); m0++; exp_err(1, "rx error case 1");  // SDT (the flip makes a stuff error)
    build(2);
    bfm_flip = raw_of(50);    bfm_send(); idle(11); m0++; exp_err(2, "rx error case 2");                // PCRC bit
    bfm_flip = raw_of(17);    bfm_send(); idle(11); m0++; exp_err(3, "rx error case 3");                // ADH dominant
    bfm_flip = raw_of(16);    bfm_send(); idle(11); m0++; exp_err(3, "rx error case 4");                // resXL recessive
    bfm_flip = raw_of(20);    bfm_send(); idle(11); m0++; exp_err(3, "rx error case 5");                // DL1 recessive
    bfm_flip = raw_of(130);   bfm_send(); idle(11); m0++; exp_err(1, "rx error case 6");                // data (the flip makes a stuff error)
    bfm_flip = raw_of(97 + 160 + 33); bfm_send(); idle(11); m0++; exp_err(3, "rx error case 7");        // FCP
    bfm_flip = raw_stuff_after(60); bfm_send(); idle(11); m0++; exp_err(1, "rx error case 8");          // fixed stuff bit
    enc_sbc_bad = 1;          bfm_send(); idle(11); m0++; exp_err(2, "rx error case 9");                // SBC, PCRC right
    enc_crc_bad = 1;          bfm_send(); idle(11); m0++; exp_err(2, "rx error case 10");               // FCRC
    bfm_tail_dom = 0;         bfm_send(); idle(11); m0++; exp_err(3, "rx error case 11");               // DAH
    bfm_tail_dom = 2;         bfm_send(); idle(11); m0++; exp_err(3, "rx error case 12");               // ACK delimiter
    bfm_tail_dom = 5;         bfm_send(); idle(11); m0++; exp_err(3, "rx error case 13");               // EOF
    fill(2, mk_xl(11'h000, 4, 8'h00, 8'h00, 32'h0)); build(2);
    bfm_skip = raw_stuff_after(1); bfm_send(); idle(11); m0++; exp_err(1, "rx error case 14");          // dynamic stuff
    fill(2, mk_cc(29'h0F0, 0, 0, 1)); enc_crc_bad = 1; bfm_send(); idle(11); m0++; exp_err(2, "rx error case 15");  // CC CRC
    fill(2, mk_cc(29'h000, 0, 0, 0)); build(2);
    bfm_skip = raw_stuff_after(1); bfm_send(); idle(11); m0++; exp_err(1, "rx error case 16");
    fill(2, mk_cc(29'h0F1, 0, 0, 0)); bfm_tail_dom = 0; bfm_send(); idle(11); m0++; exp_err(3, "rx error case 17");
    exp_cnt(0, m0, 0, m0);
    fill(2, mk_xl(11'h0F4, 3)); bfm_tail_dom = 9; bfm_send(0); idle(11);                // EOF bit 7: ignored
    exp_cnt(0, m0 - 1, 0, m0 - 1);
    for (int i = 0; i < m0; i++) begin fill(2, rnd_xl(30)); bfm_send(); end
    exp_cnt(0, 0, 0, 0);

    // 6. protocol exceptions: a CAN FD base frame, an extended frame with r1 set
    $display("[%0t] section 6: protocol exceptions", $time);
    err_sync();
    fill(2, mk_cc(29'h3F0, 0, 0, 8)); enc_fd = 1; bfm_send(0); idle(11); exp_err(5, "FD frame");
    fill(2, mk_cc(29'h1234_5678, 1, 0, 8)); enc_r1 = 1; bfm_send(0); idle(11); exp_err(5, "r1 recessive");
    fill(2, mk_cc(29'h0F0, 0, 0, 8)); enc_fd = 1; build(2); bfm_stop = raw_of(16); bfm_send(0); idle(11);
    exp_err(5, "FD frame cut short");
    if (mon_pexc != 3) fail($sformatf("monitor saw %0d protocol exceptions", mon_pexc));
    exp_cnt(0, 0, 0, 0);
    a_send(mk_xl(11'h1, 4)); wait_ready(1, 0);

    // 7. transmit errors at A only
    $display("[%0t] section 7: transmit errors", $time);
    a_send(mk_xl(11'h555, 32), 2);
    hit_a(110, 2, 1);                                    // data phase: bit error
    wait_ready(1, 0);
    exp_cnt(7, -1, 0, -1);
    a_send(mk_xl(11'h7FF, 4));
    hit_a(2, 1);                                         // arbitration: lost, then stuff errors
    wait_ready(1, 0);
    idle(11);
    m0 = a_tec; err_sync();
    a_send(mk_cc(29'h000, 0, 0, 0));
    hit_a(5, 1);                                         // recessive stuff bit in arbitration
    wait_ready(1, 0);
    idle(11);
    if (a_tec != (m0 > 0 ? m0 - 1 : 0) || a_ne[1] - a_ne0[1] != 1) fail("stuff error in arbitration: no TEC");
    m0 = a_tec; err_sync();
    a_send(mk_cc(29'h000, 0, 0, 0));
    hit_a(15, 1);                                        // recessive stuff bit after r0: TEC + 8
    wait_ready(1, 0);
    idle(11);
    if (a_tec != m0 + 7 || a_ne[1] - a_ne0[1] != 1) fail("transmitter stuff error after arbitration");
    a_send(mk_xl(11'h3A5, 4));
    while (!(u_a.is_tx && u_a.mode == 2 && u_a.xknown && u_a.k == 15'd1 && u_a.bit_start)) @(negedge clk_a);
    @(negedge clk_a); dis_a = 0; bits(1); dis_a = 1;      // DAH dominant at A only
    wait_ready(1, 0);
    idle(11);
    chk_on = 0;                                          // B gets this frame twice
    a_send(mk_xl(11'h3A6, 4));
    while (!(u_a.is_tx && u_a.mode == 2 && u_a.xknown && u_a.k == 15'd10 && u_a.bit_start)) @(negedge clk_a);
    @(negedge clk_a); dis_a = 0; bits(1); dis_a = 1;      // EOF 7 dominant at A: form error, resent
    wait_ready(1, 0);
    idle(11);
    chk_on = 1;
    m0 = a_tec;
    for (int i = 0; i < 12; i++) begin a_send(rnd_xl(16)); wait_ready(1, 0); end
    if (a_tec != (m0 > 12 ? m0 - 12 : 0)) fail("TEC count-down");

    // 8. error passive: B offline, A gets no ACK; TEC stops at 128
    $display("[%0t] section 8: error passive", $time);
    rst_b = 0;
    a_send(mk_xl(11'h321, 6));
    begin : wait_flag
      int g2;
      g2 = 0;
      while (!a_err_passive && g2 < 400000) begin @(negedge clk_a); g2++; end
      if (!a_err_passive) fail("A never became error passive");
    end
    bits(300);
    m0 = a_tec;
    bits(300);
    if (a_tec != m0) fail("TEC moved on passive ACK errors");
    a_abort();
    wait_ready(1, 0);
    rst_b = 1;
    idle(11);
    // still passive after a bit error and a good frame (TEC 135): A
    // suspends after its frame, and B's frame starts during the suspension
    a_send(mk_xl(11'h010, 4)); b_send(mk_cc(29'h7F0, 0, 0, 1));
    hit_a(17, 1);
    wait_ready(1, 1);
    if (!u_a.err_passive) fail("A should still be error passive");
    idle(11);
    for (int i = 0; i < 4; i++) begin a_send(rnd_xl(8)); b_send(rnd_cc()); wait_ready(1, 1); end
    b_send(mk_cc(29'h0F, 0, 0, 8), 1);
    @(negedge b_txd); bits(25); dis_a = 0; bits(1); dis_a = 1;   // passive flag at A
    wait_ready(0, 1);
    idle(11);

    // 9. bus-off and recovery
    $display("[%0t] section 9: bus-off", $time);
    a_send(mk_xl(11'h2F0, 24), 3);
    for (int i = 0; i < 40 && !a_bus_off; i++) hit_a(100, 3, 1);
    if (!a_bus_off) fail("A never went bus-off");
    b_send(mk_cc(29'h77, 0, 0, 1));
    begin : wait_recovery
      int g2;
      g2 = 0;
      while (a_bus_off && g2 < 12000 * bt()) begin @(negedge clk_a); g2++; end
      if (a_bus_off) fail("no bus-off recovery");
      if (g2 < 128 * 11 * bt()) fail("bus-off recovery before 128 x 11 recessive bits");
    end
    exp_cnt(0, 0, -1, -1);
    wait_ready(1, 1);
    idle(11);
    reset_all();

    // 10. REC above 127, then 120 after a good frame
    $display("[%0t] section 10: receive error passive", $time);
    for (int i = 0; i < 128; i++) begin fill(2, mk_cc(29'(i), 0, 0, 0)); enc_crc_bad = 1; bfm_send(0); idle(11); end
    exp_cnt(-1, 128, -1, 128);
    if (!a_err_passive || !b_err_passive) fail("receivers not error passive");
    fill(2, mk_xl(11'h44, 2)); bfm_send(); idle(11);
    exp_cnt(-1, 120, -1, 120);
    for (int i = 0; i < 140; i++) begin fill(2, mk_cc(29'(i), 0, 1, 0)); enc_crc_bad = 1; bfm_send(0); idle(11); end
    exp_cnt(-1, 255, -1, 255);
    reset_all();

    // 11. abort
    $display("[%0t] section 11: abort", $time);
    k = a_abn;
    fork
      begin fill(2, mk_xl(11'h1, 30)); bfm_send(); end
      begin bits(10); a_send(mk_xl(11'h2, 2)); a_abort(); end
    join
    wait_ready(1, 0);
    if (a_abn != k + 1) fail("abort while receiving: no tx_aborted");
    idle(11);
    a_send(mk_xl(11'h3, 16));
    @(negedge a_txd); bits(5);
    a_abort();                                           // too late: frame completes
    wait_ready(1, 0);
    if (a_abn != k + 1) fail("tx_aborted for a frame that completed");
    rst_b = 0;
    a_send(mk_xl(11'h4, 1));
    bits(60);
    a_abort();
    wait_ready(1, 0);
    if (a_abn != k + 2) fail("abort between retransmissions: no tx_aborted");
    rst_b = 1;
    idle(11);

    // 12. bit timing variants
    $display("[%0t] section 12: bit timing", $time);
    cfg_dbrp = 1; cfg_dtseg1 = 2; cfg_dtseg2 = 1; cfg_dsjw = 1;
    reset_all();
    a_send(rnd_xl(MAXB)); b_send(rnd_xl(MAXB)); wait_ready(1, 1);
    fill(2, rnd_xl(80)); bfm_send();
    cfg_dbrp = 0; cfg_dtseg1 = 2; cfg_dtseg2 = 1; cfg_dsjw = 0;            // 6-clock data bits (the minimum)
    reset_all();
    a_send(rnd_xl(MAXB)); b_send(rnd_xl(MAXB)); wait_ready(1, 1);
    cfg_brp = 3; cfg_tseg1 = 9; cfg_tseg2 = 4; cfg_sjw = 3;
    cfg_dbrp = 2; cfg_dtseg1 = 15; cfg_dtseg2 = 7; cfg_dsjw = 3;           // data slower than nominal
    reset_all();
    a_send(rnd_xl(20)); b_send(rnd_cc()); wait_ready(1, 1);
    cfg_brp = 2; cfg_tseg1 = 6; cfg_tseg2 = 3; cfg_sjw = 2;               // even settings
    cfg_dbrp = 1; cfg_dtseg1 = 4; cfg_dtseg2 = 2; cfg_dsjw = 2;
    reset_all();
    a_send(rnd_xl(20)); b_send(rnd_cc()); wait_ready(1, 1);
    cfg_brp = 63; cfg_tseg1 = 15; cfg_tseg2 = 7; cfg_sjw = 3;             // the longest bits
    cfg_dbrp = 63; cfg_dtseg1 = 15; cfg_dtseg2 = 7; cfg_dsjw = 3;
    reset_all();
    a_send(rnd_xl(2)); b_send(mk_cc(29'h15, 0, 0, 1)); wait_ready(1, 1);
    hb = 4.985;                                                            // B faster than A
    cfg_brp = 1; cfg_tseg1 = 5; cfg_tseg2 = 2; cfg_sjw = 1;
    cfg_dbrp = 0; cfg_dtseg1 = 3; cfg_dtseg2 = 1; cfg_dsjw = 0;
    reset_all();
    for (int i = 0; i < 6; i++) begin
      if (i % 2) a_send(rnd_xl(MAXB)); else b_send(rnd_xl(MAXB));
      wait_ready(1, 1);
    end

    // 13. reset in the middle of frames
    $display("[%0t] section 13: reset", $time);
    chk_on = 0;
    a_send(mk_xl(11'h6, 40));
    @(negedge a_txd); bits(30);
    rst_b = 0; bits(2); rst_b = 1;
    wait_ready(1, 0);
    b_send(mk_xl(11'h7, 40));
    @(negedge b_txd); bits(40);
    rst_a = 0; rst_b = 0; ca(3);
    rst_a = 1; rst_b = 1;
    idle(12);
    chk_on = 1;
    a_send(rnd_xl(10)); wait_ready(1, 0);
    b_send(rnd_cc()); wait_ready(0, 1);

    idle(3);
    $display("monitor: %0d valid frames (%0d XL), %0d broken, %0d protocol exceptions; A tx %0d rx %0d, B tx %0d rx %0d",
             mon_n, mon_xl, mon_bad, mon_pexc, a_txn, a_rxn, b_txn, b_rxn);
    if (errors == 0) $display("TEST PASSED: CAN_XL");
    else $display("TEST FAILED: CAN_XL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #200ms;
    $display("TEST FAILED: CAN_XL (timeout)");
    $finish;
  end
endmodule
