// SPDX-License-Identifier: Apache-2.0
// RapidIO endpoint: concurrent SVA against an independent, cycle-level
// reference model, plus functional coverage.
//  * The model keeps the received octets of each packet itself, finds the
//    content length from the packet length (pad or not, early CRC or not),
//    checks both CRCs by recomputing them, checks the structure and
//    executes the request on its own copy of the memory and the CSRs. A
//    packet that arrives while the model is checking, writing or sending is
//    dropped and reported the clock after its last octet.
//  * Its transmitter builds every packet the endpoint must send (responses,
//    our doorbell) from the content, inserts the early CRC, the final CRC
//    and the pad, and reads memory payload octets in the clock they go out.
//    tx_valid / tx_data / tx_last, busy, the reports, the doorbell outputs,
//    base_id and host_rdata are compared with the model on every clock.
`include "cov_macros.svh"
module RAPIDIO_sva (
  input  logic        clk, rst_n,
  input  logic        rx_valid,
  input  logic [7:0]  rx_data,
  input  logic        rx_last,
  input  logic        tx_valid,
  input  logic [7:0]  tx_data,
  input  logic        tx_last,
  input  logic [31:0] cfg_dev_id_car, cfg_dev_info_car, cfg_asm_id_car, cfg_asm_info_car, cfg_pe_feat_car,
  input  logic [23:0] cfg_base_id,
  input  logic        id_load,
  input  logic [23:0] base_id,
  input  logic        host_rd, host_wr,
  input  logic [9:0]  host_addr,
  input  logic [7:0]  host_wdata,
  input  logic [7:0]  host_rdata,
  input  logic        ob_start, ob_tt,
  input  logic [15:0] ob_dest,
  input  logic [7:0]  ob_tid,
  input  logic [15:0] ob_info,
  input  logic        ob_busy, ob_done,
  input  logic [3:0]  ob_status,
  input  logic        db_valid,
  input  logic [15:0] db_src,
  input  logic [7:0]  db_tid,
  input  logic [15:0] db_info,
  input  logic        rx_rep,
  input  logic [2:0]  rx_why,
  input  logic [3:0]  rx_ftype,
  input  logic        busy
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [15:0] crc_upd(input logic [15:0] c, input logic [7:0] d);
    for (int i = 7; i >= 0; i--) begin
      bit fb;
      fb = c[15] ^ d[i];
      c = {c[14:0], 1'b0};
      if (fb) c ^= 16'h1021;
    end
    return c;
  endfunction
  // RapidIO rdsize / wrsize: octets, first lane, 0 octets for a reserved size
  task automatic size_of(input logic [3:0] s, input bit w, input bit wr, output int n, output int lane);
    lane = 0;
    if (s <= 3) begin n = 1; lane = 4 * w + s; end
    else case (s)
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

  // ---------------- model state ----------------
  typedef enum int {M_IDLE, M_RX, M_CHK, M_WR, M_TX} ms_t;
  ms_t         ms;
  bit          skip, drop_pend;
  logic [7:0]  pk [0:1023];                          // the packet being received
  int          pn;
  logic [7:0]  mm [0:1023];                          // memory
  logic [23:0] m_base;
  logic [15:0] m_lock;
  logic [31:0] m_tag;
  bit          obb, ob_tt_m;                         // our doorbell outstanding
  logic [15:0] ob_dest_m;
  logic [7:0]  ob_tid_m;
  // write in progress
  logic [7:0]  wd [0:255];
  int          wn, wi, wdst;
  bit          wresp;
  // transmitter: content octets (literal, or a memory address when tref >= 0)
  logic [7:0]  tc [0:299];
  int          tref [0:299];
  int          tlen, tk, tph, tn;
  bit          tsec;
  logic [15:0] tcrc, tsave;
  // expected outputs for this clock
  bit          x_tv, x_tl, x_busy, x_rep, x_db, x_obd;
  logic [7:0]  x_td, x_dbt, x_hr;
  logic [2:0]  x_why;
  logic [3:0]  x_ft, x_obs;
  logic [15:0] x_dbs, x_dbi;
  // coverage flags of this clock
  bit          v_nread_sub, v_nread_big, v_nwrite_sub, v_nwrite_big, v_nwrite_short, v_nwrite_r,
               v_swrite, v_mt_rd, v_mt_wr, v_lock_take, v_lock_rel, v_lock_refused, v_db_in, v_ob_tt0,
               v_ob_tt1, v_ob_ok, v_ob_other, v_early_rx, v_early_tx, v_pad_rx, v_nopad_rx, v_pad_tx,
               v_nopad_tx, v_long, v_hcol, v_drop_in_chk, v_prio_sat, v_tt1_resp, v_max_payload,
               v_mem_top, v_drop_ob, v_id_load_and_write, v_mt_unknown, v_hop, v_err_resp;
  bit   [7:0]  v_why;

  // the transmit octet for the current generator state
  task automatic t_out(output logic [7:0] d, output bit last);
    last = 0;
    case (tph)
      0: d = tref[tk] >= 0 ? mm[tref[tk]] : tc[tk];
      1, 2: d = tsec ? tsave[7:0] : tsave[15:8];
      default: d = 8'h00;
    endcase
    if (tsec && (tph == 2 && (tn + 1) % 4 == 0 || tph == 3)) last = 1;
  endtask
  // the octet d went out: advance; returns 1 after the last octet
  function automatic bit t_adv(input logic [7:0] d);
    bit done;
    done = 0;
    tn++;
    case (tph)
      0: begin
        tcrc = crc_upd(tcrc, tk == 0 ? {6'd0, d[1:0]} : d);
        tk++;
        if (tk == tlen) begin tph = 2; tsec = 0; tsave = tcrc; end
        else if (tk == 80) begin tph = 1; tsec = 0; tsave = tcrc; end
      end
      1: begin
        tcrc = crc_upd(tcrc, d);
        if (tsec) begin tph = 0; tsec = 0; end else tsec = 1;
      end
      2: if (!tsec) tsec = 1;
         else if (tn % 4 == 0) done = 1;
         else begin tph = 3; tsec = 0; end
      default: if (!tsec) tsec = 1; else done = 1;
    endcase
    return done;
  endfunction
  task automatic t_start;
    tk = 0; tph = 0; tn = 0; tsec = 0; tcrc = 16'hFFFF;
  endtask
  task automatic t_lit(input logic [7:0] d);
    tc[tlen] = d; tref[tlen] = -1; tlen++;
  endtask
  // response header to the request in ct
  task automatic t_resp(input logic [7:0] b1, input logic [15:0] src, input logic [15:0] my, input bit t1,
                        input logic [3:0] ft, input logic [3:0] tty, input logic [3:0] st, input logic [7:0] tid);
    logic [1:0] pr;
    pr = b1[7:6] == 2'd3 ? 2'd3 : b1[7:6] + 2'd1;
    tlen = 0;
    t_lit(8'h00); t_lit({pr, b1[5:4], ft});
    if (t1) begin t_lit(src[15:8]); t_lit(src[7:0]); t_lit(my[15:8]); t_lit(my[7:0]); end
    else begin t_lit(src[7:0]); t_lit(my[7:0]); end
    t_lit({tty, st}); t_lit(tid);
    if (ft == 4'd8) begin t_lit(8'hFF); t_lit(8'h00); t_lit(8'h00); t_lit(8'h00); end
    v_prio_sat |= b1[7:6] == 2'd3;
    v_tt1_resp |= t1;
  endtask

  // ---------------- the received packet ----------------
  logic [7:0]  ct [0:511];                           // content (early CRC removed)
  // CRC and length check for pad p: content length, ok
  task automatic try_pad(input int p, output int c, output bit len_ok, output bit crc_ok);
    int t;
    logic [15:0] r;
    t = pn - p;
    c = t - 2 <= 80 ? t - 2 : t - 4;
    len_ok = t >= 4 && (t - 2 <= 80 || t - 4 > 80);
    crc_ok = 0;
    if (!len_ok) return;
    if (p == 2 && (pk[pn - 1] != 8'h00 || pk[pn - 2] != 8'h00)) return;
    r = 16'hFFFF;
    for (int i = 0; i < t; i++) begin
      logic [7:0] d;
      d = i == 0 ? {6'd0, pk[0][1:0]} : pk[i];
      if (i == 80 && c > 80 && {pk[80], pk[81]} != r) return;   // early CRC
      if (i == t - 2) begin crc_ok = {pk[i], pk[i + 1]} == r; return; end
      r = crc_upd(r, d);
    end
  endtask
  function automatic bit struct_ok(input logic [3:0] ft, input logic [3:0] tty, input int c, input int h);
    int pl;
    pl = c - h;
    if (c < h) return 0;
    case (ft)
      2, 10: return pl == 0;
      5, 6:  return pl > 0 && pl % 8 == 0 && pl <= 256;
      8:     return (tty == 1 || tty == 2) ? pl == 8 : pl == 0;
      13:    return tty == 8 ? pl > 0 && pl % 8 == 0 && pl <= 256 : pl == 0;
      default: return 1;
    endcase
  endfunction
  function automatic int hdr_len(input logic [3:0] ft, input bit t1);
    return (t1 ? 6 : 4) + ((ft == 2 || ft == 5 || ft == 8) ? 6 : (ft == 6 || ft == 10) ? 4 : 2);
  endfunction

  // execute the received packet (state M_CHK); sets the report, the next state
  task automatic execute(input logic [23:0] base_new_in, output logic [23:0] base_new);
    int c0, c2, c, o, hl, pl;
    bit l0k, l2k, k0, k2, s0, s2, t1;
    logic [3:0] ft, tty, sz;
    logic [15:0] dst, src, my;
    logic [7:0] tid;
    base_new = base_new_in;
    x_rep = 1; x_ft = pk[1][3:0];
    ms = M_IDLE;
    if (pn >= 512 || pn % 4 != 0 || pk[1][5]) begin x_why = 3; v_long |= pn >= 512; return; end
    try_pad(0, c0, l0k, k0);
    try_pad(2, c2, l2k, k2);
    t1 = pk[1][4]; ft = pk[1][3:0]; o = t1 ? 6 : 4; hl = hdr_len(ft, t1);
    tty = pk[o][7:4]; sz = pk[o][3:0];
    s0 = l0k && struct_ok(ft, tty, c0, hl);
    s2 = l2k && struct_ok(ft, tty, c2, hl);
    if (!k0 && !k2) begin x_why = 1; return; end
    if (!(k0 && s0) && !(k2 && s2)) begin x_why = 3; return; end
    c = (k0 && s0) ? c0 : c2;
    v_pad_rx |= !(k0 && s0); v_nopad_rx |= k0 && s0; v_early_rx |= c > 80;
    for (int i = 0; i < c; i++) ct[i] = pk[i < 80 ? i : i + 2];
    pl = c - hl;
    dst = t1 ? {ct[2], ct[3]} : {8'd0, ct[2]};
    src = t1 ? {ct[4], ct[5]} : {8'd0, ct[3]};
    my  = t1 ? m_base[15:0] : {8'd0, m_base[23:16]};
    tid = ct[o + 1];
    x_why = 0;
    if (ft == 13) begin
      if (dst != my) x_why = 2;
      else if (obb && tty == 0 && t1 == ob_tt_m && tid == ob_tid_m && src == ob_dest_m) begin
        obb = 0; x_obd = 1; x_obs = ct[o][3:0]; v_ob_ok = 1;
      end else begin x_why = 7; v_ob_other = 1; end
      return;
    end
    if (dst != my || (ft == 8 && ct[o + 2] != 0)) begin x_why = 2; v_hop |= dst == my; return; end
    if (ft == 10) begin
      x_db = 1; x_dbs = src; x_dbt = tid; x_dbi = {ct[o + 2], ct[o + 3]}; v_db_in = 1;
      t_resp(ct[1], src, my, t1, 13, 0, 0, tid); t_start(); ms = M_TX;
      return;
    end
    if (ft == 8) begin
      logic [23:0] off;
      logic [31:0] v;
      off = {ct[o + 3], ct[o + 4], ct[o + 5][7:3], 3'b000} | {21'd0, ct[o + 5][2], 2'b00};
      if (tty == 2 || tty == 3) begin x_why = 7; return; end
      if (tty >= 4 || sz != 8) begin
        x_why = tty >= 4 ? 4 : 5; v_err_resp = 1;
        t_resp(ct[1], src, my, t1, 8, tty == 1 ? 3 : 2, 7, tid); t_start(); ms = M_TX;
        return;
      end
      if (tty == 0) begin
        case (off)
          24'h00: v = cfg_dev_id_car;
          24'h04: v = cfg_dev_info_car;
          24'h08: v = cfg_asm_id_car;
          24'h0C: v = cfg_asm_info_car;
          24'h10: v = cfg_pe_feat_car;
          24'h60: v = {8'd0, m_base};
          24'h68: v = {16'd0, m_lock};
          24'h6C: v = m_tag;
          default: begin v = 0; v_mt_unknown = 1; end
        endcase
        t_resp(ct[1], src, my, t1, 8, 2, 0, tid);
        for (int i = 0; i < 8; i++) t_lit((i < 4) == !off[2] ? v[31 - 8 * (i % 4) -: 8] : 8'h00);
        v_mt_rd = 1;
      end else begin
        for (int i = 0; i < 4; i++) v[31 - 8 * i -: 8] = ct[hl + (off[2] ? 4 : 0) + i];
        if (off == 24'h60) begin base_new = v[23:0]; v_id_load_and_write |= id_load; end
        if (off == 24'h68) begin
          if (m_lock == 16'hFFFF) begin m_lock = v[15:0]; v_lock_take = 1; end
          else if (m_lock == v[15:0]) begin m_lock = 16'hFFFF; v_lock_rel = 1; end
          else v_lock_refused = 1;
        end
        if (off == 24'h6C) m_tag = v;
        if (!(off inside {24'h60, 24'h68, 24'h6C})) v_mt_unknown = 1;
        t_resp(ct[1], src, my, t1, 8, 3, 0, tid);
        v_mt_wr = 1;
      end
      t_start(); ms = M_TX;
      return;
    end
    if (!(ft == 2 && tty == 4 || ft == 5 && (tty == 4 || tty == 5) || ft == 6)) begin
      x_why = 4;
      if (ft == 2 || ft == 5) begin t_resp(ct[1], src, my, t1, 13, 0, 7, tid); t_start(); ms = M_TX; v_err_resp = 1; end
      return;
    end
    begin
      logic [31:0] a;
      longint beg, adw;
      int n, lane, cnt, from;
      bit err, sub;
      a = ft == 6 ? {ct[o], ct[o + 1], ct[o + 2], ct[o + 3]} : {ct[o + 2], ct[o + 3], ct[o + 4], ct[o + 5]};
      adw = {a[31:3], 3'b000};
      sub = ft != 6 && sz <= 10;
      err = a[1:0] != 0;
      from = hl;
      if (ft == 6) begin beg = adw; cnt = pl; end
      else begin
        size_of(sz, a[2], ft == 5, n, lane);
        err |= n == 0;
        if (ft == 2) begin beg = adw; cnt = sub ? 8 : n; end
        else if (sub) begin beg = adw + lane; cnt = n; from = hl + lane; err |= pl != 8; end
        else begin beg = adw; cnt = pl; err |= pl > n; end
      end
      err |= beg + cnt > 1024;
      if (err) begin
        x_why = 5;
        if (ft == 2 || ft == 5 && tty == 5) begin t_resp(ct[1], src, my, t1, 13, 0, 7, tid); t_start(); ms = M_TX; v_err_resp = 1; end
        return;
      end
      v_mem_top |= beg + cnt == 1024;
      v_max_payload |= cnt == 256;
      if (ft == 2) begin
        t_resp(ct[1], src, my, t1, 13, 8, 0, tid);
        for (int i = 0; i < cnt; i++) begin tc[tlen] = 0; tref[tlen] = int'(beg) + i; tlen++; end
        t_start(); ms = M_TX;
        if (sub) v_nread_sub = 1; else v_nread_big = 1;
      end else begin
        for (int i = 0; i < cnt; i++) wd[i] = ct[from + i];
        wn = cnt; wi = 0; wdst = int'(beg); wresp = ft == 5 && tty == 5; ms = M_WR;
        if (wresp) t_resp(ct[1], src, my, t1, 13, 0, 0, tid);
        if (ft == 6) v_swrite = 1;
        else begin
          v_nwrite_r |= wresp;
          if (sub) v_nwrite_sub = 1; else v_nwrite_big = 1;
          v_nwrite_short |= !sub && pl < n;
        end
      end
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms = M_IDLE; skip = 0; drop_pend = 0; pn = 0;
      m_base = 0; m_lock = 16'hFFFF; m_tag = 0; obb = 0; ob_tt_m = 0; ob_dest_m = 0; ob_tid_m = 0;
      {x_tv, x_tl, x_busy, x_rep, x_db, x_obd} = '0;
      x_td = 0; x_why = 0; x_ft = 0; x_obs = 0; x_dbs = 0; x_dbt = 0; x_dbi = 0; x_hr = 0;
      tlen = 0;
      for (int i = 0; i < 16; i++) pk[i] = 8'h00;                   // the header registers reset
    end else begin
      logic [23:0] base_new;
      logic [7:0]  sent;
      bit          was_busy, old_skip, e_we;
      int          e_wa;
      {v_nread_sub, v_nread_big, v_nwrite_sub, v_nwrite_big, v_nwrite_short, v_nwrite_r, v_swrite,
       v_mt_rd, v_mt_wr, v_lock_take, v_lock_rel, v_lock_refused, v_db_in, v_ob_tt0, v_ob_tt1, v_ob_ok,
       v_ob_other, v_early_rx, v_early_tx, v_pad_rx, v_nopad_rx, v_pad_tx, v_nopad_tx, v_long, v_hcol,
       v_drop_in_chk, v_prio_sat, v_tt1_resp, v_max_payload, v_mem_top, v_drop_ob, v_id_load_and_write,
       v_mt_unknown, v_hop, v_err_resp} = '0;
      x_rep = 0; x_db = 0; x_obd = 0;
      if (host_rd) x_hr = mm[host_addr];
      base_new = id_load ? cfg_base_id : m_base;
      sent = x_td;
      // dropped packets: reported the clock after the last octet
      was_busy = ms == M_CHK || ms == M_WR || ms == M_TX;
      old_skip = skip;
      if (drop_pend) begin x_rep = 1; x_why = 6; x_ft = 0; end
      drop_pend = rx_valid && (was_busy || skip) && rx_last;
      if (rx_valid && (was_busy || skip)) begin
        skip = !rx_last;
        v_drop_in_chk |= ms == M_CHK && rx_last;
        v_drop_ob |= ms == M_TX && obb && tlen <= 10 && tc[1][3:0] == 4'd10;
      end
      e_we = 0; e_wa = 0;
      case (ms)
        M_IDLE, M_RX: begin
          if (rx_valid && old_skip) ;
          else if (ms == M_IDLE && ob_start && !obb && !rx_valid) begin
            tlen = 0;
            t_lit(8'h00); t_lit({4'b0000, 4'd10} | {3'b000, ob_tt, 4'd0});
            if (ob_tt) begin
              t_lit(ob_dest[15:8]); t_lit(ob_dest[7:0]); t_lit(m_base[15:8]); t_lit(m_base[7:0]);
            end else begin
              t_lit(ob_dest[7:0]); t_lit(m_base[23:16]);
            end
            t_lit(8'h00); t_lit(ob_tid); t_lit(ob_info[15:8]); t_lit(ob_info[7:0]);
            obb = 1; ob_tt_m = ob_tt; ob_dest_m = ob_tt ? ob_dest : {8'd0, ob_dest[7:0]}; ob_tid_m = ob_tid;
            v_ob_tt0 = !ob_tt; v_ob_tt1 = ob_tt;
            t_start(); ms = M_TX;
          end else if (rx_valid) begin
            if (ms == M_IDLE) pn = 0;
            if (pn < 1024) pk[pn] = rx_data;
            pn++;
            ms = rx_last ? M_CHK : M_RX;
          end
        end
        M_CHK: execute(base_new, base_new);
        M_WR: begin
          e_we = 1; e_wa = wdst + wi;
          mm[e_wa] = wd[wi];
          wi++;
          if (wi == wn) begin
            ms = wresp ? M_TX : M_IDLE;
            if (wresp) t_start();
          end
        end
        default: if (t_adv(sent)) ms = M_IDLE;
      endcase
      // the host write, unless it hits the octet the endpoint writes now
      v_hcol = host_wr && e_we && e_wa == host_addr;
      if (host_wr && !v_hcol) mm[host_addr] = host_wdata;
      m_base = base_new;
      // outputs for the next clock
      x_busy = ms == M_CHK || ms == M_WR || ms == M_TX;
      x_tv = ms == M_TX;
      if (ms == M_TX) begin
        t_out(x_td, x_tl);
        if (x_tl) begin v_early_tx = tlen > 80; v_pad_tx = tph == 3; v_nopad_tx = tph == 2; end
      end else begin x_td = 8'h00; x_tl = 0; end
      for (int i = 0; i < 8; i++) v_why[i] = x_rep && x_why == i;
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_valid, tx_valid === x_tv)
  `SVA_IMP(a_tx_data, x_tv, tx_data === x_td)
  `SVA_INV(a_tx_last, tx_last === x_tl)
  `SVA_INV(a_busy, busy === x_busy)
  `SVA_INV(a_rx_rep, rx_rep === x_rep)
  `SVA_IMP(a_rx_why, x_rep, rx_why === x_why && rx_ftype === x_ft)
  `SVA_INV(a_db_valid, db_valid === x_db)
  `SVA_IMP(a_db_fields, x_db, db_src === x_dbs && db_tid === x_dbt && db_info === x_dbi)
  `SVA_INV(a_ob_done, ob_done === x_obd)
  `SVA_IMP(a_ob_status, x_obd, ob_status === x_obs)
  `SVA_INV(a_ob_busy, ob_busy === obb)
  `SVA_INV(a_base_id, base_id === m_base)
  `SVA_INV(a_host_rdata, host_rdata === x_hr)
  `SVA_RST(a_rst_outputs, 1'b1, !tx_valid && !tx_last && !busy && !rx_rep && !db_valid && !ob_done && !ob_busy &&
                                base_id == 24'd0 && host_rdata == 8'd0 && ob_status == 4'd0)

  // ---------------- functional coverage ----------------
  `FC(nread_sub_dword, v_nread_sub)
  `FC(nread_multi_dword, v_nread_big)
  `FC(nwrite_sub_dword, v_nwrite_sub)
  `FC(nwrite_multi_dword, v_nwrite_big)
  `FC(nwrite_shorter_than_size, v_nwrite_short)
  `FC(nwrite_r, v_nwrite_r)
  `FC(swrite, v_swrite)
  `FC(maint_read, v_mt_rd)
  `FC(maint_write, v_mt_wr)
  `FC(maint_unknown_offset, v_mt_unknown)
  `FC(lock_taken, v_lock_take)
  `FC(lock_released, v_lock_rel)
  `FC(lock_refused, v_lock_refused)
  `FC(hop_count_not_zero, v_hop)
  `FC(doorbell_in, v_db_in)
  `FC(doorbell_out_tt0, v_ob_tt0)
  `FC(doorbell_out_tt1, v_ob_tt1)
  `FC(doorbell_response_ok, v_ob_ok)
  `FC(unexpected_response, v_ob_other)
  `FC(error_response, v_err_resp)
  `FC(why_executed, v_why[0])
  `FC(why_crc, v_why[1])
  `FC(why_not_for_us, v_why[2])
  `FC(why_malformed, v_why[3])
  `FC(why_unsupported, v_why[4])
  `FC(why_request_error, v_why[5])
  `FC(why_dropped, v_why[6])
  `FC(why_unexpected_response, v_why[7])
  `FC(early_crc_received, v_early_rx)
  `FC(early_crc_sent, v_early_tx)
  `FC(pad_received, v_pad_rx)
  `FC(no_pad_received, v_nopad_rx)
  `FC(pad_sent, v_pad_tx)
  `FC(no_pad_sent, v_nopad_tx)
  `FC(packet_too_long, v_long)
  `FC(host_write_collision, v_hcol)
  `FC(drop_while_checking, v_drop_in_chk)
  `FC(drop_while_doorbell_out, v_drop_ob)
  `FC(priority_saturates, v_prio_sat)
  `FC(response_16bit_ids, v_tt1_resp)
  `FC(payload_256, v_max_payload)
  `FC(memory_top, v_mem_top)
  `FC(id_load_with_maint_write, v_id_load_and_write)
endmodule

bind RAPIDIO_top RAPIDIO_sva u_sva (.*);
