// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// eCPRI over Ethernet node: a cycle-level model fed only by the pins predicts
// every output on every clock. The receiver collects whole frames and judges
// them at the end (address filter, ethertype, FCS over the collected bytes,
// 64-byte length, header and per-message payload shape); the message layer
// (IQ buffer, remote memory, reset, events, fault injection) and the
// transmitter (descriptor queue, complete 64-byte frame image with its own
// FCS, shifted out one byte per clock) are modelled at that level.
`include "cov_macros.svh"
module eCPRI_over_Ethernet_sva (
  input logic        clk, rst_n, rx_dv, tx_en, cpu_we, cpu_re, irq,
  input logic [7:0]  rx_d, tx_d,
  input logic [15:0] reset_op,
  input logic [3:0]  cpu_addr,
  input logic [31:0] cpu_wdata, cpu_rdata
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic [7:0] d);
    c ^= {24'h0, d};
    for (int i = 0; i < 8; i++) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    return c;
  endfunction

  // configuration / status
  logic [47:0] dm, sm, rsa;
  logic [4:0]  ir;                      // {concat, ovf, malf, type, fcs}
  logic [15:0] rop, lpc, lseq;
  logic        sv;
  logic [7:0]  gaps, okc, errc, lev, lesq;
  logic [2:0]  lety;
  // receiver
  logic [7:0]  fb [256];
  int          n;
  logic        o_dv;
  // IQ buffer / remote memory
  logic [31:0] iqm [32], mem [64];
  int          iwp, irp, icnt;
  // tx queue: payload image per entry (EVTIND gets its seq at send time)
  logic [7:0]  qp [4][12];
  logic [7:0]  qmt [4], qlen [4];
  logic        qind [4];
  int          qw, qr, qc;
  logic        ipend, aw;
  logic [20:0] ifw;
  logic [7:0]  iid, iseq, tseq;
  // transmitter
  logic        busy, m_en;
  logic [7:0]  m_d, txb [64];
  int          tk;
  // coverage events
  logic v_iq0, v_iq8, v_iqovf, v_iqpp, v_gap, v_newpc, v_memwr, v_memrd, v_mem_hi, v_mem_al,
        v_mem_rw, v_rst, v_rst_vend, v_rst_op, v_evt0, v_evt3, v_ackm, v_ackx, v_evt_rec,
        v_evt_ty, v_evt_nf, v_evt_ps, v_evt4, v_bcast, v_otherda, v_et, v_runt, v_fcs, v_short,
        v_long, v_psz, v_rev, v_conc, v_mt, v_qlost, v_injovf, v_injwait, v_injpush_same,
        v_b2b, v_clr_same, v_rst_clr;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  logic        c_mv;
  int          c_mk, c_nw, c_ma, c_et, c_nf;
  logic [31:0] c_dw;

  always @(posedge clk or negedge rst_n) begin
    logic        fend, pop_iq, qpop, mine, fcs, lenok, malf, known, ok, rpush, full, ipush, qpush;
    logic [7:0]  mt, p [40], rp [12], rmt, rlen;
    logic [15:0] ps;
    logic [31:0] c, ra;
    int          nw, avail, put;
    if (!rst_n) begin
      dm = 48'hAABB_CCDD_EEFF; sm = 48'h1122_3344_5566; rsa = 0;
      ir = 0; rop = 0; lpc = 0; lseq = 0; sv = 0; gaps = 0; okc = 0; errc = 0;
      lev = 0; lesq = 0; lety = 0; n = 0; o_dv = 0;
      iwp = 0; irp = 0; icnt = 0;
      for (int i = 0; i < 64; i++) mem[i] = 0;
      qw = 0; qr = 0; qc = 0; ipend = 0; aw = 0; ifw = 0; iid = 0; iseq = 0; tseq = 0;
      busy = 0; m_en = 0; m_d = 0; tk = 0;
      {v_iq0, v_iq8, v_iqovf, v_iqpp, v_gap, v_newpc, v_memwr, v_memrd, v_mem_hi, v_mem_al,
       v_mem_rw, v_rst, v_rst_vend, v_rst_op, v_evt0, v_evt3, v_ackm, v_ackx, v_evt_rec,
       v_evt_ty, v_evt_nf, v_evt_ps, v_evt4, v_bcast, v_otherda, v_et, v_runt, v_fcs, v_short,
       v_long, v_psz, v_rev, v_conc, v_mt, v_qlost, v_injovf, v_injwait, v_injpush_same,
       v_b2b, v_clr_same, v_rst_clr} = '0;
    end else begin
      {v_iq0, v_iq8, v_iqovf, v_iqpp, v_gap, v_newpc, v_memwr, v_memrd, v_mem_hi, v_mem_al,
       v_mem_rw, v_rst, v_rst_vend, v_rst_op, v_evt0, v_evt3, v_ackm, v_ackx, v_evt_rec,
       v_evt_ty, v_evt_nf, v_evt_ps, v_evt4, v_bcast, v_otherda, v_et, v_runt, v_fcs, v_short,
       v_long, v_psz, v_rev, v_conc, v_mt, v_qlost, v_injovf, v_injwait, v_injpush_same,
       v_b2b, v_clr_same, v_rst_clr} = '0;
      fend   = o_dv && !rx_dv;
      pop_iq = cpu_re && cpu_addr == 4'd4 && icnt != 0;
      qpop   = !busy && !m_en && qc != 0;
      // ---------------- cpu writes
      if (cpu_we) case (cpu_addr)
        4'd0: dm[31:0]  = cpu_wdata;
        4'd1: dm[47:32] = cpu_wdata[15:0];
        4'd2: sm[31:0]  = cpu_wdata;
        4'd3: sm[47:32] = cpu_wdata[15:0];
        4'd8: begin ir &= ~cpu_wdata[4:0]; v_clr_same = fend && cpu_wdata[4:0] != 0; end
        4'd9: if (cpu_wdata[0]) begin rop = 0; v_rst_clr = fend; end
        default: ;
      endcase
      if (pop_iq) irp = (irp + 1) % 32;
      // ---------------- received frame
      ok = 0; rpush = 0; mt = 0; ps = 0; ra = 0; put = 0;
      c_mv = 0;
      for (int i = 0; i < 40; i++) p[i] = 0;
      if (fend) begin
        mine = n >= 14 && {fb[12], fb[13]} == 16'hAEFE &&
               ({fb[0], fb[1], fb[2], fb[3], fb[4], fb[5]} == sm ||
                {fb[0], fb[1], fb[2], fb[3], fb[4], fb[5]} == 48'hFFFF_FFFF_FFFF);
        v_runt    = n < 14;
        v_et      = n >= 14 && {fb[12], fb[13]} != 16'hAEFE;
        v_otherda = n >= 14 && !mine && {fb[12], fb[13]} == 16'hAEFE;
        if (mine) begin
          v_bcast = {fb[0], fb[1]} == 16'hFFFF;
          c = 32'hFFFF_FFFF;
          for (int i = 0; i < n - 4; i++) c = crc32(c, fb[i]);
          fcs = ~c == {fb[n-1], fb[n-2], fb[n-3], fb[n-4]};
          mt  = fb[15];
          ps  = {fb[16], fb[17]};
          for (int i = 0; i < 40; i++) p[i] = fb[18 + i];
          ra  = {p[0], p[1], p[2], p[3]};
          lenok = n == 64 && ps <= 40;
          known = mt inside {8'd0, 8'd4, 8'd5, 8'd6};
          case (mt)
            8'd0: malf = ps < 4 || ps % 4 != 0 || ps > 36;
            8'd4: malf = !((ps == 5 && p[4] == 0) || (ps == 9 && p[4] == 1)) ||
                         ra >= 256 || ra % 4 != 0;
            8'd5: malf = ps < 3 || p[2] != 1;
            default: malf = p[3] > 4 || p[1] > 5 || ps != 4 + 8 * p[3];
          endcase
          if (!fcs) begin ir[0] = 1; v_fcs = 1; end
          else if (!lenok || fb[14][7:4] != 4'd1) begin
            ir[2] = 1; v_short = n < 64; v_long = n > 64; v_psz = n == 64 && ps > 40;
            v_rev = n == 64 && ps <= 40 && fb[14][7:4] != 4'd1;
          end
          else if (fb[14][0]) begin ir[4] = 1; v_conc = 1; end
          else if (!known) begin ir[1] = 1; v_mt = 1; end
          else if (malf) begin
            ir[2] = 1;
            v_mem_hi = mt == 4 && ra >= 256;
            v_mem_al = mt == 4 && ra < 256 && ra % 4 != 0;
            v_mem_rw = mt == 4 && ra < 256 && ra % 4 == 0;
            v_rst_op = mt == 5;
            v_evt_nf = mt == 6 && p[3] > 4;
            v_evt_ty = mt == 6 && p[3] <= 4 && p[1] > 5;
            v_evt_ps = mt == 6 && p[3] <= 4 && p[1] <= 5;
          end
          else ok = 1;
          if (ok) begin okc++; rsa = {fb[6], fb[7], fb[8], fb[9], fb[10], fb[11]}; end
          else errc++;
        end
      end
      if (ok) begin
        c_mv = 1; c_ma = ra / 4; c_et = p[1]; c_nf = p[3]; c_nw = ps / 4 - 1;
        c_mk = mt == 0 ? 0 : mt == 4 ? (p[4] == 1 ? 1 : 2) : mt == 5 ? 3 : 4;
        c_dw = mt == 0 ? {p[4], p[5], p[6], p[7]} : {p[5], p[6], p[7], p[8]};
      end
      if (ok) case (mt)
        8'd0: begin
          nw    = ps / 4 - 1;
          avail = 32 - icnt + pop_iq;
          put   = nw > avail ? avail : nw;
          for (int w = 0; w < put; w++)
            iqm[(iwp + w) % 32] = {p[4+4*w], p[5+4*w], p[6+4*w], p[7+4*w]};
          iwp = (iwp + put) % 32;
          if (nw > avail) begin ir[3] = 1; v_iqovf = 1; end
          v_iq0  = nw == 0;
          v_iq8  = nw == 8 && put == 8;
          v_iqpp = pop_iq && nw > 0;
          v_newpc = sv && {p[0], p[1]} != lpc;
          if (sv && {p[0], p[1]} == lpc && {p[2], p[3]} != lseq + 16'd1) begin
            gaps++; v_gap = 1;
          end
          lpc = {p[0], p[1]}; lseq = {p[2], p[3]}; sv = 1;
        end
        8'd4: if (p[4] == 1) begin
          mem[ra / 4] = {p[5], p[6], p[7], p[8]}; v_memwr = 1;
        end else begin
          rpush = 1; v_memrd = 1;
          rmt = 8'd4; rlen = 8'd9;
          rp = '{0, 0, 0, ra[7:0], 2, mem[ra/4][31:24], mem[ra/4][23:16], mem[ra/4][15:8],
                 mem[ra/4][7:0], 0, 0, 0};
        end
        8'd5: begin
          rop = {p[0], p[1]}; v_rst = 1; v_rst_vend = ps > 3;
          rpush = 1; rmt = 8'd5; rlen = 8'd3;
          rp = '{p[0], p[1], 2, 0, 0, 0, 0, 0, 0, 0, 0, 0};
        end
        default: begin
          v_evt_rec = p[1] inside {8'd2, 8'd4, 8'd5};
          v_evt4 = p[3] == 4;
          if (p[1] == 1) begin
            v_ackm = aw && p[0] == iid && p[2] == iseq;
            v_ackx = !(p[0] == iid && p[2] == iseq);
            if (p[0] == iid && p[2] == iseq) aw = 0;
          end
          lev = p[0]; lety = p[1][2:0]; lesq = p[2];
          if (p[1] == 0 || p[1] == 3) begin
            rpush = 1; rmt = 8'd6; rlen = 8'd4;
            v_evt0 = p[1] == 0; v_evt3 = p[1] == 3;
            rp = '{p[0], p[1] == 0 ? 8'd1 : 8'd4, p[2], 0, 0, 0, 0, 0, 0, 0, 0, 0};
          end
        end
      endcase
      // ---------------- transmitter (reads the queue before this edge's push)
      if (busy) begin
        if (tk < 64) begin m_d = txb[tk]; tk++; end
        else begin m_en = 0; busy = 0; end
      end else if (qpop) begin
        v_b2b = qc > 1;
        {txb[0], txb[1], txb[2], txb[3], txb[4], txb[5]}    = dm;
        {txb[6], txb[7], txb[8], txb[9], txb[10], txb[11]}  = sm;
        txb[12] = 8'hAE; txb[13] = 8'hFE; txb[14] = 8'h10;
        txb[15] = qmt[qr]; txb[16] = 0; txb[17] = qlen[qr];
        for (int i = 0; i < 42; i++) txb[18 + i] = (i < 12) ? qp[qr][i] : 8'h00;
        if (qind[qr]) begin
          txb[20] = tseq; iid = qp[qr][0]; iseq = tseq; tseq++; aw = 1;
        end
        c = 32'hFFFF_FFFF;
        for (int i = 0; i < 60; i++) c = crc32(c, txb[i]);
        {txb[63], txb[62], txb[61], txb[60]} = ~c;
        qr = (qr + 1) % 4;
        busy = 1; m_en = 1; m_d = txb[0]; tk = 1;
      end
      // ---------------- tx queue push (rx response first, then injection)
      full  = qc == 4 && !qpop;
      ipush = ipend && !rpush && !full;
      qpush = (rpush || ipend) && !full;
      if (rpush && !full) begin
        qp[qw] = rp; qmt[qw] = rmt; qlen[qw] = rlen; qind[qw] = 0; qw = (qw + 1) % 4;
      end else if (ipush) begin
        qp[qw] = '{ifw[7:0], 0, 0, 1, 8'hFF, 8'hFF, {3'b000, ifw[20:16]}, ifw[15:8], 0, 0, 0, 0};
        qmt[qw] = 8'd6; qlen[qw] = 8'd12; qind[qw] = 1; qw = (qw + 1) % 4;
      end
      v_injwait = ipend && rpush && !full;
      if (rpush && full) begin ir[3] = 1; v_qlost = 1; end
      if (cpu_we && cpu_addr == 4'd7) begin
        if (ipend && !ipush) begin ir[3] = 1; v_injovf = 1; end
        else begin ipend = 1; ifw = cpu_wdata[20:0]; v_injpush_same = ipush; end
      end else if (ipush) ipend = 0;
      qc = qc + qpush - qpop;
      icnt = icnt - pop_iq + put;
      // ---------------- receiver byte collection
      if (rx_dv) begin
        if (!o_dv) n = 0;
        if (n < 256) fb[n] = rx_d;
        n++;
      end
      o_dv = rx_dv;
    end
  end

  function automatic int dcls(input logic [31:0] v);
    return v == 32'd0 ? 0 : v == '1 ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  covergroup cg_ecpri @(negedge clk);
    option.per_instance = 1;
    cp_msg: coverpoint c_mk iff (rst_n && c_mv)
      { bins iq = {0}; bins mem_wr = {1}; bins mem_rd = {2}; bins reset = {3}; bins event_ = {4}; }
    cp_iqn: coverpoint c_nw iff (rst_n && c_mv && c_mk == 0) { bins n[] = {[0:8]}; }
    cp_iqd: coverpoint dcls(c_dw) iff (rst_n && c_mv && c_mk == 0 && c_nw > 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_mrw: coverpoint c_mk iff (rst_n && c_mv && (c_mk == 1 || c_mk == 2)) { bins wr = {1}; bins rd = {2}; }
    cp_madr: coverpoint c_ma iff (rst_n && c_mv && (c_mk == 1 || c_mk == 2))
      { bins first = {0}; bins mid = {[1:62]}; bins last = {63}; }
    x_mem: cross cp_mrw, cp_madr;
    cp_md: coverpoint dcls(c_dw) iff (rst_n && c_mv && c_mk == 1)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_evt: coverpoint c_et iff (rst_n && c_mv && c_mk == 4) { bins t[] = {[0:5]}; }
    cp_nf: coverpoint c_nf iff (rst_n && c_mv && c_mk == 4) { bins n[] = {[0:4]}; }
  endgroup
  cg_ecpri u_cg_ecpri = new;

  logic [31:0] m_rd;
  always_comb
    case (cpu_addr)
      4'd0:    m_rd = dm[31:0];
      4'd1:    m_rd = {16'h0, dm[47:32]};
      4'd2:    m_rd = sm[31:0];
      4'd3:    m_rd = {16'h0, sm[47:32]};
      4'd4:    m_rd = iqm[irp];
      4'd5:    m_rd = {errc, okc, gaps, 2'b00, 6'(icnt)};
      4'd6:    m_rd = {lpc, lseq};
      4'd7:    m_rd = {8'h0, lesq, 5'h0, lety, lev};
      4'd8:    m_rd = {27'h0, ir};
      4'd9:    m_rd = {16'h0, rop};
      4'd10:   m_rd = rsa[31:0];
      4'd11:   m_rd = {16'h0, rsa[47:32]};
      4'd12:   m_rd = {14'h0, aw, ipend, tseq, 5'h0, 3'(qc)};
      default: m_rd = 32'h0;
    endcase

  `SVA_RST(a_reset_outputs, !rst_n, !tx_en && !irq && reset_op == 16'h0)
  `SVA_INV(a_tx_en, tx_en == m_en)
  `SVA_IMP(a_tx_d, tx_en, tx_d == m_d)
  `SVA_INV(a_irq, irq == |ir)
  `SVA_INV(a_reset_op, reset_op == rop)
  // the IQ word at the read pointer is only defined while the buffer holds data
  `SVA_IMP(a_cpu_rdata, cpu_addr != 4'd4 || icnt != 0, cpu_rdata == m_rd)

  `FC(iq_no_words, v_iq0)
  `FC(iq_eight_words, v_iq8)
  `FC(iq_overflow, v_iqovf)
  `FC(iq_pop_during_push, v_iqpp)
  `FC(iq_seq_gap, v_gap)
  `FC(iq_new_pc_id, v_newpc)
  `FC(mem_write, v_memwr)
  `FC(mem_read, v_memrd)
  `FC(mem_addr_out_of_range, v_mem_hi)
  `FC(mem_addr_misaligned, v_mem_al)
  `FC(mem_bad_rw_or_size, v_mem_rw)
  `FC(reset_request, v_rst)
  `FC(reset_request_vendor_bytes, v_rst_vend)
  `FC(reset_bad_op, v_rst_op)
  `FC(event_fault_acked, v_evt0)
  `FC(event_sync_acked, v_evt3)
  `FC(event_ack_matches_injection, v_ackm)
  `FC(event_ack_no_match, v_ackx)
  `FC(event_recorded_only, v_evt_rec)
  `FC(event_four_elements, v_evt4)
  `FC(event_bad_type, v_evt_ty)
  `FC(event_too_many_elements, v_evt_nf)
  `FC(event_size_mismatch, v_evt_ps)
  `FC(rx_broadcast, v_bcast)
  `FC(rx_other_dmac_dropped, v_otherda)
  `FC(rx_other_ethertype_dropped, v_et)
  `FC(rx_runt_dropped, v_runt)
  `FC(rx_bad_fcs, v_fcs)
  `FC(rx_short_frame, v_short)
  `FC(rx_long_frame, v_long)
  `FC(rx_payload_size_too_big, v_psz)
  `FC(rx_bad_revision, v_rev)
  `FC(rx_concatenated, v_conc)
  `FC(rx_unknown_msgtype, v_mt)
  `FC(tx_queue_full_response_lost, v_qlost)
  `FC(injection_while_pending, v_injovf)
  `FC(injection_waits_for_response, v_injwait)
  `FC(injection_reload_on_push, v_injpush_same)
  `FC(tx_back_to_back, v_b2b)
  `FC(irq_clear_at_frame_end, v_clr_same)
  `FC(reset_op_clear_at_frame_end, v_rst_clr)
  `FC_RST(reset_while_transmitting, rst_n && tx_en ##1 !rst_n)
  `FC_RST(reset_while_receiving, rst_n && rx_dv ##1 !rst_n)
endmodule

bind eCPRI_over_Ethernet_top eCPRI_over_Ethernet_sva u_sva (.*);
