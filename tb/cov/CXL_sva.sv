// SPDX-License-Identifier: Apache-2.0
// CXL Type 3 device with a 256-byte flit link: concurrent SVA against an
// independent reference model, plus functional coverage.
//  * Link receive: the model keeps the flit's beats, checks its CRC over
//    the whole flit at the last beat (not beat by beat), the sequence
//    number and type, and from the next clock walks its own copy of the
//    flit one unit per clock: messages into its Req queue, RwD message
//    (header, byte enables, 8 data units, rolling over flits) and BIRsp
//    holder, CXL.io payloads (re-aligned by two bytes) into its CXL.io
//    queue; full buffers drop the message.
//  * Device memory is kept as 512-bit lines. Each clock the model decides,
//    from its own state, whether the BIRsp, the Req or the RwD at the head
//    is served (round robin on a tie, only when the response it needs can be
//    held), applies it, and runs the snoop filter (count of lines not
//    Invalid), the eviction victim search and the BISnp engine.
//  * Link transmit: the model builds each flit beat by beat (type choice,
//    each header unit's message, DRS data slots, credits), keeps the beats
//    and computes the CRC over all of them at beat 30.
//  * tx_valid / tx_data, io_tx_ready, io_rx_*, bi_ready, bi_done /
//    bi_state, sf_cnt and the event pulses are compared on every clock.
`include "cov_macros.svh"
module CXL_sva #(
  parameter int LINES = 16, RQD = 4, WQD = 2, SFE = 4, IOD = 2
)(
  input logic        clk, rst_n,
  input logic [15:0] hdm_base,
  input logic        bi_en,
  input logic        rx_valid,
  input logic [63:0] rx_data,
  input logic        tx_valid, tx_ready,
  input logic [63:0] tx_data,
  input logic        io_rx_valid, io_rx_ready,
  input logic [63:0] io_rx_data,
  input logic        io_rx_last,
  input logic        io_tx_valid, io_tx_ready,
  input logic [63:0] io_tx_data,
  input logic        bi_valid, bi_ready,
  input logic [1:0]  bi_op,
  input logic [$clog2(LINES)-1:0] bi_line,
  input logic        bi_done,
  input logic [1:0]  bi_state,
  input logic [$clog2(LINES):0] sf_cnt,
  input logic        ev_range, ev_opcode, ev_proto, ev_poison, ev_crc, ev_seq, ev_fmt, ev_ovf
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [63:0] POLY = 64'h42F0E1EBA9EA3693;
  function automatic logic [63:0] crc_bits(input logic [63:0] c, input logic [63:0] d, input int n);
    logic [63:0] r;
    r = c;
    for (int i = n - 1; i >= 0; i--) r = {r[62:0], 1'b0} ^ ({64{r[63] ^ d[i]}} & POLY);
    return r;
  endfunction
  // CRC of a whole flit: beats 0..29, then CRD
  function automatic logic [63:0] flit_crc(input logic [63:0] f [0:31]);
    logic [63:0] c;
    c = '1;
    for (int b = 0; b < 30; b++) c = crc_bits(c, f[b], 64);
    return crc_bits(c, f[30], 16);
  endfunction
  function automatic int need(input logic [3:0] op);
    case (op)
      4'd1, 4'd2: return 2;
      4'd0, 4'd9, 4'd10: return 1;
      default: return 0;
    endcase
  endfunction
  function automatic logic [1:0] load(input int n);
    if (n == 0) return 2'b00;
    if (n == 1) return 2'b01;
    if (n < RQD - 1) return 2'b10;
    return 2'b11;
  endfunction
  function automatic int addc(input int c, input int a, input int u);
    return (c + a > 255 ? 255 : c + a) - u;
  endfunction

  // ---------------- model state ----------------
  logic [511:0] mline [0:LINES-1];
  logic [1:0]   mmeta [0:LINES-1];
  bit           mpo [0:LINES-1];
  int           msf;
  // receive
  logic [63:0]  mrb [0:31];
  int           mrj;
  logic [7:0]   mxseq;
  bit           mua, muio, mube, mubic, mukeep;
  int           muj;
  logic [63:0]  muf [0:31];                    // the flit being unpacked
  int           mro;                           // data units owed
  bit           mrokeep;
  // the RwD message being received
  logic [3:0]   ip_op;
  logic [1:0]   ip_mf, ip_mv;
  bit           ip_s2, ip_po;
  logic [15:0]  ip_tag, ip_addr;
  logic [63:0]  ip_be;
  logic [63:0]  ip_d [0:7];
  // Req queue
  logic [3:0]   q_op [$];
  logic [1:0]   q_mf [$], q_mv [$];
  bit           q_s2 [$];
  logic [15:0]  q_tag [$], q_addr [$];
  // complete RwD messages
  logic [3:0]   w_op [$];
  logic [1:0]   w_mf [$], w_mv [$];
  bit           w_s2 [$], w_po [$];
  logic [15:0]  w_tag [$], w_addr [$];
  logic [63:0]  w_be [$];
  logic [511:0] w_ln [$];
  // BIRsp holder
  bit           mbv;
  logic [3:0]   mbop;
  logic [11:0]  mbtag;
  // CXL.io receive
  logic [63:0]  io_q [$];                      // complete flits, 30 beats each
  logic [63:0]  io_cur [0:29];
  int           mirw;
  // BI engine: 0 idle, 1 send, 2 wait
  int           mbst, mbln, mvp, mbsop;
  bit           mbext;
  logic [11:0]  mbtg;
  bit           mdone;
  logic [1:0]   mdst;
  // responses
  bit           m_nv, m_dv, m_dhs, m_dfirst;
  logic [2:0]   m_nop;
  logic [15:0]  m_ntag, m_dtag;
  logic [1:0]   m_nmv, m_ndl, m_dmv, m_ddl;
  bit           m_dpo;
  logic [511:0] m_dline;
  int           m_dwc;
  bit           m_arb;
  // transmit
  bit           m_tv, m_ta, m_tio, m_tnop, m_tlio, m_trr;
  logic [63:0]  m_td;
  int           m_tj;
  logic [7:0]   m_tseq;
  logic [63:0]  m_tb [0:31];                   // the beats of the flit being sent
  bit           m_th [0:31];                   // ... and those that carried a message
  bit           mu_h0;                         // the last unit received was a message in a slot's first unit
  logic [15:0]  m_tc48, m_tio16;
  int           m_cn, m_cd, m_cb, m_ci;       // credits from the host
  int           m_pq, m_pw, m_pb, m_pi;       // credits owed to the host
  bit           m_ev [0:7];                    // range, opcode, proto, poison, crc, seq, fmt, ovf

  // ---------------- this clock's decisions ----------------
  bit           k_adv, k_nel, k_del, k_bel, k_dowe, k_cm, k_io, k_crd, k_start, k_sio, k_snop, k_gen, k_cmf,
                k_unit, k_dat, k_hdr, k_resp, k_bis, k_pndr, k_pdrs, k_last, k_iotr, k_iov;
  int           k_b;
  bit           k_nfree, k_dfree, k_rv, k_in, k_alloc, k_blk, k_full, k_evict, k_bir, k_cq, k_cw, k_gw, k_gq,
                k_wok, k_wbic;
  int           k_need, k_dpa, k_victim;
  logic [1:0]   k_mf;
  logic [63:0]  k_iod;
  always @(*) begin
    logic [15:0] off;
    k_adv = !m_tv || tx_ready;
    k_nel = m_nv && !(m_dv && !m_dhs && m_dfirst) && m_cn != 0;
    k_del = m_dv && !m_dhs && !(m_nv && !m_dfirst) && m_cd != 0;
    k_bel = mbst == 1 && m_cb != 0;
    k_dowe = m_dv && m_dhs;
    k_cm = k_nel || k_del || k_bel || k_dowe;
    k_io = io_tx_valid && m_ci != 0;
    k_crd = m_pq != 0 || m_pw != 0 || m_pb != 0 || m_pi != 0;
    k_start = !m_ta && k_adv && (k_cm || k_io || k_crd);
    k_sio = k_io && (!k_cm || !m_tlio);
    k_snop = !k_cm && !k_io;
    k_gen = k_start || m_ta && k_adv && !(m_tio && m_tj <= 29 && !io_tx_valid);
    k_b = k_start ? 0 : m_tj;
    k_cmf = m_ta && !m_tio && !m_tnop;
    k_unit = k_gen && k_cmf && k_b >= 1 && k_b <= 29;
    k_dat = k_unit && k_b >= 2 && k_dowe && (m_dwc != 0 || k_b % 2 == 0);
    k_hdr = k_unit && !k_dat;
    k_resp = k_hdr && (k_nel || k_del) && (!k_bel || !m_trr);
    k_bis = k_hdr && k_bel && !k_resp;
    k_pndr = k_resp && k_nel;
    k_pdrs = k_resp && k_del;
    k_last = k_dat && m_dwc == 7;
    k_iotr = k_gen && (k_start ? k_sio : m_tio && m_tj <= 29);
    k_iov = io_q.size() != 0;
    k_iod = k_iov ? io_q[mirw] : 64'd0;
    // the core
    k_nfree = !m_nv || k_pndr;
    k_dfree = !m_dv || k_last;
    k_rv = q_op.size() != 0;
    k_mf = 2'b00; k_in = 0; k_dpa = 0; k_alloc = 0; k_need = 0;
    if (k_rv) begin
      k_mf = q_mf[0] == 2'b01 || q_mf[0] == 2'b10 || q_s2[0] ? 2'b11 : q_mf[0];
      off = q_addr[0] - hdm_base;
      k_in = off < LINES;
      k_dpa = int'(off) % LINES;
      k_need = need(q_op[0]);
      k_alloc = k_in && k_mf == 2'b00 && q_mv[0] != 2'b00 && mmeta[k_dpa] == 2'b00 &&
                (q_op[0] == 4'd0 || q_op[0] == 4'd1 || q_op[0] == 4'd9 || q_op[0] == 4'd10);
    end
    k_blk = k_rv && mbst != 0 && k_in && k_dpa == mbln;
    k_full = k_rv && bi_en && k_alloc && msf >= SFE;
    k_evict = k_full && mbst == 0;
    k_bir = mbv;
    k_cq = k_rv && !k_blk && !k_full && (k_need == 0 || k_need == 1 && k_nfree || k_need == 2 && k_dfree);
    k_wok = w_op.size() != 0 && (w_op[0] == 4'd1 || w_op[0] == 4'd2);
    k_wbic = w_op.size() != 0 && w_op[0] == 4'd4 && bi_en;
    k_cw = w_op.size() != 0 && (!(k_wok || k_wbic) || k_nfree);
    k_gw = !k_bir && k_cw && (m_arb || !k_cq);
    k_gq = !k_bir && k_cq && !k_gw;
    // the eviction victim: the first line not Invalid from mvp on
    k_victim = mvp;
    for (int k = LINES - 1; k >= 0; k--) if (mmeta[(mvp + k) % LINES] != 2'b00) k_victim = (mvp + k) % LINES;
  end
  wire k_bi_ready = bi_en && mbst == 0 && !k_evict;

  // ---------------- coverage flags ----------------
  bit v_op [0:15], v_wop [0:15], v_cmp [0:4], v_rng_rd, v_rng_wr, v_rng_inv, v_poi_rd, v_po_set, v_po_clr, v_po_keep;
  bit v_be0, v_be_part, v_res_mf, v_res_snp, v_dl_n [0:3], v_dl_d [0:3], v_tie_q, v_tie_w, v_q_wait_n, v_q_wait_d;
  bit v_w_wait, v_drs_b2b, v_ndr_b2b, v_wrap, v_spec_out, v_meta_set [0:3], v_rddata_meta, v_ptl_po;
  bit v_rx_type [0:3], v_crc, v_crc_abort, v_seq, v_fmt_code, v_fmt_odd, v_fmt_type, v_ovf_req, v_ovf_rwd, v_ovf_bir,
      v_ovf_io, v_rx_roll, v_rx_hslot, v_rx_two, v_rwd_last, v_rwd_drop, v_bic_drop;
  bit v_tx_type [0:2], v_tx_roll, v_tx_hslot, v_tx_two, v_drs_u0, v_drs_u1, v_crd_n, v_crd_d, v_crd_b, v_crd_io,
      v_io_stall, v_alt_io, v_alt_cm, v_d_first, v_n_first, v_rr_bis, v_rr_resp, v_sat, v_crd15, v_crd_back;
  bit v_evict, v_ext_imm, v_ext_op [0:3], v_rsp [0:2][0:3], v_rsp_bad [0:2], v_bir_stale, v_bir_none, v_bir_hdmh,
      v_req_blk, v_ev_wait, v_rwd_sf_full, v_bic, v_bic_hdmh, v_ext_busy, v_sf_full, v_wb_during_bi, v_req_after_bi,
      m_mid, v_rst_mid;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_qv, c_wv, c_dv, c_wpo, c_rxu, c_txu;
  int c_qop, c_qln, c_wln, c_wop, c_rxj, c_rxf, c_txj, c_txf, c_sf;
  logic [1:0]  c_mv;
  logic [63:0] c_wd, c_rd;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int l = 0; l < LINES; l++) begin mline[l] = '0; mmeta[l] = 2'b00; mpo[l] = 0; end
      msf = 0; mrj = 0; mxseq = 0; mua = 0; muio = 0; mube = 0; mubic = 0; mukeep = 0; muj = 0; mro = 0; mrokeep = 0;
      q_op.delete(); q_mf.delete(); q_mv.delete(); q_s2.delete(); q_tag.delete(); q_addr.delete();
      w_op.delete(); w_mf.delete(); w_mv.delete(); w_s2.delete(); w_po.delete(); w_tag.delete(); w_addr.delete();
      w_be.delete(); w_ln.delete();
      mbv = 0; io_q.delete(); mirw = 0;
      mbst = 0; mbln = 0; mvp = 0; mbsop = 0; mbext = 0; mbtg = 12'd1; mdone = 0; mdst = 0;
      m_nv = 0; m_dv = 0; m_dhs = 0; m_dfirst = 0; m_nop = 0; m_ntag = 0; m_dtag = 0; m_nmv = 0; m_ndl = 0;
      m_dmv = 0; m_ddl = 0; m_dpo = 0; m_dwc = 0; m_arb = 0;
      m_tv = 0; m_ta = 0; m_tio = 0; m_tnop = 0; m_tlio = 0; m_trr = 0; m_td = 0; m_tj = 0; m_tseq = 0;
      m_tc48 = 0; m_tio16 = 0;
      m_cn = 0; m_cd = 0; m_cb = 0; m_ci = 0; m_pq = RQD; m_pw = WQD; m_pb = 1; m_pi = IOD;
      for (int e = 0; e < 8; e++) m_ev[e] = 0;
      if (m_mid) v_rst_mid = 1;
      m_mid = 0;
    end else begin : b_step
      // decisions of this clock (taken before anything changes)
      bit          adv, start, sio, snop, gen, cmf, dat, pndr, pdrs, pbis, presp, last, gq, gw, gb, evict, nfree,
                   o_nv, o_dv, o_dhs, iopop, rend, bi_acc, ua_pre;
      int          b, a_n, a_d, a_b, a_io, victim, nq;
      logic [1:0]  dl;
      adv = k_adv; start = k_start; sio = k_sio; snop = k_snop; gen = k_gen; cmf = k_cmf; dat = k_dat;
      pndr = k_pndr; pdrs = k_pdrs; pbis = k_bis; presp = k_resp; last = k_last; b = k_b;
      gq = k_gq; gw = k_gw; gb = k_bir; evict = k_evict; nfree = k_nfree; victim = k_victim;
      bi_acc = bi_valid && k_bi_ready;
      ua_pre = mua;
      o_nv = m_nv; o_dv = m_dv; o_dhs = m_dhs;
      iopop = k_iov && io_rx_ready && mirw == 29;
      nq = q_op.size();
      dl = load(nq - int'(gq));
      a_n = 0; a_d = 0; a_b = 0; a_io = 0;
      for (int e = 0; e < 8; e++) m_ev[e] = 0;
      mdone = 0;
      {c_qv, c_wv, c_dv, c_rxu, c_txu} = '0;
      c_sf = msf;
      m_mid = mrj > 3 && tx_valid;
      // coverage of the decisions
      if (k_cq && k_cw && !k_bir) begin if (gq) v_tie_q = 1; else v_tie_w = 1; end
      if (k_rv && !k_blk && !k_full && k_need == 1 && !nfree) v_q_wait_n = 1;
      if (k_rv && !k_blk && !k_full && k_need == 2 && !k_dfree) v_q_wait_d = 1;
      if (k_wok && !nfree) v_w_wait = 1;
      if (k_blk) v_req_blk = 1;
      if (k_full && mbst != 0) v_ev_wait = 1;
      if (bi_valid && bi_en && mbst != 0) v_ext_busy = 1;
      if (msf == SFE && bi_en) v_sf_full = 1;
      if (m_nv && !k_nel && m_cn == 0) v_crd_n = 1;
      if (m_dv && !m_dhs && m_cd == 0) v_crd_d = 1;
      if (mbst == 1 && m_cb == 0) v_crd_b = 1;
      if (io_tx_valid && m_ci == 0) v_crd_io = 1;
      if (m_ta && m_tio && m_tj <= 29 && !io_tx_valid && adv) v_io_stall = 1;
      if (start && k_cm && k_io) begin if (sio) v_alt_io = 1; else v_alt_cm = 1; end
      if (m_nv && m_dv && !m_dhs) begin if (m_dfirst) v_d_first = 1; else v_n_first = 1; end
      if (k_hdr && (k_nel || k_del) && k_bel) begin if (pbis) v_rr_bis = 1; else v_rr_resp = 1; end

      // ================= link receive =================
      rend = 0;
      if (rx_valid) begin
        mrb[mrj] = rx_data;
        if (mrj == 31) begin : b_end
          logic [63:0] c;
          logic [1:0]  typ;
          logic [7:0]  seq;
          rend = 1;
          c = flit_crc(mrb);
          typ = mrb[0][1:0]; seq = mrb[0][15:8];
          if (c != {mrb[31][15:0], mrb[30][63:16]}) begin
            m_ev[4] = 1; v_crc = 1;
            mxseq = mxseq + 8'd1;
            if (mro != 0) v_crc_abort = 1;
            mro = 0;
          end else begin
            if (seq != mxseq) begin m_ev[5] = 1; v_seq = 1; end
            mxseq = seq + 8'd1;
            v_rx_type[typ] = 1;
            if (typ == 2'd3) begin m_ev[6] = 1; v_fmt_type = 1; end
            else begin
              a_n = mrb[30][3:0]; a_d = mrb[30][7:4]; a_b = mrb[30][11:8]; a_io = mrb[30][15:12];
              if (a_n == 15 || a_d == 15 || a_b == 15 || a_io == 15) v_crd15 = 1;
              if (typ == 2'd2) begin
                mua = 1; muio = 0; muj = 1;
                for (int k = 0; k < 32; k++) muf[k] = mrb[k];
                if (mro != 0) v_rx_roll = 1;
              end
              if (typ == 2'd1) begin
                if ((io_q.size() + 29) / 30 + m_pi >= IOD) begin m_ev[7] = 1; v_ovf_io = 1; end
                else begin
                  mua = 1; muio = 1; muj = 0;
                  for (int k = 0; k < 32; k++) muf[k] = mrb[k];
                end
              end
            end
          end
          mrj = 0;
        end else mrj++;
      end

      // ================= unpacker (the clock after the flit's end, on) =================
      if (ua_pre) begin : b_unpack
        logic [63:0] u;
        int          j;
        bit          wasdata, h0;
        j = muj;
        u = muf[j];
        wasdata = 0;
        h0 = 0;
        if (muio) begin
          io_cur[j] = j == 29 ? {16'd0, u[63:16]} : {muf[j + 1][15:0], u[63:16]};
          if (j == 29) begin
            mua = 0;
            for (int k = 0; k < 30; k++) io_q.push_back(io_cur[k]);
          end
        end else begin
          if (j == 29) mua = 0;
          c_rxu = 1; c_rxj = j; c_rxf = 16;
          if (j >= 2 && mro != 0) begin
            c_rxf = 15;
            wasdata = 1;
            ip_d[8 - mro] = u;
            mro--;
            if (mro == 0 && mrokeep) begin
              logic [511:0] ln;
              for (int k = 0; k < 8; k++) ln[64 * k +: 64] = ip_d[k];
              w_op.push_back(ip_op); w_mf.push_back(ip_mf); w_mv.push_back(ip_mv); w_s2.push_back(ip_s2);
              w_po.push_back(ip_po); w_tag.push_back(ip_tag); w_addr.push_back(ip_addr); w_be.push_back(ip_be);
              w_ln.push_back(ln);
            end
          end else if (mube) begin
            c_rxf = 14;
            mube = 0;
            ip_be = u;
            if (mubic) begin
              if (mukeep) begin
                w_op.push_back(ip_op); w_mf.push_back(ip_mf); w_mv.push_back(ip_mv); w_s2.push_back(ip_s2);
                w_po.push_back(ip_po); w_tag.push_back(ip_tag); w_addr.push_back(ip_addr); w_be.push_back(ip_be);
                w_ln.push_back(512'd0);
              end
            end else begin
              mro = 8; mrokeep = mukeep;
            end
            if (j == 29) v_rwd_last = 1;
          end else begin
            c_rxf = u[3:0];
            if (j == 1 && mro != 0 && u[3:0] != 4'd0) v_rx_hslot = 1;
            if (j % 2 == 1 && mu_h0 && (u[3:0] == 4'd1 || u[3:0] == 4'd3)) v_rx_two = 1;
            case (u[3:0])
              4'd0: ;
              4'd1:
                if (nq + m_pq >= RQD) begin m_ev[7] = 1; v_ovf_req = 1; end
                else begin
                  q_op.push_back(u[7:4]); q_mf.push_back(u[9:8]); q_mv.push_back(u[11:10]); q_s2.push_back(u[14]);
                  q_tag.push_back(u[31:16]); q_addr.push_back(u[47:32]);
                end
              4'd2:
                if (j % 2 == 1) begin m_ev[6] = 1; v_fmt_odd = 1; end
                else begin
                  mube = 1; mubic = u[7:4] == 4'd4;
                  mukeep = w_op.size() + m_pw < WQD;
                  if (!mukeep) begin
                    m_ev[7] = 1; v_ovf_rwd = 1;
                    if (mubic) v_bic_drop = 1; else v_rwd_drop = 1;
                  end
                  ip_op = u[7:4]; ip_mf = u[9:8]; ip_mv = u[11:10]; ip_s2 = u[14]; ip_po = u[15];
                  ip_tag = u[31:16]; ip_addr = u[47:32];
                end
              4'd3:
                if (mbv || m_pb != 0) begin m_ev[7] = 1; v_ovf_bir = 1; end
                else begin mbv = 1; mbop = u[7:4]; mbtag = u[19:8]; end
              default: begin m_ev[6] = 1; v_fmt_code = 1; end
            endcase
          end
        end
        if (!muio) mu_h0 = j % 2 == 0 && !wasdata && (u[3:0] == 4'd1 || u[3:0] == 4'd3) && c_rxf == u[3:0];
        muj = j + 1;
      end

      // ================= CXL.io receive =================
      if (k_iov && io_rx_ready) begin
        if (mirw == 29) begin
          for (int k = 0; k < 30; k++) void'(io_q.pop_front());
          mirw = 0;
        end else mirw++;
      end

      // ================= link transmit =================
      if (adv && !gen) m_tv = 0;
      if (gen) begin : b_tx
        logic [63:0] bt;
        if (start) begin
          bt = {sio ? io_tx_data[47:0] : 48'd0, m_tseq, 6'd0, sio ? 2'd1 : snop ? 2'd0 : 2'd2};
          m_ta = 1; m_tio = sio; m_tnop = snop;
          m_tseq = m_tseq + 8'd1;
          v_tx_type[sio ? 1 : snop ? 0 : 2] = 1;
          if (sio) m_tlio = 1; else if (!snop) m_tlio = 0;
        end else if (b == 30) begin : b_c30
          logic [63:0] c;
          logic [15:0] cr;
          cr = {4'(m_pi), 4'(m_pb), 4'(m_pw), 4'(m_pq)};
          m_tb[30] = {48'd0, cr};
          c = flit_crc(m_tb);
          bt = {c[47:0], cr};
          m_tc48 = c[63:48];
          if (m_pq == RQD && m_pw == WQD && m_pb == 1 && m_pi == IOD) v_crd_back = 1;
        end else if (b == 31) bt = {48'd0, m_tc48};
        else if (m_tio) bt = {io_tx_data[47:0], m_tio16};
        else if (dat) begin
          bt = m_dline[64 * m_dwc +: 64];
          if (m_dwc != 0 && b == 2) v_tx_roll = 1;
          m_dwc++;
          if (last) begin m_dv = 0; m_dhs = 0; m_dwc = 0; end
        end else if (pndr) begin
          bt = {32'd0, m_ntag, 4'd0, m_ndl, m_nmv, 1'b0, m_nop, 4'd4};
          m_nv = 0;
        end else if (pdrs) begin
          bt = {32'd0, m_dtag, 3'd0, m_dpo, m_ddl, m_dmv, 4'd0, 4'd5};
          m_dhs = 1; m_dfirst = 0;
          if (b % 2 == 0) v_drs_u0 = 1; else v_drs_u1 = 1;
        end else if (pbis) begin
          bt = {16'd0, hdm_base + 16'(mbln), 12'd0, mbtg, 2'b00, 2'(mbsop), 4'd6};
          mbst = 2;
        end else bt = 64'd0;
        if (presp) m_trr = 1;
        if (pbis) m_trr = 0;
        if (cmf && b == 1 && o_dv && o_dhs && (pndr || pbis)) v_tx_hslot = 1;
        if (cmf && b % 2 == 1 && b >= 3 && (pndr || pbis || pdrs) && m_th[b - 1]) v_tx_two = 1;
        m_th[b] = pndr || pbis || pdrs;
        if (m_tio || start && sio) m_tio16 = io_tx_data[63:48];
        m_tb[b] = bt;
        m_td = bt;
        m_tv = 1;
        if (b == 31) m_ta = 0;
        m_tj = b + 1;
      end
      // credits
      m_cn = addc(m_cn, a_n, int'(pndr));
      m_cd = addc(m_cd, a_d, int'(pdrs));
      m_cb = addc(m_cb, a_b, int'(pbis));
      m_ci = addc(m_ci, a_io, int'(start && sio));
      if (m_cn == 255 || m_ci == 255) v_sat = 1;
      if (gen && b == 30) begin m_pq = 0; m_pw = 0; m_pb = 0; m_pi = 0; end
      m_pq += int'(gq); m_pw += int'(gw); m_pb = m_pb | int'(gb); m_pi += int'(iopop);

      // ================= a BIRsp =================
      if (gb) begin : b_bir
        bit         legal;
        logic [1:0] s;
        int         ro;
        mbv = 0;
        if (!bi_en && mbst == 0) v_bir_hdmh = 1;
        if (mbst == 2 && mbtag == mbtg) begin
          legal = mbop == 4'd0 || mbop == 4'd1 && mbsop != 2 || mbop == 4'd2 && mbsop == 0;
          s = !legal ? 2'b00 : mbop == 4'd1 ? 2'b11 : mbop == 4'd2 ? 2'b10 : 2'b00;
          ro = mbop < 3 ? mbop : 3;
          if (legal) v_rsp[mbsop][ro] = 1; else begin m_ev[2] = 1; v_rsp_bad[mbsop] = 1; end
          msf = msf + int'(s != 2'b00) - int'(mmeta[mbln] != 2'b00);
          mmeta[mbln] = s;
          mbst = 0;
          if (mbext) begin mdone = 1; mdst = s; end
        end else begin
          m_ev[2] = 1;
          if (mbst == 2) v_bir_stale = 1; else if (bi_en) v_bir_none = 1;
        end
      end

      // ================= back-invalidation requests =================
      if (evict) begin
        mbst = 1; mbln = victim; mbsop = 2; mbext = 0;
        mbtg = {mbtg[10:0], mbtg[11] ^ mbtg[10] ^ mbtg[9] ^ mbtg[3]};
        mvp = (victim + 1) % LINES;
        v_evict = 1;
      end else if (bi_acc) begin
        if (mmeta[bi_line] == 2'b00) begin
          mdone = 1; mdst = 2'b00; v_ext_imm = 1;
        end else begin
          mbst = 1; mbln = bi_line; mbsop = bi_op == 2'd3 ? 2 : bi_op; mbext = 1;
          mbtg = {mbtg[10:0], mbtg[11] ^ mbtg[10] ^ mbtg[9] ^ mbtg[3]};
          v_ext_op[bi_op] = 1;
        end
      end

      // ================= a Req served =================
      if (gq) begin : b_req
        logic [3:0]  op;
        logic [1:0]  mf, mv, old;
        logic [15:0] off;
        int          ln;
        bit          in;
        op = q_op.pop_front(); mf = q_mf.pop_front(); mv = q_mv.pop_front();
        m_arb = 1;
        off = q_addr[0] - hdm_base;
        in = off < LINES;
        ln = int'(off) % LINES;
        if (in && q_addr[0] < hdm_base) v_wrap = 1;
        old = in ? mmeta[ln] : 2'b00;
        if (mf == 2'b01 || mf == 2'b10 || q_s2[0]) begin
          m_ev[2] = 1; mf = 2'b11;
          if (q_s2[0]) v_res_snp = 1; else v_res_mf = 1;
        end
        v_op[op] = 1;
        if (need(op) != 0 && in) begin c_qv = 1; c_qop = need(op); c_qln = ln; c_mv = old; end
        if (need(op) != 0 && !in) begin
          m_ev[0] = 1;
          if (need(op) == 2) v_rng_rd = 1; else v_rng_inv = 1;
        end
        if (op == 4'd8 && !in) v_spec_out = 1;
        if (in && mbst == 0 && bi_en && mbln == ln) v_req_after_bi = 1;
        if (need(op) == 2) begin
          if (o_dv) v_drs_b2b = 1;
          m_dv = 1; m_dhs = 0; m_dwc = 0; m_dfirst = 0;
          m_dtag = q_tag[0]; m_dmv = old; m_ddl = dl; m_dpo = !in || mpo[ln];
          v_dl_d[dl] = 1;
          m_dline = in ? mline[ln] : 512'd0;
          if (in && mpo[ln]) begin m_ev[3] = 1; v_poi_rd = 1; end
          if (in && !mpo[ln]) begin c_dv = 1; c_rd = mline[ln][63:0]; end
          if (in && op == 4'd1 && mf == 2'b00) begin
            msf = msf + int'(mv != 2'b00) - int'(mmeta[ln] != 2'b00);
            mmeta[ln] = mv; v_meta_set[mv] = 1;
          end
          if (op == 4'd2 && mf == 2'b00) v_rddata_meta = 1;
        end else if (need(op) == 1) begin
          if (o_nv) v_ndr_b2b = 1;
          m_nv = 1; m_ntag = q_tag[0]; m_nmv = old; m_ndl = dl;
          m_nop = 3'd0;
          if (op != 4'd10 && mf == 2'b00) m_nop = mv == 2'b11 ? 3'd1 : mv == 2'b10 ? 3'd2 : 3'd0;
          m_dfirst = o_dv && !o_dhs && !pdrs;
          v_cmp[m_nop] = 1;
          v_dl_n[dl] = 1;
          if (in && mf == 2'b00) begin
            msf = msf + int'(mv != 2'b00) - int'(mmeta[ln] != 2'b00);
            mmeta[ln] = mv; v_meta_set[mv] = 1;
          end
        end else if (op != 4'd8) m_ev[1] = 1;
        void'(q_s2.pop_front()); void'(q_tag.pop_front()); void'(q_addr.pop_front());
      end

      // ================= an RwD message served =================
      if (gw) begin : b_rwd
        logic [3:0]   op;
        logic [1:0]   mf, mv;
        logic [15:0]  off;
        logic [63:0]  be;
        logic [511:0] d;
        int           ln;
        bit           in, po;
        op = w_op.pop_front(); mf = w_mf.pop_front(); mv = w_mv.pop_front(); po = w_po.pop_front();
        be = w_be.pop_front(); d = w_ln.pop_front();
        m_arb = 0;
        off = w_addr[0] - hdm_base;
        in = off < LINES;
        ln = int'(off) % LINES;
        v_wop[op] = 1;
        if (op == 4'd4 && bi_en) begin
          if (o_nv) v_ndr_b2b = 1;
          m_nv = 1; m_nop = 3'd4; m_ntag = w_tag[0]; m_nmv = 2'b00; m_ndl = dl;
          m_dfirst = o_dv && !o_dhs && !pdrs;
          v_cmp[4] = 1; v_bic = 1;
        end else begin
          if (op == 4'd4) v_bic_hdmh = 1;
          if (mf == 2'b01 || mf == 2'b10 || w_s2[0]) begin
            m_ev[2] = 1; mf = 2'b11;
            if (w_s2[0]) v_res_snp = 1; else v_res_mf = 1;
          end
          if (op != 4'd1 && op != 4'd2) m_ev[1] = 1;
          else begin
            if (o_nv) v_ndr_b2b = 1;
            m_nv = 1; m_nop = 3'd0; m_ntag = w_tag[0]; m_nmv = in ? mmeta[ln] : 2'b00; m_ndl = dl;
            m_dfirst = o_dv && !o_dhs && !pdrs;
            v_dl_n[dl] = 1;
            if (!in) begin m_ev[0] = 1; v_rng_wr = 1; end
            else begin
              c_wv = 1; c_wln = ln; c_wop = op; c_wpo = po; c_wd = d[63:0];
              if (mbst != 0 && mbln == ln) v_wb_during_bi = 1;
              if (op == 4'd2 && be == 64'd0) v_be0 = 1;
              if (op == 4'd2 && be != 64'd0 && be != '1) v_be_part = 1;
              for (int k = 0; k < 64; k++)
                if (op == 4'd1 || be[k]) mline[ln][8 * k +: 8] = d[8 * k +: 8];
              if (op == 4'd1) begin
                if (po) v_po_set = 1; else if (mpo[ln]) v_po_clr = 1;
                mpo[ln] = po;
              end else begin
                if (mpo[ln] && !po) v_po_keep = 1;
                if (po) v_ptl_po = 1;
                mpo[ln] = mpo[ln] || po;
              end
              if (mf == 2'b00) begin
                if (bi_en && mmeta[ln] == 2'b00 && mv != 2'b00 && msf >= SFE) begin
                  mv = 2'b00; v_rwd_sf_full = 1;
                end
                msf = msf + int'(mv != 2'b00) - int'(mmeta[ln] != 2'b00);
                mmeta[ln] = mv; v_meta_set[mv] = 1;
              end
            end
          end
        end
        void'(w_s2.pop_front()); void'(w_tag.pop_front()); void'(w_addr.pop_front());
      end
      if (gen) begin c_txu = k_unit; c_txj = b; c_txf = dat ? 15 : m_td[3:0]; end
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx, tx_valid == m_tv && tx_data == m_td)
  `SVA_INV(a_io_tx_ready, io_tx_ready == k_iotr)
  `SVA_INV(a_io_rx, io_rx_valid == k_iov && (!k_iov || io_rx_data == k_iod && io_rx_last == (mirw == 29)))
  `SVA_INV(a_bi_ready, bi_ready == k_bi_ready)
  `SVA_INV(a_bi_done, bi_done == mdone && bi_state == mdst)
  `SVA_INV(a_sf_cnt, int'(sf_cnt) == msf)
  `SVA_INV(a_events, {ev_range, ev_opcode, ev_proto, ev_poison, ev_crc, ev_seq, ev_fmt, ev_ovf} ==
                     {m_ev[0], m_ev[1], m_ev[2], m_ev[3], m_ev[4], m_ev[5], m_ev[6], m_ev[7]})
  `SVA_RST(a_reset, 1'b1, !tx_valid && !io_rx_valid && !bi_ready && !bi_done && sf_cnt == '0 &&
                          {ev_range, ev_opcode, ev_proto, ev_poison, ev_crc, ev_seq, ev_fmt, ev_ovf} == 8'd0)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [63:0] v);
    return v == 64'd0 ? 0 : v == '1 ? 1 : (v == {32{2'b01}} || v == {32{2'b10}}) ? 2 : 3;
  endfunction
  covergroup cg_cxl @(negedge clk);
    option.per_instance = 1;
    cp_qkind: coverpoint c_qop iff (rst_n && c_qv) { bins ndr = {1}; bins drs = {2}; }
    cp_qline: coverpoint c_qln iff (rst_n && c_qv) { bins l[] = {[0:LINES-1]}; }
    x_qline: cross cp_qkind, cp_qline;
    cp_qmeta: coverpoint c_mv iff (rst_n && c_qv) { bins m[] = {[0:3]}; }
    cp_wline: coverpoint c_wln iff (rst_n && c_wv) { bins l[] = {[0:LINES-1]}; }
    cp_wkind: coverpoint {c_wop[1:0], c_wpo} iff (rst_n && c_wv)
      { bins full = {3'b010}; bins full_poison = {3'b011}; bins partial = {3'b100}; bins partial_poison = {3'b101}; }
    cp_wdata: coverpoint dcls(c_wd) iff (rst_n && c_wv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(c_rd) iff (rst_n && c_dv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    // which unit of a CXL.cachemem flit carried what (received: 0 empty,
    // 1 Req, 2 RwD, 3 BIRsp, 14 byte enables, 15 data; sent: 0 empty, 4
    // NDR, 5 DRS, 6 BISnp, 15 data)
    cp_rx_empty: coverpoint c_rxj iff (rst_n && c_rxu && c_rxf == 0) { bins u[] = {[1:29]}; }
    cp_rx_req: coverpoint c_rxj iff (rst_n && c_rxu && c_rxf == 1) { bins u[] = {[1:29]}; }
    cp_rx_rwd: coverpoint c_rxj iff (rst_n && c_rxu && c_rxf == 2) { bins u[] = {2,4,6,8,10,12,14,16,18,20,22,24,26,28}; }
    cp_rx_birsp: coverpoint c_rxj iff (rst_n && c_rxu && c_rxf == 3) { bins u[] = {[1:29]}; }
    cp_rx_be: coverpoint c_rxj iff (rst_n && c_rxu && c_rxf == 14) { bins u[] = {3,5,7,9,11,13,15,17,19,21,23,25,27,29}; }
    cp_rx_data: coverpoint c_rxj iff (rst_n && c_rxu && c_rxf == 15) { bins u[] = {[2:29]}; }
    cp_tx_empty: coverpoint c_txj iff (rst_n && c_txu && c_txf == 0) { bins u[] = {[1:29]}; }
    cp_tx_ndr: coverpoint c_txj iff (rst_n && c_txu && c_txf == 4) { bins u[] = {[1:29]}; }
    cp_tx_drs: coverpoint c_txj iff (rst_n && c_txu && c_txf == 5) { bins u[] = {[1:29]}; }
    // a BISnp's unit depends only on what the packer had before it: the H
    // slot, the first or second unit of a G slot, the last slot
    cp_tx_bisnp: coverpoint c_txj iff (rst_n && c_txu && c_txf == 6) {
      bins h = {1};
      bins g_first = {2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26};
      bins g_second = {3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27};
      bins last_first = {28};
      bins last_second = {29};
    }
    cp_tx_data: coverpoint c_txj iff (rst_n && c_txu && c_txf == 15) { bins u[] = {[2:29]}; }
    cp_sf: coverpoint c_sf iff (rst_n) { bins n[] = {[0:SFE]}; bins over = {[SFE+1:LINES]}; }
  endgroup
  cg_cxl u_cg_cxl = new;

  `FC(req_meminv, v_op[0])
  `FC(req_memrd, v_op[1])
  `FC(req_memrddata, v_op[2])
  `FC(req_memrdfwd_dropped, v_op[3])
  `FC(req_memwrfwd_dropped, v_op[4])
  `FC(req_memspecrd, v_op[8])
  `FC(req_meminvnt, v_op[9])
  `FC(req_memclnevct, v_op[10])
  `FC(req_reserved_dropped, v_op[15])
  `FC(rwd_memwr, v_wop[1])
  `FC(rwd_memwrptl, v_wop[2])
  `FC(rwd_reserved_dropped, v_wop[15])
  `FC(ndr_cmp, v_cmp[0])
  `FC(ndr_cmp_s, v_cmp[1])
  `FC(ndr_cmp_e, v_cmp[2])
  `FC(ndr_biconflictack, v_cmp[4])
  `FC(meta_set_invalid, v_meta_set[0])
  `FC(meta_set_reserved, v_meta_set[1])
  `FC(meta_set_any, v_meta_set[2])
  `FC(meta_set_shared, v_meta_set[3])
  `FC(memrddata_meta0_ignored, v_rddata_meta)
  `FC(range_read, v_rng_rd)
  `FC(range_write, v_rng_wr)
  `FC(range_inv, v_rng_inv)
  `FC(range_specrd, v_spec_out)
  `FC(range_wraps, v_wrap)
  `FC(poison_read, v_poi_rd)
  `FC(poison_set_full, v_po_set)
  `FC(poison_clear_full, v_po_clr)
  `FC(poison_kept_partial, v_po_keep)
  `FC(poison_set_partial, v_ptl_po)
  `FC(partial_no_bytes, v_be0)
  `FC(partial_some_bytes, v_be_part)
  `FC(reserved_meta_field, v_res_mf)
  `FC(reserved_snp_type, v_res_snp)
  `FC(devload_light_ndr, v_dl_n[0])
  `FC(devload_optimal_ndr, v_dl_n[1])
  `FC(devload_moderate_ndr, v_dl_n[2])
  `FC(devload_severe_ndr, v_dl_n[3])
  `FC(devload_light_drs, v_dl_d[0])
  `FC(devload_optimal_drs, v_dl_d[1])
  `FC(devload_moderate_drs, v_dl_d[2])
  `FC(devload_severe_drs, v_dl_d[3])
  `FC(tie_req_served, v_tie_q)
  `FC(tie_rwd_served, v_tie_w)
  `FC(req_waits_for_ndr, v_q_wait_n)
  `FC(req_waits_for_drs, v_q_wait_d)
  `FC(rwd_waits_for_ndr, v_w_wait)
  `FC(drs_back_to_back, v_drs_b2b)
  `FC(ndr_back_to_back, v_ndr_b2b)
  // link receive
  `FC(rx_nop_flit, v_rx_type[0])
  `FC(rx_io_flit, v_rx_type[1])
  `FC(rx_cachemem_flit, v_rx_type[2])
  `FC(rx_bad_crc, v_crc)
  `FC(rx_bad_crc_abandons_rwd, v_crc_abort)
  `FC(rx_bad_seq, v_seq)
  `FC(rx_reserved_type, v_fmt_type)
  `FC(rx_reserved_unit, v_fmt_code)
  `FC(rx_rwd_in_second_unit, v_fmt_odd)
  `FC(rx_req_overflow, v_ovf_req)
  `FC(rx_rwd_overflow, v_rwd_drop)
  `FC(rx_biconflict_overflow, v_bic_drop)
  `FC(rx_birsp_overflow, v_ovf_bir)
  `FC(rx_io_overflow, v_ovf_io)
  `FC(rx_data_rolls_over, v_rx_roll)
  `FC(rx_h_slot_while_data_owed, v_rx_hslot)
  `FC(rx_two_messages_in_a_slot, v_rx_two)
  `FC(rx_rwd_in_last_slot, v_rwd_last)
  `FC(rx_credits_15, v_crd15)
  `FC(rx_beat_gap, rst_n && !rx_valid && mrj != 0)
  // link transmit
  `FC(tx_nop_flit, v_tx_type[0])
  `FC(tx_io_flit, v_tx_type[1])
  `FC(tx_cachemem_flit, v_tx_type[2])
  `FC(tx_data_rolls_over, v_tx_roll)
  `FC(tx_h_slot_while_data_owed, v_tx_hslot)
  `FC(tx_two_messages_in_a_slot, v_tx_two)
  `FC(tx_drs_header_first_unit, v_drs_u0)
  `FC(tx_drs_header_second_unit, v_drs_u1)
  `FC(tx_ndr_waits_for_credit, v_crd_n)
  `FC(tx_drs_waits_for_credit, v_crd_d)
  `FC(tx_bisnp_waits_for_credit, v_crd_b)
  `FC(tx_io_waits_for_credit, v_crd_io)
  `FC(tx_io_beat_late, v_io_stall)
  `FC(tx_io_and_cachemem_io_first, v_alt_io)
  `FC(tx_io_and_cachemem_cm_first, v_alt_cm)
  `FC(tx_older_drs_first, v_d_first)
  `FC(tx_older_ndr_first, v_n_first)
  `FC(tx_bisnp_wins_tie, v_rr_bis)
  `FC(tx_response_wins_tie, v_rr_resp)
  `FC(tx_back_pressure, tx_valid && !tx_ready)
  `FC(tx_credit_saturates, v_sat)
  `FC(tx_all_credits_returned, v_crd_back)
  `FC(io_rx_back_pressure, io_rx_valid && !io_rx_ready)
  // HDM-DB
  `FC(bi_eviction, v_evict)
  `FC(bi_device_request_invalid_line, v_ext_imm)
  `FC(bi_device_bisnpcur, v_ext_op[0])
  `FC(bi_device_bisnpdata, v_ext_op[1])
  `FC(bi_device_bisnpinv, v_ext_op[2])
  `FC(bi_device_reserved_op, v_ext_op[3])
  `FC(bi_device_request_busy, v_ext_busy)
  `FC(birsp_inv_i, v_rsp[2][0])
  `FC(birsp_data_i, v_rsp[1][0])
  `FC(birsp_data_s, v_rsp[1][1])
  `FC(birsp_cur_i, v_rsp[0][0])
  `FC(birsp_cur_s, v_rsp[0][1])
  `FC(birsp_cur_e, v_rsp[0][2])
  `FC(birsp_illegal_inv, v_rsp_bad[2])
  `FC(birsp_illegal_data, v_rsp_bad[1])
  `FC(birsp_illegal_cur, v_rsp_bad[0])
  `FC(birsp_stale_tag, v_bir_stale)
  `FC(birsp_none_outstanding, v_bir_none)
  `FC(birsp_without_hdm_db, v_bir_hdmh)
  `FC(req_blocked_by_bisnp, v_req_blk)
  `FC(req_waits_for_eviction, v_ev_wait)
  `FC(rwd_left_invalid_filter_full, v_rwd_sf_full)
  `FC(biconflict_ack, v_bic)
  `FC(biconflict_without_hdm_db, v_bic_hdmh)
  `FC(snoop_filter_full, v_sf_full)
  `FC(write_back_during_bisnp, v_wb_during_bi)
  `FC(req_after_bisnp_line, v_req_after_bi)
  `FC(reset_mid_flit, v_rst_mid)
endmodule

bind CXL_top CXL_sva #(.LINES(LINES), .RQD(RQD), .WQD(WQD), .SFE(SFE), .IOD(IOD)) u_sva (.*);
