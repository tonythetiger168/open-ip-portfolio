// SPDX-License-Identifier: Apache-2.0
// SoundWire manager / peripheral: concurrent SVA against an independent
// reference model, plus functional coverage.
//  * Bit timing: the manager's phase counter (edge at cfg_div, drive at
//    half of it), or the peripheral's two-flop CLOCK synchroniser (edge one
//    clock after a change is seen, drive one clock after that).
//  * Edge: the NRZI-decoded bit goes into a bit history (sync hunt at a
//    stride of the column count), the frame's control word, the command
//    fields, the sync check and the receive column; then the next bit's
//    owner and value are decided from the spec's slot table.
//  * Drive: the decided bit, from the level of the last bit.
// Every output is compared on every clock.
`include "cov_macros.svh"
module MIPI_SoundWire_sva (
  input logic        clk, rst_n, cfg_manager,
  input logic [4:0]  cfg_div,
  input logic [1:0]  cfg_cols,
  input logic [3:0]  cfg_dev, cfg_tx_col, cfg_rx_col,
  input logic        sw_clk_o, sw_clk_oe, sw_clk_i, sw_dat_o, sw_dat_oe, sw_dat_i,
  input logic        cmd_valid, cmd_ready,
  input logic [1:0]  cmd_op,
  input logic [3:0]  cmd_dev,
  input logic [15:0] cmd_addr,
  input logic [7:0]  cmd_wdata,
  input logic        rsp_valid, rsp_ack, rsp_nak,
  input logic [7:0]  rsp_rdata,
  input logic [15:0] ping_status,
  input logic [1:0]  dev_status,
  input logic        reg_we, reg_re,
  input logic [15:0] reg_addr,
  input logic [7:0]  reg_wdata, reg_rdata,
  input logic        tx_valid, tx_ready,
  input logic [31:0] tx_data,
  input logic        tx_underrun, rx_valid,
  input logic [31:0] rx_data,
  input logic        locked, lost_sync, par_err
);
  `COV_CLOCKING(clk, !rst_n)

  localparam int HUNT = 0, CHECK = 1, LOCK = 2;
  int          ph, st, rw, cl, nmiss;
  bit          mclk, cs0, cs1, cq, ep, dp, lvl, oe, do_, sok, prev_ok, busy, fh;
  bit          n_own, n_val, n_rd;
  int          n_ri;
  bit          hist [0:127];                 // hist[0] = newest decoded bit
  logic [47:0] rcv, mcw;
  logic [3:0]  ldyn, mdyn;
  logic [1:0]  q_op;
  logic [3:0]  q_dev;
  logic [15:0] q_addr;
  logic [7:0]  q_wd;
  logic [31:0] tsr, rsr;
  // registered outputs
  bit          m_rv, m_ack, m_nak, m_we, m_re, m_tr, m_tu, m_xv, m_lost, m_pe;
  logic [7:0]  m_rd, m_wd;
  logic [15:0] m_ps, m_ra;
  logic [31:0] m_xd;
  // coverage
  bit          v_check_fail, v_miss_ok, v_cmd_at_frame, v_rd_ack [1:15], v_wr_ack [1:15], v_ping_slot [1:8];
  bit          v_cols_tx [0:3], v_cols_rx [0:3], v_nak, v_absent, v_resv, v_div_odd, v_tx_lastcol;

  function automatic int ncol; return 2 << cfg_cols; endfunction
  function automatic bit col_ok(input logic [3:0] c); return c != 0 && int'(c) < ncol(); endfunction
  // 8-bit sync / 4-bit dynamic sync from the history: oldest bit is the MSB
  function automatic logic [7:0] strided8;
    logic [7:0] v;
    for (int i = 0; i < 8; i++) v[i] = hist[i * ncol()];
    return v;
  endfunction
  function automatic logic [3:0] strided4;
    logic [3:0] v;
    for (int i = 0; i < 4; i++) v[i] = hist[i * ncol()];
    return v;
  endfunction
  function automatic logic [3:0] lfsr(input logic [3:0] d); return {d[2:0], d[3] ^ d[2]}; endfunction
  function automatic bit par(input logic [47:0] w);
    return (^w[47:25]) ^ (w[45] ? ^w[24:17] : 1'b0);
  endfunction

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ph = 0; st = HUNT; rw = 47; cl = 0; nmiss = 0;
      {mclk, cs0, cs1, cq, ep, dp, lvl, oe, do_, sok, prev_ok, busy, fh, n_own, n_val, n_rd} = '0;
      n_ri = 0;
      for (int i = 0; i < 128; i++) hist[i] = 0;
      rcv = 0; mcw = 0; ldyn = 0; mdyn = 4'hF; q_op = 0; q_dev = 0; q_addr = 0; q_wd = 0; tsr = 0; rsr = 0;
      {m_rv, m_ack, m_nak, m_we, m_re, m_tr, m_tu, m_xv, m_lost, m_pe} = '0;
      m_rd = 0; m_wd = 0; m_ps = 0; m_ra = 0; m_xd = 0;
    end else begin : b_step
      bit e_now, d_now, was_busy;
      {m_rv, m_we, m_re, m_tr, m_tu, m_xv, m_lost, m_pe} = '0;
      was_busy = busy;
      // timing
      if (cfg_manager) begin
        e_now = ph == int'(cfg_div);
        d_now = ph == int'(cfg_div) / 2;
        ph = e_now ? 0 : (ph + 1) % 32;        // a 5-bit count
        if (e_now) mclk = !mclk;
      end else begin
        e_now = ep; d_now = dp; ph = 0;
      end
      dp = ep;
      ep = !cfg_manager && cs1 != cq;
      cq = cs1; cs1 = cs0; cs0 = sw_clk_i;
      if (cfg_manager) st = LOCK;
      if (cmd_valid && !busy) begin busy = 1; q_op = cmd_op; q_dev = cmd_dev; q_addr = cmd_addr; q_wd = cmd_wdata; end

      if (d_now) begin
        oe = n_own;
        if (n_own) do_ = lvl ^ (n_rd ? reg_rdata[n_ri] : n_val);
      end
      if (e_now) begin : b_edge
        bit b, hit, found;
        int ci, nr, nc, old_st;
        logic [47:0] w;
        b = sw_dat_i ^ lvl;
        lvl = sw_dat_i;
        oe = 0;
        old_st = st;
        for (int i = 127; i > 0; i--) hist[i] = hist[i - 1];
        hist[0] = b;
        ci = 47 - rw;
        if (cl == 0) rcv[ci] = b;
        w = rcv;
        // sync
        found = 0;
        if (!cfg_manager) begin
          if (st == HUNT) begin
            if (strided8() == 8'hB1) begin found = 1; st = CHECK; sok = 1; prev_ok = 0; nmiss = 0; end
          end else if (cl == 0 && ci == 6) sok = strided8() == 8'hB1;
          else if (cl == 0 && ci == 2) begin : b_dyn
            logic [3:0] d;
            d = strided4();
            hit = sok && (st != LOCK || d == lfsr(ldyn));
            ldyn = st != LOCK || hit ? d : lfsr(ldyn);
            if (st == CHECK) begin
              if (!sok) begin st = HUNT; v_check_fail = 1; end
              else if (prev_ok) st = LOCK;
              prev_ok = sok;
            end else if (hit) begin if (nmiss == 1) v_miss_ok = 1; nmiss = 0; end
            else if (nmiss == 0) nmiss = 1;
            else begin st = HUNT; m_lost = 1; nmiss = 0; prev_ok = 0; end
          end
        end
        // command fields
        if (cl == 0 && old_st != HUNT) begin
          if (!cfg_manager && old_st == LOCK && w[44:41] == cfg_dev) begin
            if (ci == 25 && w[47:45] == 3'b010) begin m_re = 1; m_ra = w[40:25]; end
            if (ci == 16 && w[47:46] == 2'b01) begin
              if (par(w) != w[16]) begin m_pe = 1; v_nak = 1; end
              else if (w[45]) begin m_we = 1; m_ra = w[40:25]; m_wd = w[24:17]; end
            end
          end
          if (cfg_manager && ci == 25 && w[47:45] == 3'b000) begin
            m_ps = w[40:25];
            for (int k = 1; k <= 8; k++) if (w[42 - 2 * k -: 2] != 0) v_ping_slot[k] = 1;
          end
          if (cfg_manager && ci == 14 && fh) begin
            m_rv = 1; m_ack = w[15]; m_nak = w[14]; m_rd = w[24:17];
            if (w[15] && w[47:45] == 3'b010) v_rd_ack[w[44:41]] = 1;
            if (w[15] && w[47:45] == 3'b011) v_wr_ack[w[44:41]] = 1;
            if (!w[15] && !w[14] && w[47:46] == 2'b01) v_absent = 1;
            if (w[47:45] == 3'b001) v_resv = 1;
          end
        end
        // receive column
        if (col_ok(cfg_rx_col) && cl == int'(cfg_rx_col) && rw < 32 && old_st == LOCK) begin
          rsr = {rsr[30:0], b};
          if (rw == 31) begin m_xv = 1; m_xd = rsr; v_cols_rx[cfg_cols] = 1; end
        end
        // next position
        if (found) begin nr = 41; nc = 1; end
        else if (cl == ncol() - 1) begin nc = 0; nr = (rw + 1) % 48; end
        else begin nc = (cl + 1) % 16; nr = rw; end      // a 4-bit count (the column count can shrink mid-row)
        rw = nr; cl = nc;
        if (rw == 0 && cl == 0) begin
          rcv = 0;
          if (cfg_manager) begin
            fh = was_busy;
            mdyn = lfsr(mdyn);
            mcw = 0;
            if (was_busy) begin
              mcw[46:45] = q_op; mcw[44:41] = q_dev; mcw[40:25] = q_addr;
              if (q_op == 3) mcw[24:17] = q_wd;
            end
            mcw[13:6] = 8'hB1; mcw[5:2] = mdyn;
            mcw[16] = par(mcw);
            if (was_busy) busy = 0;
            else if (busy) v_cmd_at_frame = 1;    // a command taken at the frame start waits
          end
        end
        // next bit: owner and value
        n_own = 0; n_val = 0; n_rd = 0; n_ri = 0;
        if (cl == 0) begin : b_ctl
          int ni;
          logic [47:0] v;
          ni = 47 - rw;
          v = cfg_manager ? mcw : rcv;
          if (cfg_manager) begin
            n_own = 1; n_val = v[ni];
            if (ni == 15 || ni == 14) n_own = 0;
            if (v[47:45] == 3'b010 && ni >= 17 && ni <= 24) n_own = 0;
            if (v[47:45] == 3'b000 && ni >= 25 && ni <= 40) n_own = 0;
          end else if (old_st == LOCK && v[44:41] == cfg_dev) begin
            if (v[47:45] == 3'b010 && ni >= 17 && ni <= 24) begin n_own = 1; n_rd = 1; n_ri = ni - 17; end
            if (v[47:46] == 2'b01 && ni == 15) begin n_own = 1; n_val = par(v) == v[16]; end
            if (v[47:46] == 2'b01 && ni == 14) begin n_own = 1; n_val = par(v) != v[16]; end
          end
          if (!cfg_manager && old_st == LOCK && v[47:45] == 3'b000 && cfg_dev >= 1 && cfg_dev <= 8 &&
              (ni == 42 - 2 * int'(cfg_dev) || ni == 41 - 2 * int'(cfg_dev))) begin
            n_own = 1; n_val = dev_status[ni - (41 - 2 * int'(cfg_dev))];
          end
        end else if (col_ok(cfg_tx_col) && cl == int'(cfg_tx_col) && rw < 32 && old_st == LOCK) begin
          if (rw == 0) begin
            tsr = tx_valid ? tx_data : 0;
            if (tx_valid) m_tr = 1; else m_tu = 1;
            v_cols_tx[cfg_cols] = 1;
            if (int'(cfg_tx_col) == ncol() - 1) v_tx_lastcol = 1;
          end
          n_own = 1; n_val = tsr[31]; tsr = tsr << 1;
        end
      end
      if (cfg_manager && cfg_div[0]) v_div_odd = 1;
    end

  // ---------------- assertions ----------------
  `SVA_INV(a_clk_oe, sw_clk_oe == cfg_manager)
  `SVA_IMP(a_clk, cfg_manager, sw_clk_o == mclk)
  `SVA_INV(a_dat_oe, sw_dat_oe == oe)
  `SVA_IMP(a_dat, oe, sw_dat_o == do_)
  `SVA_INV(a_cmd_ready, cmd_ready == !busy)
  `SVA_INV(a_rsp_valid, rsp_valid == m_rv)
  `SVA_IMP(a_rsp, m_rv, rsp_ack == m_ack && rsp_nak == m_nak && rsp_rdata == m_rd)
  `SVA_INV(a_ping, ping_status == m_ps)
  `SVA_INV(a_reg_re, reg_re == m_re && reg_we == m_we)
  `SVA_IMP(a_reg, m_re || m_we, reg_addr == m_ra && (!m_we || reg_wdata == m_wd))
  `SVA_INV(a_tx, tx_ready == m_tr && tx_underrun == m_tu)
  `SVA_INV(a_rx_valid, rx_valid == m_xv)
  `SVA_IMP(a_rx_data, m_xv, rx_data == m_xd)
  `SVA_INV(a_locked, locked == (st == LOCK))
  `SVA_INV(a_errs, lost_sync == m_lost && par_err == m_pe)
  `SVA_RST(a_reset, 1'b1, !sw_dat_oe && !locked && !rsp_valid && !tx_ready && !rx_valid && cmd_ready)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [31:0] v, input bit w32);
    logic [31:0] m;
    m = w32 ? '1 : 32'h0000_00FF;
    v &= m;
    return v == 0 ? 0 : v == m ? 1 : (v == (32'h5555_5555 & m) || v == (32'hAAAA_AAAA & m)) ? 2 : 3;
  endfunction
  // commands and responses (manager), command / read data, port samples
  covergroup cg_sdw @(negedge clk);
    option.per_instance = 1;
    cp_op: coverpoint cmd_op iff (rst_n && cfg_manager && cmd_valid && cmd_ready)
      { bins ping = {0}; bins reserved = {1}; bins read = {2}; bins write = {3}; }
    cp_rsp: coverpoint {rsp_ack, rsp_nak} iff (rst_n && cfg_manager && rsp_valid)
      { bins none = {2'b00}; bins ack = {2'b10}; bins nak = {2'b01}; }
    cp_wdata: coverpoint dcls({24'd0, cmd_wdata}, 0) iff (rst_n && cfg_manager && cmd_valid && cmd_ready && cmd_op == 3)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls({24'd0, rsp_rdata}, 0) iff (rst_n && cfg_manager && rsp_valid && rsp_ack && q_op == 2)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_tx: coverpoint dcls(tx_data, 1) iff (rst_n && tx_valid && tx_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rx: coverpoint dcls(rx_data, 1) iff (rst_n && rx_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_sdw u_cg_sdw = new;

  `FC(peripheral_lock, !cfg_manager && $rose(locked))
  `FC(check_fails, v_check_fail)
  `FC(one_miss_survived, v_miss_ok)
  `FC(lost_sync, lost_sync)
  `FC(read_ack_dev1, v_rd_ack[1])
  `FC(read_ack_dev5, v_rd_ack[5])
  `FC(write_ack_dev1, v_wr_ack[1])
  `FC(write_ack_dev5, v_wr_ack[5])
  `FC(absent_device, v_absent)
  `FC(reserved_op, v_resv)
  `FC(parity_nak, v_nak && cfg_manager == 1'b0)
  `FC(nak_seen, rsp_valid && rsp_nak)
  `FC(ping_dev1, v_ping_slot[1])
  `FC(ping_dev5, v_ping_slot[5])
  `FC(cmd_at_frame_start, v_cmd_at_frame)
  `FC(cmd_back_to_back, cfg_manager && cmd_valid && cmd_ready && fh)
  `FC(tx_cols2, v_cols_tx[0])
  `FC(tx_cols4, v_cols_tx[1])
  `FC(tx_cols8, v_cols_tx[2])
  `FC(tx_cols16, v_cols_tx[3])
  `FC(rx_cols2, v_cols_rx[0])
  `FC(rx_cols4, v_cols_rx[1])
  `FC(rx_cols8, v_cols_rx[2])
  `FC(rx_cols16, v_cols_rx[3])
  `FC(tx_last_column, v_tx_lastcol)
  `FC(underrun, tx_underrun)
  `FC(manager_rx, cfg_manager && rx_valid)
  `FC(peripheral_tx, !cfg_manager && tx_ready)
  `FC(odd_div, v_div_odd)
  `FC(slow_div, cfg_manager && cfg_div == 5'd31 && rsp_valid)
endmodule

bind MIPI_SoundWire_top MIPI_SoundWire_sva u_sva (.*);
