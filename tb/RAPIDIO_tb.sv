// SPDX-License-Identifier: Apache-2.0
// Self-checking TB of RAPIDIO_top. Packets are built here (content, early
// CRC after octet 80, final CRC, pad) with random ackIDs; a golden model
// executes every request against its own copy of the memory and CSRs and
// builds the response packet it expects. Every transmitted packet is
// compared octet by octet, every rx report, doorbell and outbound doorbell
// completion is checked, and the memory is read back through the host port.
// Covered: NREAD for every rdsize / wdptr, NWRITE / NWRITE_R for every
// wrsize / wdptr (short payloads too), SWRITE, both transport sizes,
// maintenance reads of every register and writes of the base ID, lock and
// tag, doorbells in and out, every error (CRC, early CRC, length, structure,
// destination, hop count, unsupported, request errors, busy drops,
// unexpected responses), host collisions and reset.
`timescale 1ns/1ps
module RAPIDIO_tb;
  logic        clk = 0, rst_n = 0;
  logic        rx_valid = 0, rx_last = 0;
  logic [7:0]  rx_data = 0;
  wire         tx_valid, tx_last;
  wire  [7:0]  tx_data;
  logic [31:0] cfg_dev_id_car = 32'h0001_0074, cfg_dev_info_car = 32'h0000_0010, cfg_asm_id_car = 32'h1234_5678,
               cfg_asm_info_car = 32'h0100_0000, cfg_pe_feat_car = 32'h8000_0011;
  logic [23:0] cfg_base_id = 24'h12_3456;
  logic        id_load = 0;
  wire  [23:0] base_id;
  logic        host_rd = 0, host_wr = 0;
  logic [9:0]  host_addr = 0;
  logic [7:0]  host_wdata = 0;
  wire  [7:0]  host_rdata;
  logic        ob_start = 0, ob_tt = 0;
  logic [15:0] ob_dest = 0, ob_info = 0;
  logic [7:0]  ob_tid = 0;
  wire         ob_busy, ob_done, db_valid, rx_rep, busy;
  wire  [3:0]  ob_status, rx_ftype;
  wire  [15:0] db_src, db_info;
  wire  [7:0]  db_tid;
  wire  [2:0]  rx_why;
  RAPIDIO_top dut (.*);
  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic cyc(input int n); repeat (n) @(negedge clk); endtask

  // ---------------- golden state ----------------
  logic [7:0]  gm [0:1023];
  logic [23:0] g_id;
  logic [15:0] g_lock;
  logic [31:0] g_tag;
  task automatic h_wr(input logic [9:0] a, input logic [7:0] d);
    @(negedge clk) host_wr = 1; host_addr = a; host_wdata = d;
    @(negedge clk) host_wr = 0;
    gm[a] = d;
  endtask
  task automatic h_rd_exp(input logic [9:0] a);
    @(negedge clk) host_rd = 1; host_addr = a;
    @(negedge clk) host_rd = 0;
    if (host_rdata !== gm[a]) fail($sformatf("host read %h = %h, expected %h", a, host_rdata, gm[a]));
  endtask
  task automatic mem_check(input int a, input int n);
    for (int i = 0; i < n; i++) h_rd_exp(10'(a + i));
  endtask

  // ---------------- packets ----------------
  function automatic logic [15:0] crc_upd(input logic [15:0] c, input logic [7:0] d);
    for (int i = 7; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h1021 : 16'h0);
    return c;
  endfunction
  logic [7:0] ct [0:1023];              // content being built
  int         cn;
  logic [7:0] pk [0:1023];              // packet with CRCs and pad
  int         pn;
  task automatic c_put(input logic [7:0] b); ct[cn] = b; cn++; endtask
  // physical + transport header
  task automatic c_hdr(input logic [1:0] prio, input logic [1:0] tt, input logic [3:0] ft,
                       input logic [15:0] dst, input logic [15:0] src);
    cn = 0;
    c_put(8'($urandom)); c_put({prio, tt, ft});
    if (tt == 2'd1) begin c_put(dst[15:8]); c_put(dst[7:0]); c_put(src[15:8]); c_put(src[7:0]); end
    else begin c_put(dst[7:0]); c_put(src[7:0]); end
  endtask
  // CRCs and pad; bad: 1 final CRC wrong, 2 early CRC wrong (final consistent), 3 drop the pad
  task automatic finish(input int bad = 0);
    logic [15:0] c;
    pn = 0; c = 16'hFFFF;
    for (int i = 0; i < cn; i++) begin
      if (i == 80) begin
        logic [15:0] e;
        e = c ^ (bad == 2 ? 16'h0100 : 16'h0);
        pk[pn] = e[15:8]; pk[pn + 1] = e[7:0]; pn += 2;
        c = crc_upd(c, e[15:8]); c = crc_upd(c, e[7:0]);
      end
      pk[pn] = ct[i]; pn++;
      c = crc_upd(c, i == 0 ? {6'd0, ct[0][1:0]} : ct[i]);
    end
    c = c ^ (bad == 1 ? 16'h0001 : 16'h0);
    pk[pn] = c[15:8]; pk[pn + 1] = c[7:0]; pn += 2;
    if (pn % 4 != 0 && bad != 3) begin pk[pn] = 0; pk[pn + 1] = 0; pn += 2; end
  endtask
  task automatic drive;
    for (int i = 0; i < pn; i++) begin
      @(negedge clk) rx_valid = 1; rx_data = pk[i]; rx_last = i == pn - 1;
    end
    @(negedge clk) rx_valid = 0; rx_last = 0; rx_data = $urandom;
  endtask

  // ---------------- monitors ----------------
  logic [7:0] tp [0:1023];
  int         tpn = 0, n_tx = 0;
  logic [7:0] tq [0:1023];              // the last complete tx packet
  int         tqn = 0;
  always @(negedge clk) if (rst_n) begin
    if (tx_valid) begin
      if (tpn < 1024) tp[tpn] = tx_data; tpn++;
      if (tx_last) begin
        for (int i = 0; i < tpn && i < 1024; i++) tq[i] = tp[i];
        tqn = tpn; tpn = 0; n_tx++;
      end
    end
    if (tx_last && !tx_valid) fail("tx_last without tx_valid");
  end
  int         n_rep = 0, n_db = 0, n_ob = 0;
  logic [2:0] l_why;
  logic [3:0] l_ft, l_obs;
  logic [15:0] l_dbs, l_dbi;
  logic [7:0] l_dbt;
  always @(negedge clk) if (rst_n) begin
    if (rx_rep) begin n_rep++; l_why = rx_why; l_ft = rx_ftype; end
    if (db_valid) begin n_db++; l_dbs = db_src; l_dbi = db_info; l_dbt = db_tid; end
    if (ob_done) begin n_ob++; l_obs = ob_status; end
  end

  // ---------------- golden execution ----------------
  // size table: octets and the first lane, 0 octets for a reserved size
  task automatic g_size(input logic [3:0] s, input bit w, input bit wr, output int n, output int lane);
    lane = 0;
    case (s)
      0: begin n = 1; lane = w ? 4 : 0; end
      1: begin n = 1; lane = w ? 5 : 1; end
      2: begin n = 1; lane = w ? 6 : 2; end
      3: begin n = 1; lane = w ? 7 : 3; end
      4: begin n = 2; lane = w ? 4 : 0; end
      5: begin n = 3; lane = w ? 5 : 0; end
      6: begin n = 2; lane = w ? 6 : 2; end
      7: begin n = 5; lane = w ? 3 : 0; end
      8: begin n = 4; lane = w ? 4 : 0; end
      9: begin n = 6; lane = w ? 2 : 0; end
      10: begin n = 7; lane = w ? 1 : 0; end
      11: n = w ? 16 : 8;
      12: n = w ? 64 : 32;
      13: n = w ? 128 : (wr ? 0 : 96);
      14: n = wr ? 0 : (w ? 192 : 160);
      default: n = w ? 256 : (wr ? 0 : 224);
    endcase
  endtask
  // expected outcome of the packet in ct / cn
  int          x_why;
  logic [7:0]  xr [0:1023];            // expected response content (xn = 0: none)
  int          xn;
  bit          x_db;
  task automatic x_resp(input logic [3:0] ft, input logic [3:0] tty, input logic [3:0] st, input int tid);
    logic [1:0] pr, tt;
    tt = ct[1][5:4]; pr = ct[1][7:6] == 3 ? 3 : ct[1][7:6] + 1;
    xn = 0;
    xr[0] = 0; xr[1] = {pr, tt, ft}; xn = 2;
    if (tt == 1) begin
      xr[2] = ct[4]; xr[3] = ct[5]; xr[4] = g_id[15:8]; xr[5] = g_id[7:0]; xn = 6;
    end else begin xr[2] = ct[3]; xr[3] = g_id[23:16]; xn = 4; end
    xr[xn] = {tty, st}; xr[xn + 1] = 8'(tid); xn += 2;
    if (ft == 8) begin xr[xn] = 8'hFF; xr[xn + 1] = 0; xr[xn + 2] = 0; xr[xn + 3] = 0; xn += 4; end
  endtask
  function automatic logic [31:0] g_csr(input int a);
    case (a)
      'h00: return cfg_dev_id_car;
      'h04: return cfg_dev_info_car;
      'h08: return cfg_asm_id_car;
      'h0C: return cfg_asm_info_car;
      'h10: return cfg_pe_feat_car;
      'h60: return {8'd0, g_id};
      'h68: return {16'd0, g_lock};
      'h6C: return g_tag;
      default: return 0;
    endcase
  endfunction
  bit          g_obp;                   // our doorbell outstanding: tt, dest, tid
  logic [15:0] g_obd;
  logic [7:0]  g_obt;
  bit          g_obtt;
  task automatic golden;
    int o, lh, pl, tid, n, lane, beg, cnt, ftype, ttype, size;
    bit tt1, w;
    logic [15:0] dst, src, my;
    logic [31:0] a;
    tt1 = ct[1][4]; ftype = ct[1][3:0];
    o = tt1 ? 6 : 4;
    dst = tt1 ? {ct[2], ct[3]} : {8'd0, ct[2]};
    src = tt1 ? {ct[4], ct[5]} : {8'd0, ct[3]};
    my = tt1 ? g_id[15:0] : {8'd0, g_id[23:16]};
    ttype = ct[o][7:4]; size = ct[o][3:0]; tid = ct[o + 1];
    lh = (ftype == 2 || ftype == 5 || ftype == 8) ? 6 : (ftype == 6 || ftype == 10) ? 4 : 2;
    pl = cn - o - lh;
    xn = 0; x_db = 0; x_why = 0;
    a = {ct[o + 2], ct[o + 3], ct[o + 4], ct[o + 5]};
    if (ftype == 13) begin
      if (dst != my) x_why = 2;
      else if (g_obp && ttype == 0 && tid == g_obt && src == g_obd && tt1 == g_obtt) begin x_why = 0; g_obp = 0; end
      else x_why = 7;
    end else if (dst != my || (ftype == 8 && ct[o + 2] != 0)) x_why = 2;
    else if (ftype == 10) begin x_db = 1; x_resp(13, 0, 0, tid); end
    else if (ftype == 8) begin
      int off;
      logic [31:0] v;
      off = {ct[o + 3], ct[o + 4], ct[o + 5][7:3], 3'b000} + (ct[o + 5][2] ? 4 : 0);
      w = ct[o + 5][2];
      if (ttype == 2 || ttype == 3) x_why = 7;
      else if (ttype >= 4) begin x_why = 4; x_resp(8, 2, 7, tid); end
      else if (size != 8) begin x_why = 5; x_resp(8, ttype == 1 ? 3 : 2, 7, tid); end
      else if (ttype == 0) begin
        v = g_csr(off);
        x_resp(8, 2, 0, tid);
        for (int i = 0; i < 8; i++) xr[xn + i] = 0;
        for (int i = 0; i < 4; i++) xr[xn + (w ? 4 : 0) + i] = v[31 - 8 * i -: 8];
        xn += 8;
      end else begin
        x_resp(8, 3, 0, tid);                                  // from the ID it was sent to
        for (int i = 0; i < 4; i++) v[31 - 8 * i -: 8] = ct[o + lh + (w ? 4 : 0) + i];
        if (off == 'h60) g_id = v[23:0];
        if (off == 'h68) begin
          if (g_lock == 16'hFFFF) g_lock = v[15:0];
          else if (g_lock == v[15:0]) g_lock = 16'hFFFF;
        end
        if (off == 'h6C) g_tag = v;
      end
    end else if (!(ftype == 2 && ttype == 4 || ftype == 5 && (ttype == 4 || ttype == 5) || ftype == 6)) begin
      x_why = 4;
      if (ftype == 2 || ftype == 5) x_resp(13, 0, 7, tid);
    end else begin
      bit err, sub;
      w = a[2];
      sub = ftype != 6 && size <= 10;
      if (ftype == 6) begin
        a = {ct[o], ct[o + 1], ct[o + 2], ct[o + 3]};             // SWRITE: the address comes first
        beg = {a[31:3], 3'b000}; cnt = pl; lane = 0; err = a[1:0] != 0;
      end
      else begin
        g_size(4'(size), w, ftype == 5, n, lane);
        err = n == 0 || a[1:0] != 0;
        if (ftype == 2) begin beg = {a[31:3], 3'b000}; cnt = sub ? 8 : n; end
        else if (sub) begin beg = {a[31:3], 3'b000} + lane; cnt = n; err = err || pl != 8; end
        else begin beg = {a[31:3], 3'b000}; cnt = pl; err = err || pl > n; end
      end
      err = err || {1'b0, a[31:3], 3'b000} + (sub && ftype == 5 ? lane : 0) + cnt > 1024 || beg >= 1024;
      if (err) begin
        x_why = 5;
        if (ftype == 2 || ftype == 5 && ttype == 5) x_resp(13, 0, 7, tid);
      end else if (ftype == 2) begin
        x_resp(13, 8, 0, tid);
        for (int i = 0; i < cnt; i++) xr[xn + i] = gm[beg + i];
        xn += cnt;
      end else begin
        for (int i = 0; i < cnt; i++) gm[beg + i] = ct[o + lh + (sub ? lane : 0) + i];
        if (ttype == 5 && ftype == 5) x_resp(13, 0, 0, tid);
      end
    end
  endtask

  // ---------------- checks ----------------
  // the response packet in tq must be xr / xn with CRCs and pad
  task automatic resp_check(input string what);
    logic [7:0] sv [0:1023];
    int sn;
    for (int i = 0; i < xn; i++) ct[i] = xr[i];
    cn = xn; ct[0] = 0;
    // keep the request's pk
    sn = pn; for (int i = 0; i < pn; i++) sv[i] = pk[i];
    finish();
    if (tqn != pn) fail($sformatf("%s: response of %0d octets, expected %0d", what, tqn, pn));
    else begin
      int bad;
      bad = -1;
      for (int i = 0; i < pn; i++) if (bad < 0 && tq[i] !== pk[i]) bad = i;
      if (bad >= 0) fail($sformatf("%s: response octet %0d = %h, expected %h", what, bad, tq[bad], pk[bad]));
    end
    pn = sn; for (int i = 0; i < sn; i++) pk[i] = sv[i];
  endtask
  // send the packet in ct (already golden-executed or with an expected why), wait until idle
  task automatic run(input string what, input int bad = 0, input int why = -1);
    int r0, t0, d0, k;
    logic [7:0] sct [0:1023];
    int scn;
    scn = cn; for (int i = 0; i < cn; i++) sct[i] = ct[i];
    if (why < 0) golden();
    else begin x_why = why; xn = 0; x_db = 0; end
    finish(bad);
    r0 = n_rep; t0 = n_tx; d0 = n_db;
    drive();
    k = 0;
    while ((busy || tx_valid) && k < 5000) begin @(negedge clk); k++; end
    cyc(2);
    if (n_rep != r0 + 1) fail($sformatf("%s: %0d reports", what, n_rep - r0));
    else if (l_why !== 3'(x_why)) fail($sformatf("%s: why %0d, expected %0d", what, l_why, x_why));
    else if (x_why != 6 && l_ft !== sct[1][3:0]) fail($sformatf("%s: report ftype %0d", what, l_ft));
    if (n_db != d0 + x_db) fail($sformatf("%s: doorbell reports %0d", what, n_db - d0));
    if (x_db && (l_dbt !== sct[ct[1][4] ? 7 : 5] || l_dbi !== {sct[ct[1][4] ? 8 : 6], sct[ct[1][4] ? 9 : 7]}))
      fail($sformatf("%s: doorbell %h %h", what, l_dbt, l_dbi));
    if (xn == 0) begin if (n_tx != t0) fail($sformatf("%s: unexpected response", what)); end
    else if (n_tx != t0 + 1) fail($sformatf("%s: %0d responses", what, n_tx - t0));
    else resp_check(what);
  endtask

  // requests
  logic [15:0] me8, me16;
  task automatic rq_nread(input bit tt, input int sz, input bit w, input int dwa, input int xam = 0,
                          input int ttype = 4, input int prio = 0);
    c_hdr(2'(prio), {1'b0, tt}, 4'd2, tt ? g_id[15:0] : {8'd0, g_id[23:16]}, 16'hBEEF);
    c_put({4'(ttype), 4'(sz)}); c_put(8'($urandom));
    c_put(dwa[28:21]); c_put(dwa[20:13]); c_put(dwa[12:5]); c_put({dwa[4:0], w, 2'(xam)});
  endtask
  task automatic rq_nwrite(input bit tt, input int ttype, input int sz, input bit w, input int dwa, input int nb,
                           input int xam = 0);
    c_hdr(2'($urandom), {1'b0, tt}, 4'd5, tt ? g_id[15:0] : {8'd0, g_id[23:16]}, 16'h0A0B);
    c_put({4'(ttype), 4'(sz)}); c_put(8'($urandom));
    c_put(dwa[28:21]); c_put(dwa[20:13]); c_put(dwa[12:5]); c_put({dwa[4:0], w, 2'(xam)});
    for (int i = 0; i < nb; i++) c_put(8'($urandom));
  endtask
  task automatic rq_swrite(input bit tt, input int dwa, input int nb, input int xam = 0);
    c_hdr(2'd1, {1'b0, tt}, 4'd6, tt ? g_id[15:0] : {8'd0, g_id[23:16]}, 16'h0C0D);
    c_put(dwa[28:21]); c_put(dwa[20:13]); c_put(dwa[12:5]); c_put({dwa[4:0], 1'b0, 2'(xam)});
    for (int i = 0; i < nb; i++) c_put(8'($urandom));
  endtask
  task automatic rq_maint(input bit tt, input int ttype, input int sz, input int off, input int hop = 0,
                          input logic [31:0] v = 0);
    c_hdr(2'd2, {1'b0, tt}, 4'd8, tt ? g_id[15:0] : {8'd0, g_id[23:16]}, 16'h0E0F);
    c_put({4'(ttype), 4'(sz)}); c_put(8'($urandom)); c_put(8'(hop));
    c_put(off[23:16]); c_put(off[15:8]); c_put({off[7:3], off[2], 2'b00});
    if (ttype == 1 || ttype == 2) for (int i = 0; i < 8; i++) c_put((i < 4) == !off[2] ? v[31 - 8 * (i % 4) -: 8] : 8'($urandom));
  endtask
  task automatic rq_db(input bit tt, input logic [15:0] info, input logic [15:0] src = 16'h5150,
                       input int tid = -1);
    c_hdr(2'd0, {1'b0, tt}, 4'd10, tt ? g_id[15:0] : {8'd0, g_id[23:16]}, src);
    c_put(8'h00); c_put(tid < 0 ? 8'($urandom) : 8'(tid)); c_put(info[15:8]); c_put(info[7:0]);
  endtask

  // outbound doorbell: send, check the packet
  task automatic ob_send(input bit tt, input logic [15:0] dst, input logic [7:0] tid, input logic [15:0] info);
    int t0, k;
    t0 = n_tx;
    @(negedge clk) ob_start = 1; ob_tt = tt; ob_dest = dst; ob_tid = tid; ob_info = info;
    @(negedge clk) ob_start = 0; ob_dest = $urandom; ob_tid = $urandom; ob_info = $urandom;
    if (!ob_busy) fail("ob_busy not set");
    k = 0;
    while (n_tx == t0 && k < 1000) begin @(negedge clk); k++; end
    cyc(2);
    c_hdr(0, {1'b0, tt}, 4'd10, dst, tt ? g_id[15:0] : {8'd0, g_id[23:16]});
    c_put(0); c_put(tid); c_put(info[15:8]); c_put(info[7:0]);
    for (int i = 0; i < cn; i++) xr[i] = ct[i];
    xn = cn;
    resp_check("outbound doorbell");
    g_obp = 1; g_obd = tt ? dst : {8'd0, dst[7:0]}; g_obt = tid; g_obtt = tt;
  endtask
  task automatic rsp_in(input bit tt, input logic [15:0] src, input int tty, input int st, input logic [7:0] tid,
                        input int npl = 0);
    c_hdr(2'd1, {1'b0, tt}, 4'd13, tt ? g_id[15:0] : {8'd0, g_id[23:16]}, src);
    c_put({4'(tty), 4'(st)}); c_put(tid);
    for (int i = 0; i < npl; i++) c_put(8'($urandom));
  endtask

  // ---------------- scenarios ----------------
  initial begin
    for (int i = 0; i < 1024; i++) gm[i] = 0;
    g_lock = 16'hFFFF; g_tag = 0; g_id = 0; g_obp = 0;
    cyc(3); rst_n = 1; cyc(2);
    if (base_id !== 0) fail("base ID after reset");
    @(negedge clk) id_load = 1;
    @(negedge clk) id_load = 0; g_id = cfg_base_id; cfg_base_id = $urandom;
    if (base_id !== g_id) fail("id_load");
    for (int i = 0; i < 1024; i++) h_wr(10'(i), 8'($urandom));
    mem_check(0, 16);

    // 1. NREAD: every size / wdptr, both transport sizes, priorities
    $display("[%0t] 1. NREAD", $time);
    for (int s = 0; s < 16; s++)
      for (int w = 0; w < 2; w++) begin
        rq_nread(s[0] ^ w[0], s, w[0], 3 + s, 0, 4, s % 4);
        run($sformatf("NREAD size %0d wdptr %0d", s, w));
      end
    rq_nread(0, 15, 1, 96); run("NREAD 256 at the top");             // 0x300..0x3FF
    rq_nread(1, 15, 1, 97); run("NREAD past the top");
    rq_nread(0, 8, 0, 127); run("NREAD last double-word");
    rq_nread(0, 8, 0, 128); run("NREAD outside");
    rq_nread(0, 8, 0, 2, 1); run("NREAD xamsbs");
    rq_nread(1, 8, 0, 2, 2); run("NREAD xamsbs 2");
    rq_nread(0, 8, 0, 2, 0, 12); run("NREAD unsupported ttype (atomic)");

    // 2. NWRITE / NWRITE_R: every size / wdptr, short payloads, errors
    $display("[%0t] 2. NWRITE", $time);
    for (int s = 0; s < 16; s++)
      for (int w = 0; w < 2; w++) begin
        int n, l;
        g_size(4'(s), w[0], 1, n, l);
        rq_nwrite(w[0], 5 - (s % 2), s, w[0], 8 + 2 * s, s <= 10 ? 8 : n == 0 ? 8 : n);
        run($sformatf("NWRITE size %0d wdptr %0d", s, w));
      end
    rq_nwrite(0, 5, 12, 1, 20, 24); run("NWRITE_R shorter than the size");
    rq_nwrite(1, 5, 11, 0, 20, 16); run("NWRITE_R longer than the size");
    rq_nwrite(0, 5, 3, 0, 20, 16); run("NWRITE_R lanes with 16 octets");
    rq_nwrite(0, 4, 15, 1, 100, 256); run("NWRITE past the top");
    rq_nwrite(0, 5, 8, 0, 6, 8, 3); run("NWRITE_R xamsbs");
    rq_nwrite(1, 14, 8, 0, 6, 8); run("NWRITE unsupported ttype");
    rq_nwrite(1, 5, 15, 1, 0, 256); run("NWRITE_R 256");
    mem_check(0, 256);

    // 3. SWRITE
    $display("[%0t] 3. SWRITE", $time);
    rq_swrite(0, 40, 8); run("SWRITE 8");
    rq_swrite(1, 50, 256); run("SWRITE 256");
    rq_swrite(0, 127, 8); run("SWRITE last double-word");
    rq_swrite(0, 127, 16); run("SWRITE past the top");
    rq_swrite(0, 2, 8, 1); run("SWRITE xamsbs");
    mem_check(320, 64); mem_check(1016, 8);

    // 4. maintenance
    $display("[%0t] 4. maintenance", $time);
    for (int i = 0; i < 27; i++) begin
      int off;
      if (i % 9 == 0) begin                                        // CARs A, ~A, A: every bit both ways
        cfg_dev_id_car = ~cfg_dev_id_car; cfg_dev_info_car = ~cfg_dev_info_car;
        cfg_asm_id_car = ~cfg_asm_id_car; cfg_asm_info_car = ~cfg_asm_info_car;
        cfg_pe_feat_car = ~cfg_pe_feat_car; cfg_base_id = ~cfg_base_id;
      end
      off = i % 9 < 5 ? 4 * (i % 9) : i % 9 == 5 ? 'h60 : i % 9 == 6 ? 'h68 : i % 9 == 7 ? 'h6C : 'h1004;
      rq_maint(i[0], 0, 8, off); run($sformatf("maintenance read %h", off));
    end
    rq_maint(0, 1, 8, 'h6C, 0, 32'hCAFE_F00D); run("write the component tag");
    rq_maint(1, 0, 8, 'h6C); run("read the component tag");
    rq_maint(0, 1, 8, 'h6C, 0, 32'h3501_0FF2); run("write the inverted tag");
    rq_maint(1, 0, 8, 'h6C); run("read the inverted tag");
    rq_maint(0, 1, 8, 'h6C, 0, 32'h0); run("clear the tag");
    rq_maint(1, 0, 8, 'h6C); run("read the cleared tag");
    rq_maint(0, 1, 8, 'h68, 0, 32'h0000_0042); run("take the lock");
    rq_maint(0, 1, 8, 'h68, 0, 32'h0000_0043); run("lock held by another");
    rq_maint(0, 0, 8, 'h68); run("read the lock");
    rq_maint(1, 1, 8, 'h68, 0, 32'h0000_0042); run("release the lock");
    rq_maint(0, 0, 8, 'h68); run("read the lock again");
    rq_maint(1, 1, 8, 'h68, 0, 32'h0000_0001); run("take the lock as ID 1");
    rq_maint(0, 1, 8, 'h68, 0, 32'h0000_0001); run("release the lock as ID 1");
    rq_maint(0, 1, 8, 'h40, 0, 32'h1234_5678); run("write an unknown offset");
    rq_maint(0, 0, 4, 'h00); run("maintenance read size 2");
    rq_maint(1, 1, 11, 'h60, 0, 0); run("maintenance write size 8");
    rq_maint(0, 5, 8, 'h00); run("maintenance ttype 5");
    rq_maint(1, 4, 8, 'h00); run("maintenance ttype 4");
    rq_maint(0, 0, 8, 'h00, 3); run("hop count 3");
    rq_maint(0, 2, 8, 'h00, 0, 32'h1); run("maintenance read response");
    rq_maint(1, 3, 8, 'h00); run("maintenance write response");
    rq_maint(0, 1, 8, 'h60, 0, 32'h00FF_FFFF); run("base device ID all ones");
    rq_maint(1, 0, 8, 'h60); run("read the all-ones base ID");
    rq_maint(0, 1, 8, 'h60, 0, 32'h00AB_CDEF); run("new base device ID");
    begin                                                            // id_load in the clock of the CSR write
      rq_maint(0, 1, 8, 'h60, 0, 32'h0012_3456); golden(); finish();
      cfg_base_id = 24'h65_4321;
      fork
        drive();
        begin
          @(posedge rx_last); @(negedge clk) id_load = 1;
          @(negedge clk) id_load = 0;
        end
      join
      while (busy || tx_valid) @(negedge clk);
      cyc(2);
      if (base_id !== 24'h12_3456) fail("the CSR write loses to id_load");
      resp_check("CSR write with id_load");
      rq_maint(0, 1, 8, 'h60, 0, 32'h00AB_CDEF); run("base device ID back");
    end
    if (base_id !== 24'hAB_CDEF) fail("base_id output");
    rq_nread(0, 8, 0, 4); run("NREAD to the new 8-bit ID");
    rq_nread(1, 8, 1, 4); run("NREAD to the new 16-bit ID");

    // 5. doorbells in and out, responses
    $display("[%0t] 5. doorbells", $time);
    rq_db(0, 16'h1234); run("doorbell in");
    rq_db(1, 16'hEDCB); run("doorbell in, tt 1");
    rq_db(1, 16'hFFFF, 16'hFFFF, 8'hFF); run("doorbell in, all ones");
    rq_db(1, 16'h0000, 16'h0000, 8'h00); run("doorbell in, all zeros");
    ob_send(0, 16'h0077, 8'h5A, 16'hA5A5);
    rsp_in(0, 16'h0076, 0, 0, 8'h5A); run("response from another ID");
    rsp_in(0, 16'h0077, 0, 0, 8'h5B); run("response with another TID");
    rsp_in(1, 16'h0077, 0, 0, 8'h5A); run("response with another tt");
    rsp_in(0, 16'h0077, 8, 0, 8'h5A, 8); run("response with data");
    if (!ob_busy) fail("ob_busy dropped");
    rsp_in(0, 16'h0077, 0, 7, 8'h5A); run("doorbell ERROR response");
    if (ob_busy || n_ob != 1 || l_obs !== 4'd7) fail("outbound doorbell completion");
    ob_send(1, 16'hF00D, 8'hC3, 16'h0001);
    @(negedge clk) ob_start = 1; ob_tt = 0;
    @(negedge clk) ob_start = 0;                                   // ignored while busy
    cyc(40);
    if (n_tx != 0 && tx_valid) fail("second doorbell sent");
    rsp_in(1, 16'hF00D, 0, 0, 8'hC3); run("doorbell DONE response");
    if (ob_busy || n_ob != 2 || l_obs !== 4'd0) fail("outbound doorbell completion 2");
    ob_send(1, 16'hFFFF, 8'hFF, 16'hFFFF);
    rsp_in(1, 16'hFFFF, 0, 15, 8'hFF); run("doorbell user status response");
    if (ob_busy || n_ob != 3 || l_obs !== 4'hF) fail("outbound doorbell completion 3");
    ob_send(1, 16'h0000, 8'h00, 16'h0000);
    rsp_in(1, 16'h0000, 0, 0, 8'h00); run("doorbell response from ID 0");
    if (ob_busy || n_ob != 4 || l_obs !== 4'd0) fail("outbound doorbell completion 4");
    rsp_in(0, 16'h0077, 0, 0, 8'h5A); run("response with nothing outstanding");
    c_hdr(0, 0, 4'd13, 16'h0042, 16'h0077); c_put(0); c_put(0); run("response to another ID");

    // 6. errors
    $display("[%0t] 6. errors", $time);
    rq_nread(0, 8, 0, 4); run("final CRC wrong", 1, 1);
    rq_nwrite(0, 5, 15, 1, 0, 128); run("early CRC wrong", 2, 1);
    rq_nwrite(0, 5, 15, 1, 0, 128); run("final CRC wrong (long)", 1, 1);
    rq_nread(1, 8, 0, 4); run("pad missing", 3, 3);
    begin                                                            // a one-octet packet
      int r0;
      r0 = n_rep; pk[0] = 8'hA5; pn = 1; drive(); cyc(4);
      if (n_rep != r0 + 1 || l_why !== 3'd3) fail("one-octet packet");
    end
    rq_nread(0, 8, 0, 4); c_put(0); c_put(0); c_put(0); c_put(0); c_put(0); c_put(0); c_put(0); c_put(0);
    run("NREAD with a payload", 0, 3);
    rq_nwrite(0, 4, 11, 0, 4, 4); run("payload not a double-word multiple", 0, 3);
    rq_nread(0, 8, 0, 4); ct[1][5:4] = 2'd2; run("tt 2", 0, 3);
    rq_nwrite(0, 4, 15, 1, 0, 256); for (int i = 0; i < 260; i++) c_put(0); run("too long", 0, 3);
    cn = 3; ct[0] = 0; ct[1] = 8'h02; ct[2] = 0; run("3 octets", 0, 3);
    // content of 82 octets: total 84, never valid
    rq_swrite(0, 10, 72); cn = 82; run("84 octets", 0, 3);
    rq_nread(0, 8, 0, 4); ct[2] = ct[2] + 1; run("another destination");
    rq_nread(1, 8, 0, 4); ct[3] = ct[3] ^ 8'h80; run("another 16-bit destination");
    c_hdr(0, 0, 4'd11, {8'd0, g_id[23:16]}, 16'h0001); c_put(0); c_put(0); run("message (ftype 11)");
    c_hdr(0, 1, 4'd0, g_id[15:0], 16'h0001); c_put(0); c_put(0); run("ftype 0");

    // 7. busy: a packet while a response goes out, and while our doorbell goes out
    $display("[%0t] 7. busy", $time);
    begin
      int r0, t0;
      rq_nread(0, 15, 1, 0); golden(); finish();
      r0 = n_rep; t0 = n_tx;
      drive();
      rq_db(0, 16'h7777); finish();
      while (!tx_valid) @(negedge clk);
      drive();                                                       // dropped
      while (busy || tx_valid) @(negedge clk);
      cyc(2);
      if (n_rep != r0 + 2 || l_why !== 3'd6) fail("packet while busy");
      resp_check("read before the dropped packet");
      // a long packet still being dropped after the engine is idle again
      rq_nread(0, 8, 0, 4); golden(); finish();
      r0 = n_rep;
      drive();
      rq_swrite(0, 0, 256); finish();
      while (!tx_valid) @(negedge clk);
      drive();                                                       // dropped, to its last octet
      while (busy || tx_valid) @(negedge clk);
      cyc(2);
      if (n_rep != r0 + 2 || l_why !== 3'd6) fail("long packet while busy");
      resp_check("read before the long dropped packet");
      // a one-octet packet right after a request's last octet (dropped while that one is checked)
      rq_nread(0, 8, 0, 4); golden(); finish();
      r0 = n_rep;
      for (int i = 0; i <= pn; i++) begin
        @(negedge clk) rx_valid = 1; rx_data = i < pn ? pk[i] : 8'hA5; rx_last = i >= pn - 1;
      end
      @(negedge clk) rx_valid = 0; rx_last = 0;
      while (busy || tx_valid) @(negedge clk);
      cyc(2);
      if (n_rep != r0 + 2 || l_why !== 3'd6) fail("one-octet packet after a request");
      resp_check("read before the one-octet packet");
      ob_send(0, 16'h0011, 8'h01, 16'h0);
      rq_db(0, 16'h1); finish();
      r0 = n_rep;
      @(negedge clk) ob_start = 1; ob_tt = 0; ob_dest = 16'h0011; ob_tid = 8'h02;
      @(negedge clk) ob_start = 0;                                   // ob_busy: ignored
      cyc(2);
      rsp_in(0, 16'h0011, 0, 0, 8'h01); run("ob response");
    end
    begin
      // a doorbell going out while a packet arrives: the packet is dropped
      int r0;
      rq_db(0, 16'h2); finish();
      r0 = n_rep;
      fork
        begin @(negedge clk); drive(); end                           // one clock after ob_start
        begin
          @(negedge clk) ob_start = 1; ob_tt = 0; ob_dest = 16'h0021; ob_tid = 8'h03; ob_info = 16'h0;
          @(negedge clk) ob_start = 0;
        end
      join
      while (busy || tx_valid || rx_valid) @(negedge clk);
      cyc(2);
      if (n_rep != r0 + 1 || l_why !== 3'd6) fail("packet while our doorbell goes out");
      g_obp = 1; g_obd = 16'h0021; g_obt = 8'h03; g_obtt = 0;
      rsp_in(0, 16'h0021, 0, 0, 8'h03); run("ob response 2");
    end

    // 8. host write collision
    $display("[%0t] 8. host collision", $time);
    begin
      logic [7:0] keep;
      rq_swrite(0, 60, 8); golden(); finish();
      keep = gm[484];
      fork
        drive();
        begin
          while (!(dut.e_we && dut.e_wa == 10'd484)) @(negedge clk);
          host_wr = 1; host_addr = 10'd484; host_wdata = ~keep;
          @(negedge clk) host_wr = 0;
          host_wr = 1; host_addr = 10'd0; host_wdata = 8'h99;            // next clock: lands
          @(negedge clk) host_wr = 0;
        end
      join
      gm[0] = 8'h99;
      while (busy) @(negedge clk);
      cyc(2);
      mem_check(480, 8); h_rd_exp(0);
    end

    // 9. reset in the middle of a response, then of a received packet
    $display("[%0t] 9. reset", $time);
    rq_nread(0, 15, 1, 0); finish();
    drive();
    while (!tx_valid) @(negedge clk);
    cyc(30);
    rst_n = 0; cyc(3);
    if (tx_valid || busy || rx_rep || ob_busy || base_id !== 0) fail("reset values");
    tpn = 0;                                                         // the cut response
    rst_n = 1; cyc(3);
    g_id = 0; g_lock = 16'hFFFF; g_tag = 0; g_obp = 0;
    rq_swrite(0, 0, 256); finish();                                  // long: reset lands inside it
    fork
      drive();
      begin cyc(100); rst_n = 0; end
    join
    cyc(3);
    if (tx_valid || busy || rx_rep) fail("reset values in a packet");
    if (tpn != 0) fail($sformatf("%0d octets sent for a cut packet", tpn));
    rst_n = 1; cyc(3);
    rq_nread(0, 8, 0, 4); run("after reset (ID 0)");
    rq_maint(0, 0, 8, 'h68); run("lock after reset");

    $display("RAPIDIO: %0d reports, %0d packets sent", n_rep, n_tx);
    if (errors == 0) $display("TEST PASSED: RAPIDIO");
    else $display("TEST FAILED: RAPIDIO (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50ms;
    $display("TEST FAILED: RAPIDIO (timeout)");
    $finish;
  end
endmodule
