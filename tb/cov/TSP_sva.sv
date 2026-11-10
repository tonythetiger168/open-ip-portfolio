// SPDX-License-Identifier: Apache-2.0
// TSP (transport stream processor: CISSA descrambling, PCR capture, PES /
// section routing): concurrent SVA against a packet-level model written
// from the header, fed by the configuration pins and the AXI4 read data,
// + functional coverage. For each packet the model collects the 47 words
// read, decides from the header (sync byte, PID against the slot table,
// transport_scrambling_control and the keys loaded, adaptation field) what
// the core must do, and checks: the read addresses (SRC_ADDR + 188 * i),
// SYNC / UNMATCHED / NOKEY / DESC / OVF counts and interrupts, the PCR
// fields, the destinations and addresses of the writes (A then B at
// OUTx_ADDR + 188 * x_CNT, none to a full buffer), every byte written that
// the descrambler does not touch (the header with its control bits cleared
// unless KEEP_TSC, the adaptation field, the residue under 16 bytes; the
// whole packet when it is not descrambled), A_CNT / B_CNT, DONE and ERR.
// The decrypted blocks themselves are checked by the testbench's own AES
// model; the AXI engine is closed by its own run.
`include "cov_macros.svh"
module TSP_sva (
  input logic        clk, rst_n,
  input logic        keep_tsc, pcr_en, start, key_load, slot_load, odd, slot_valid,
  input logic [12:0] pcr_pid, slot_pid,
  input logic [1:0]  slot, slot_route,
  input logic [31:0] src_addr, outa_addr, outb_addr,
  input logic [15:0] pkts, outa_max, outb_max,
  input logic        busy, key_busy, err, done, err_irq, nokey, sync, pcr, ovf,
  input logic [15:0] a_cnt, b_cnt, desc_cnt, nokey_cnt, sync_cnt, drop_cnt, ovf_cnt, pkt_cnt,
  input logic [31:0] pcr_base, pcr_local,
  input logic [9:0]  pcr_ext,
  input logic [31:0] m_awaddr, m_wdata, m_araddr, m_rdata,
  input logic [7:0]  m_awlen, m_arlen,
  input logic        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready,
  input logic        m_arvalid, m_arready, m_rvalid, m_rready,
  input logic [1:0]  m_bresp, m_rresp
);
  `COV_CLOCKING(clk, !rst_n)
  function automatic logic [15:0] sat(input logic [15:0] v); return v == 16'hFFFF ? v : v + 1; endfunction

  // slot table and keys
  logic [12:0] t_pid [4];
  logic [3:0]  t_val, k_ev, k_od;
  logic [1:0]  t_rt [4];
  logic [1:0]  kp_slot;
  logic        kp_odd, kp;
  // job and packet
  logic        j_on, j_err;
  logic [15:0] j_pi, j_a, j_b;
  logic [31:0] pw [47];
  int          rwi;                                // words of the packet read
  logic [31:0] m_clk, p_t0;
  logic [15:0] c_desc, c_nokey, c_sync, c_drop, c_ovf, c_pkt;
  int          n_sync_i, n_nokey_i, n_ovf_i, n_pcr_i, n_sync_e, n_nokey_e, n_ovf_e, n_pcr_e;
  logic [32:0] e_pcr_b;
  logic [8:0]  e_pcr_x;
  logic        e_pcr_v;
  // writes still expected: destination address and the packet image
  logic [31:0] wq_addr [$];
  logic [31:0] wq_img [$][47];
  logic [3:0]  wq_mask [$][47];                    // byte lanes to compare
  int          ar_w, aw_w, w_beats;                // words requested / written in the packet

  // decision on the packet just read (combinational on pw)
  wire  [7:0]  h_sync = pw[0][7:0];
  wire  [12:0] h_pid  = {pw[0][12:8], pw[0][23:16]};
  wire  [1:0]  h_tsc  = pw[0][31:30];
  wire  [1:0]  h_afc  = pw[0][29:28];
  wire  [7:0]  h_afl  = pw[1][7:0];
  wire         h_pcrf = h_afc[1] && h_afl >= 7 && pw[1][12];
  wire  [8:0]  h_pay  = (h_afc == 2'b01) ? 9'd4 : 9'd5 + 9'(h_afl);
  wire         h_has  = h_afc[0] && h_pay < 188;
  wire  [7:0]  h_nblk = h_has ? 8'((188 - h_pay) >> 4) : 8'd0;
  logic        h_hit;
  logic [1:0]  h_slot;
  always_comb begin
    h_hit = 0; h_slot = 0;
    for (int i = 3; i >= 0; i--) if (t_val[i] && t_pid[i] == h_pid) begin h_hit = 1; h_slot = 2'(i); end
  end
  wire         h_keyok = h_tsc[0] ? k_od[h_slot] : k_ev[h_slot];
  wire         h_ok    = h_sync == 8'h47;
  wire         h_desc  = h_ok && h_hit && h_tsc[1] && h_keyok;
  wire         h_nokey = h_ok && h_hit && h_tsc[1] && !h_keyok;
  wire         p_end   = m_rvalid && m_rready && j_on && rwi == 46;   // the packet's last word arrives
  wire         go      = start && !busy;
  logic        p_dec;                              // the clock after p_end: pw complete

  // the packet image written: descrambled bytes are not compared
  task automatic queue_write(input logic [31:0] a);
    logic [31:0] img [47];
    logic [3:0]  msk [47];
    for (int w = 0; w < 47; w++) begin img[w] = pw[w]; msk[w] = 4'hF; end
    if (h_desc) begin
      if (!keep_tsc) img[0][31:30] = 2'b00;
      for (int b = 0; b < 16 * h_nblk; b++) msk[(h_pay + b) / 4][(h_pay + b) % 4] = 1'b0;
    end
    wq_addr.push_back(a); wq_img.push_back(img); wq_mask.push_back(msk);
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin t_pid[i] <= 0; t_rt[i] <= 0; end
      t_val <= 0; k_ev <= 0; k_od <= 0; kp_slot <= 0; kp_odd <= 0; kp <= 0;
      j_on <= 0; j_err <= 0; j_pi <= 0; j_a <= 0; j_b <= 0; rwi <= 0; m_clk <= 0; p_t0 <= 0;
      c_desc <= 0; c_nokey <= 0; c_sync <= 0; c_drop <= 0; c_ovf <= 0; c_pkt <= 0;
      n_sync_i <= 0; n_nokey_i <= 0; n_ovf_i <= 0; n_pcr_i <= 0; n_sync_e <= 0; n_nokey_e <= 0; n_ovf_e <= 0; n_pcr_e <= 0;
      e_pcr_b <= 0; e_pcr_x <= 0; e_pcr_v <= 0; p_dec <= 0;
      wq_addr.delete(); wq_img.delete(); wq_mask.delete(); ar_w <= 0; aw_w <= 0; w_beats <= 0;
    end else begin
      m_clk <= m_clk + 1;
      p_dec <= p_end;
      // configuration
      if (slot_load) begin t_pid[slot] <= slot_pid; t_val[slot] <= slot_valid; t_rt[slot] <= slot_route; end
      if (key_load && !key_busy) begin
        kp <= 1; kp_slot <= slot; kp_odd <= odd;
        if (odd) k_od[slot] <= 0; else k_ev[slot] <= 0;
      end
      if (kp && $fell(key_busy)) begin
        kp <= 0;
        if (kp_odd) k_od[kp_slot] <= 1; else k_ev[kp_slot] <= 1;
      end
      // interrupts seen
      n_sync_i <= n_sync_i + sync; n_nokey_i <= n_nokey_i + nokey; n_ovf_i <= n_ovf_i + ovf; n_pcr_i <= n_pcr_i + pcr;
      // job
      if (go) begin j_on <= pkts != 0; j_err <= 0; j_pi <= 0; j_a <= 0; j_b <= 0; rwi <= 0; ar_w <= 0; end
      if ((m_rvalid && m_rready && m_rresp != 0) || (m_bvalid && m_bready && m_bresp != 0)) j_err <= 1;
      if (m_arvalid && m_arready) begin
        if (ar_w == 0) p_t0 <= m_clk;
        ar_w <= (ar_w + 32'(m_arlen) + 1 >= 47) ? 0 : ar_w + 32'(m_arlen) + 1;
      end
      if (m_rvalid && m_rready && j_on) begin
        pw[rwi] <= m_rdata;
        rwi <= (rwi == 46) ? 0 : rwi + 1;
      end
      // a packet decided (the clock after its last word: pw complete)
      if (p_dec) begin
        c_pkt <= sat(c_pkt);
        if (!h_ok) begin c_sync <= sat(c_sync); n_sync_e <= n_sync_e + 1; end
        else begin
          if (pcr_en && h_pid == pcr_pid && h_pcrf) begin
            e_pcr_v <= 1; n_pcr_e <= n_pcr_e + 1;
            e_pcr_b <= {pw[1][23:16], pw[1][31:24], pw[2][7:0], pw[2][15:8], pw[2][23]};
            e_pcr_x <= {pw[2][16], pw[2][31:24]};
          end
          if (!h_hit) c_drop <= sat(c_drop);
          else begin
            logic [15:0] a, b;
            if (h_nokey) begin c_nokey <= sat(c_nokey); n_nokey_e <= n_nokey_e + 1; end
            if (h_desc) c_desc <= sat(c_desc);
            a = j_a; b = j_b;
            if (t_rt[h_slot][0]) begin
              if (a < outa_max) begin queue_write(outa_addr + 32'(a) * 188); j_a <= a + 1; end
              else begin c_ovf <= sat(c_ovf); n_ovf_e <= n_ovf_e + 1; end
            end
            if (t_rt[h_slot][1]) begin
              if (b < outb_max) begin queue_write(outb_addr + 32'(b) * 188); j_b <= b + 1; end
              else begin c_ovf <= sat(c_ovf); n_ovf_e <= n_ovf_e + 1; end
            end
          end
        end
        j_pi <= j_pi + 1;
      end
      // writes
      if (m_awvalid && m_awready) aw_w <= aw_w + 32'(m_awlen) + 1;
      if (m_wvalid && m_wready) begin
        if (w_beats == 46) begin
          w_beats <= 0; aw_w <= 0;
          if (wq_addr.size() != 0) begin void'(wq_addr.pop_front()); void'(wq_img.pop_front()); void'(wq_mask.pop_front()); end
        end else w_beats <= w_beats + 1;
      end
      if (done) j_on <= 0;
    end
  end

  logic [31:0] w_exp, w_msk;
  always_comb begin
    w_exp = 0; w_msk = 0;
    if (wq_addr.size() != 0) begin
      w_exp = wq_img[0][w_beats];
      for (int b = 0; b < 4; b++) w_msk[8 * b +: 8] = {8{wq_mask[0][w_beats][b]}};
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !busy && !m_arvalid && !m_awvalid && a_cnt == 0 && b_cnt == 0 && pkt_cnt == 0
                                 && desc_cnt == 0 && sync_cnt == 0 && drop_cnt == 0 && ovf_cnt == 0 && !err)
  `SVA_NXT(a_start, go, busy || done)
  `SVA_NXT(a_key_busy, key_load && !key_busy, key_busy)
  `SVA_IMP(a_read_addr, m_arvalid && m_arready, m_araddr == src_addr + 32'(j_pi) * 188 + 32'(ar_w) * 4
                                                   && ar_w + 32'(m_arlen) + 1 <= 47)
  `SVA_IMP(a_write_addr, m_awvalid && m_awready, wq_addr.size() != 0 && m_awaddr == wq_addr[0] + 32'(aw_w) * 4
                                                   && aw_w + 32'(m_awlen) + 1 <= 47)
  `SVA_IMP(a_write_data, m_wvalid && m_wready, wq_addr.size() != 0 && ((m_wdata ^ w_exp) & w_msk) == 0)
  `SVA_IMP(a_counters, done || go, desc_cnt == c_desc && nokey_cnt == c_nokey && sync_cnt == c_sync && drop_cnt == c_drop
                                    && ovf_cnt == c_ovf && pkt_cnt == c_pkt)
  `SVA_IMP(a_pcr, pcr, e_pcr_v && pcr_base == e_pcr_b[31:0] && pcr_ext == {e_pcr_b[32], e_pcr_x})
  `SVA_IMP(a_pcr_local, pcr, pcr_local <= p_t0 && p_t0 - pcr_local < 32'd64)
  `SVA_IMP(a_done, done, !busy && j_pi == pkts && a_cnt == j_a && b_cnt == j_b && wq_addr.size() == 0
                         && err_irq == j_err && n_sync_i == n_sync_e && n_nokey_i == n_nokey_e && n_ovf_i == n_ovf_e
                         && n_pcr_i == n_pcr_e)
  `SVA_NXT(a_err, done && err_irq, err)

  covergroup cg_tsp @(posedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint (!h_ok ? 3'd0 : !h_hit ? 3'd1 : h_nokey ? 3'd2 : h_desc ? 3'd3 : 3'd4) iff (rst_n && p_dec)
      { bins sync_err = {0}; bins unmatched = {1}; bins nokey = {2}; bins descrambled = {3}; bins clear = {4}; }
    cp_tsc: coverpoint h_tsc iff (rst_n && p_dec && h_ok && h_hit);
    cp_afc: coverpoint h_afc iff (rst_n && p_dec && h_ok && h_hit);
    cp_slot: coverpoint h_slot iff (rst_n && p_dec && h_ok && h_hit);
    cp_route: coverpoint t_rt[h_slot] iff (rst_n && p_dec && h_ok && h_hit);
    cp_blocks: coverpoint h_nblk iff (rst_n && p_dec && h_desc)
      { bins none = {0}; bins one = {1}; bins some = {[2:10]}; bins all_ = {11}; }
    cp_full: coverpoint {t_rt[h_slot][1] && j_b >= outb_max, t_rt[h_slot][0] && j_a >= outa_max} iff (rst_n && p_dec && h_ok && h_hit);
    cp_pkts: coverpoint pkts iff (rst_n && go) { bins zero = {0}; bins one = {1}; bins few = {[2:255]}; bins many = {[256:16'hFFFF]}; }
    cx_kind_tsc: cross cp_tsc, cp_afc;
  endgroup
  cg_tsp u_cg_tsp = new;

  `FC(pcr_captured, pcr)
  `FC(key_load_while_busy, key_load && busy)
  `FC(start_during_key_expansion, go && key_busy)
  `FC(job_error, done && err_irq)
  `FC(keep_tsc_descrambled, p_dec && h_desc && keep_tsc)
  `FC(both_buffers_full, ovf && $past(ovf))
  `FC(counter_saturated, p_dec && pkt_cnt == 16'hFFFF)
  `FC_RST(reset_mid_job, rst_n && busy ##1 !rst_n)
endmodule

bind TSP_top TSP_sva u_sva (.*);
