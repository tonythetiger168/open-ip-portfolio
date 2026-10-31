// SPDX-License-Identifier: Apache-2.0
// UniPro-Mem: a symbol-level model. It deframes rx_sym on its own (ESC_DL /
// COF, escapes, CRC16), executes each good frame against a shadow memory
// and attribute file, keeps the two traffic-class response slots with
// their read-response timers and the NAC retransmit buffer, and builds
// every outgoing frame as a list of line symbols (with escapes and CRC).
// It predicts tx_valid / tx_sym on every clock, irq, the memory and the
// attribute registers.
`include "cov_macros.svh"
module UniPro_Mem_sva (
  input logic        clk, rst_n, rx_valid, tx_valid, tx_ready, irq,
  input logic [7:0]  rx_sym, tx_sym,
  input logic [31:0] mem [0:63],
  input logic [7:0]  attr [0:15]
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [7:0] ESC = 8'h9D, COF = 8'hC0;

  function automatic logic [15:0] crc(input logic [15:0] c, input logic [7:0] d);
    c ^= {d, 8'h00};
    for (int i = 0; i < 8; i++) c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
    return c;
  endfunction

  typedef struct packed {
    logic        v, rd, tc;
    logic [3:0]  cp, sq;
    logic [7:0]  len, tmr;
    logic [127:0] pay;
  } slot_t;

  logic [31:0] sm [0:63];
  logic [7:0]  sa [0:15];
  slot_t       q [0:1];
  slot_t       rb;
  logic        rb_p;
  logic [1:0]  rb_n;
  logic [3:0]  seq;
  // receiver
  int          rs;                 // 0 hunt, 1 after ESC, 2 frame, 3 discard
  logic        esc;
  int          nb;
  logic [7:0]  fb [0:20];
  logic        m_irq;
  // transmitter
  logic        tv;
  logic [7:0]  ts [0:47];
  int          tn, ti;

  // covergroup samples (one cycle after the event)
  function automatic int dcls(input logic [31:0] v);
    dcls = v == 0 ? 0 : v == 32'hFFFF_FFFF ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  int c_mk, c_ml, c_ma, c_md, c_ak, c_ai, c_ad, c_rt, c_rk;
  // coverage strobes
  logic vwr, vrd, vget, vset, vnac, vnacx, vnacmiss, vcrc, voob_w, voob_r, voob_a, vbad, vlong, vdrop,
        vtmo, vqos, vretx, vesc, vabort, vshortmem, vpacpshort, vwr3, vrd3;

  // one-shot build of the symbol list for a slot
  task automatic build(input slot_t f);
    logic [7:0] by [0:20];
    logic [15:0] c;
    int n, k;
    c = 16'hFFFF;
    by[0] = {3'b000, f.tc, f.cp}; by[1] = {4'h0, f.sq}; by[2] = f.len;
    for (int i = 0; i < 16; i++) by[3 + i] = f.pay[127 - 8 * i -: 8];
    n = 3 + int'(f.len);
    for (int i = 0; i < 19; i++) if (i < n) c = crc(c, by[i]);
    ts[0] <= ESC; ts[1] <= COF; k = 2;
    for (int i = 0; i < 21; i++) begin
      logic [7:0] b;
      if (i < n + 2) begin
        b = i < n ? by[i] : i == n ? c[15:8] : c[7:0];
        if (b == ESC || b == COF) begin ts[k] <= ESC; ts[k + 1] <= b ^ 8'h20; k += 2; vesc <= 1; end
        else begin ts[k] <= b; k++; end
      end
    end
    tn <= k; ti <= 0; tv <= 1;
  endtask

  // frame dispatch: returns the response (r.v = 0: none)
  function automatic slot_t respond(input int n);
    slot_t r;
    logic [7:0] op, a1, a2, a3;
    int len;
    logic [3:0] cp;
    r = '0; r.v = 1; r.tc = fb[0][4]; cp = fb[0][3:0]; r.cp = cp;
    len = fb[2]; op = fb[3]; a1 = fb[4]; a2 = fb[5]; a3 = fb[6];
    r.len = 2; r.pay = {8'hE0, 8'h03, 112'h0};
    if (cp == 4'h1) begin
      if (len >= 4 && (op == 8'h01 || op == 8'h02)) begin
        if ((a3 == 4 || a3 == 8 || a3 == 12) && a1 == 0 && a2[1:0] == 0 && int'(a2) + int'(a3) <= 256 &&
            len == (op == 8'h01 ? int'(a3) + 4 : 4)) begin
          if (op == 8'h01) begin r.len = 5; r.pay = {8'h81, a1, a2, a3, 8'h00, 88'h0}; end
          else begin
            r.len = a3 + 4; r.rd = 1;
            r.pay = {8'h82, a1, a2, a3, sm[a2[7:2]], sm[6'(a2[7:2] + 1)], sm[6'(a2[7:2] + 2)]};
          end
        end else r.pay = {8'hE0, 8'h02, 112'h0};
      end
    end else if (cp == 4'hF) begin
      if (op == 8'h10 || op == 8'h11) begin
        if (a1 >= 16) r.pay = {8'hE0, 8'h02, 112'h0};
        else if (op == 8'h10 && len >= 2) begin r.len = 3; r.pay = {8'h90, a1, sa[a1[3:0]], 104'h0}; end
        else if (op == 8'h11 && len >= 3) begin r.len = 3; r.pay = {8'h91, a1, a2, 104'h0}; end
      end else if (op == 8'h20) r.v = 0;
    end
    return r;
  endfunction

  wire ldx = !tv && rb_p;
  wire ld1 = !tv && !rb_p && q[1].v;
  wire ld0 = !tv && !rb_p && !q[1].v && q[0].v;
  wire [7:0] rb_ = esc ? rx_sym ^ 8'h20 : rx_sym;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 64; i++) sm[i] <= 0;
      for (int i = 0; i < 16; i++) sa[i] <= 0;
      q[0] <= '0; q[1] <= '0; rb <= '0; rb_p <= 0; rb_n <= 0; seq <= 0;
      rs <= 0; esc <= 0; nb <= 0; m_irq <= 0; tv <= 0; tn <= 0; ti <= 0;
      for (int i = 0; i < 48; i++) ts[i] <= 0;
      for (int i = 0; i < 21; i++) fb[i] <= 0;
      {vwr, vrd, vget, vset, vnac, vnacx, vnacmiss, vcrc, voob_w, voob_r, voob_a, vbad, vlong, vdrop,
       vtmo, vqos, vretx, vesc, vabort, vshortmem, vpacpshort, vwr3, vrd3} <= '0;
    end else begin
      slot_t r;
      logic go;
      {vwr, vrd, vget, vset, vnac, vnacx, vnacmiss, vcrc, voob_w, voob_r, voob_a, vbad, vlong, vdrop,
       vtmo, vqos, vretx, vesc, vabort, vshortmem, vpacpshort, vwr3, vrd3} <= '0;
      m_irq <= 0;
      go = 0; r = '0;
      c_mk <= -1; c_ak <= -1; c_rt <= -1;

      // transmitter
      if (tv) begin
        if (tx_ready) begin ti <= ti + 1; if (ti == tn - 1) tv <= 0; end
      end else if (ldx) begin build(rb); rb_p <= 0; vretx <= 1; end
      else if (ld1) begin build(q[1]); q[1].v <= 0; rb <= q[1]; rb_n <= 0; vqos <= q[0].v; end
      else if (ld0) begin build(q[0]); q[0].v <= 0; rb <= q[0]; rb_n <= 0; end

      // read-response timers
      for (int t = 0; t < 2; t++)
        if (q[t].v && q[t].rd && !(t == 1 ? ld1 : ld0)) begin
          if (q[t].tmr == 1) begin q[t].len <= 2; q[t].pay[127:112] <= {8'hE0, 8'h01}; q[t].rd <= 0; vtmo <= 1; end
          else q[t].tmr <= q[t].tmr - 1;
        end

      // receiver
      if (rx_valid) begin
        case (rs)
          0: if (rx_sym == ESC) rs <= 1;
          1: if (rx_sym == COF) begin rs <= 2; nb <= 0; esc <= 0; end
             else if (rx_sym != ESC) rs <= 0;
          default: begin
            if (!esc && rx_sym == ESC) esc <= 1;
            else if (esc && rx_sym == COF) begin rs <= 2; nb <= 0; esc <= 0; vabort <= rs == 2 && nb > 0; end
            else begin
              esc <= 0;
              if (rs == 2) begin
                fb[nb] <= rb_; nb <= nb + 1;
                if (nb == 2 && rb_ > 16) begin rs <= 3; vlong <= 1; end
                if (nb >= 3 && nb == int'(fb[2]) + 4) begin
                  logic [15:0] c;
                  c = 16'hFFFF;
                  for (int i = 0; i < 19; i++) if (i < int'(fb[2]) + 3) c = crc(c, fb[i]);
                  rs <= 0;
                  if (c != {fb[nb - 1], rb_}) begin m_irq <= 1; vcrc <= 1; end
                  else begin
                    logic [7:0] op, a1;
                    op = fb[3]; a1 = fb[4];
                    r = respond(nb);
                    go = r.v;
                    if (fb[0][3:0] == 4'h1) begin
                      if (fb[2] < 4) vshortmem <= 1;
                      else if (r.pay[127:120] == 8'hE0 && r.pay[119:112] == 8'h02) begin
                        m_irq <= 1; if (op == 8'h01) voob_w <= 1; else voob_r <= 1;
                      end else if (op == 8'h01 && r.pay[127:120] == 8'h81) begin
                        for (int i = 0; i < 3; i++)
                          if (i < int'(fb[6][7:2])) sm[6'(fb[5][7:2] + i)] <= {fb[7 + 4 * i], fb[8 + 4 * i], fb[9 + 4 * i], fb[10 + 4 * i]};
                        vwr <= 1; vwr3 <= fb[6] == 12;
                        c_mk <= 0; c_ml <= fb[6]; c_ma <= fb[5] == 0 ? 0 : int'(fb[5]) + int'(fb[6]) == 256 ? 2 : 1;
                        c_md <= dcls({fb[7], fb[8], fb[9], fb[10]});
                      end else if (op == 8'h02 && r.rd) begin
                        vrd <= 1; vrd3 <= fb[6] == 12;
                        c_mk <= 1; c_ml <= fb[6]; c_ma <= fb[5] == 0 ? 0 : int'(fb[5]) + int'(fb[6]) == 256 ? 2 : 1;
                        c_md <= dcls(sm[fb[5][7:2]]);
                      end
                      else vbad <= 1;
                    end else if (fb[0][3:0] == 4'hF) begin
                      if ((op == 8'h10 || op == 8'h11) && a1 >= 16) begin m_irq <= 1; voob_a <= 1; end
                      else if (op == 8'h11 && r.pay[127:120] == 8'h91) begin
                        sa[a1[3:0]] <= fb[5]; vset <= 1;
                        c_ak <= 1; c_ai <= a1[3:0]; c_ad <= dcls({4{fb[5]}});
                      end else if (op == 8'h10 && r.pay[127:120] == 8'h90) begin
                        vget <= 1; c_ak <= 0; c_ai <= a1[3:0]; c_ad <= dcls({4{sa[a1[3:0]]}});
                      end
                      else if (op == 8'h20) begin
                        vnac <= 1;
                        if (rb.v && rb.sq == a1[3:0]) begin
                          if (rb_n == 3) begin rb.v <= 0; m_irq <= 1; vnacx <= 1; end
                          else begin rb_p <= 1; rb_n <= rb_n + 1; end
                        end else vnacmiss <= 1;
                      end else begin vbad <= 1; vpacpshort <= op == 8'h10 || op == 8'h11; end
                    end else vbad <= 1;
                  end
                end
              end
            end
          end
        endcase
      end

      // enqueue
      if (go) begin
        if (r.tc ? (!q[1].v || ld1) : (!q[0].v || ld0)) begin
          r.sq = seq; r.tmr = 100;
          c_rt <= r.tc;
          case (r.pay[127:120])
            8'h81: c_rk <= 0; 8'h82: c_rk <= 1; 8'h90: c_rk <= 2; 8'h91: c_rk <= 3;
            default: c_rk <= r.pay[119:112] == 8'h02 ? 4 : 5;
          endcase
          q[r.tc] <= r;
          seq <= seq + 1;
        end else begin m_irq <= 1; vdrop <= 1; end
      end
    end
  end

  logic mem_ok;
  always_comb begin
    mem_ok = 1;
    for (int i = 0; i < 64; i++) if (mem[i] != sm[i]) mem_ok = 0;
    for (int i = 0; i < 16; i++) if (attr[i] != sa[i]) mem_ok = 0;
  end

  covergroup cg_unipro_mem @(negedge clk);
    cp_mkind: coverpoint c_mk iff (c_mk >= 0) { bins write = {0}; bins read = {1}; }
    cp_mlen: coverpoint c_ml iff (c_mk >= 0) { bins w1 = {4}; bins w2 = {8}; bins w3 = {12}; }
    cp_maddr: coverpoint c_ma iff (c_mk >= 0) { bins first = {0}; bins middle = {1}; bins last = {2}; }
    cp_mdata: coverpoint c_md iff (c_mk >= 0) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_mlen: cross cp_mkind, cp_mlen;
    x_maddr: cross cp_mkind, cp_maddr;
    x_mdata: cross cp_mkind, cp_mdata;
    cp_akind: coverpoint c_ak iff (c_ak >= 0) { bins get = {0}; bins set = {1}; }
    cp_aidx: coverpoint c_ai iff (c_ak >= 0) { bins i[] = {[0:15]}; }
    cp_adata: coverpoint c_ad iff (c_ak >= 0) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_attr: cross cp_akind, cp_adata;
    cp_rtc: coverpoint c_rt iff (c_rt >= 0) { bins tc[] = {[0:1]}; }
    cp_rkind: coverpoint c_rk iff (c_rt >= 0) { bins wr_ok = {0}; bins rd_data = {1}; bins get_rsp = {2}; bins set_cnf = {3};
                                                bins err_range = {4}; bins err_other = {5}; }
    x_rsp: cross cp_rtc, cp_rkind;
  endgroup
  cg_unipro_mem u_cg_unipro_mem = new();

  `SVA_RST(a_reset_state, !rst_n, !tx_valid && !irq)
  `SVA_INV(a_tx_valid, tx_valid == tv)
  `SVA_IMP(a_tx_sym, tv, tx_sym == ts[ti])
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_memory_and_attributes, mem_ok)

  `FC(mem_write, vwr)
  `FC(mem_write_3_words, vwr3)
  `FC(mem_read, vrd)
  `FC(mem_read_3_words, vrd3)
  `FC(pacp_get, vget)
  `FC(pacp_set, vset)
  `FC(nac_retransmit, vretx)
  `FC(nac_exhausted, vnacx)
  `FC(nac_unknown_seq, vnacmiss)
  `FC(crc_error, vcrc)
  `FC(oob_write, voob_w)
  `FC(oob_read, voob_r)
  `FC(oob_attribute, voob_a)
  `FC(bad_op_or_cport, vbad)
  `FC(mem_frame_too_short, vshortmem)
  `FC(pacp_frame_too_short, vpacpshort)
  `FC(oversized_frame_dropped, vlong)
  `FC(response_dropped_slot_busy, vdrop)
  `FC(read_response_timeout, vtmo)
  `FC(tc1_overtakes_tc0, vqos)
  `FC(escaped_symbol_sent, vesc)
  `FC(cof_restarts_frame, vabort)
  `FC(tx_backpressure, tv && !tx_ready)
  `FC_RST(reset_during_tx, rst_n && tv ##1 !rst_n)
endmodule

bind UniPro_Mem_top UniPro_Mem_sva u_sva (.*);
