// SPDX-License-Identifier: Apache-2.0
// RFFE master: concurrent SVA against an independent reference model, plus
// functional coverage.
//  * A host command is expanded into a list of bus cells: master bits (the
//    command and address frames with their parity), data-frame slots
//    filled from the write stream when reached, the master's bus park,
//    read bits and the slave's bus park.
//  * A player walks the list one SCLK period per cell (half periods of
//    cfg_div + 1 PCLK), drives the expected SCLK / SDATA, holds SCLK low
//    while a data byte is missing, samples read bits through its own two
//    flops and rebuilds every read frame and its parity.
// Every output is compared on every clock.
`include "cov_macros.svh"
module RFFE_sva (
  input logic        clk, rst_n,
  input logic [3:0]  cfg_div,
  input logic        sclk, sdata_o, sdata_oe, sdata_i,
  input logic        cmd_valid, cmd_ready,
  input logic [2:0]  cmd_type,
  input logic [3:0]  cmd_sa,
  input logic [15:0] cmd_addr,
  input logic [3:0]  cmd_bc,
  input logic        wr_valid, wr_ready,
  input logic [7:0]  wr_data,
  input logic        rd_valid,
  input logic [7:0]  rd_data,
  input logic        rd_perr, done, done_perr, busy
);
  `COV_CLOCKING(clk, !rst_n)

  localparam int C_BP = 2, C_RD = 3, C_SP = 4, C_DATA = 5;   // cells; 0 / 1 are master bits
  localparam int P_IDLE = 0, P_SSC = 1, P_CELLS = 2, P_WAIT = 3, P_TAIL = 4;
  int          cells [0:400];
  int          n, ci, ph, t, halves, nrb;
  bit          m_sclk, m_oe, m_do, s0, s1, seq_perr;
  bit          m_wr, m_rv, m_rp, m_done, m_dp;
  logic [7:0]  m_rd;
  logic [8:0]  rf;
  // coverage
  bit          v_type [0:7], v_stall, v_stall_at_cmd, v_bc16, v_long8, v_perr, v_div15, v_rd_ok;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit          c_acc, c_sa0, c_wv, c_rv, c_rp, c_dn, c_dp;
  logic [2:0]  c_ty, l_ty;
  logic [3:0]  c_bc;
  logic [7:0]  c_wd, c_rd;

  function automatic void put_frame(input logic [7:0] d);
    for (int i = 7; i >= 0; i--) begin cells[n] = int'(d[i]); n++; end
    cells[n] = int'(~^d); n++;
  endfunction
  // the next cell is a data frame: take a byte, or wait for one
  function automatic void fetch;
    if (ci < n && cells[ci] == C_DATA) begin
      if (wr_valid) begin
        m_wr = 1; c_wd = wr_data;
        for (int i = 0; i < 8; i++) cells[ci + i] = int'(wr_data[7 - i]);
        cells[ci + 8] = int'(~^wr_data);
      end else ph = P_WAIT;
    end
  endfunction

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      n = 0; ci = 0; ph = P_IDLE; t = 0; halves = 0; nrb = 0;
      {m_sclk, m_oe, m_do, s0, s1, seq_perr, m_wr, m_rv, m_rp, m_done, m_dp} = '0;
      m_rd = 0; rf = 0;
      {c_acc, c_sa0, c_wv, c_rv, c_rp, c_dn, c_dp} = '0; c_ty = 0; l_ty = 0; c_bc = 0; c_wd = 0; c_rd = 0;
    end else begin : b_step
      bit tick, smp;
      int old_ph;
      {m_wr, m_rv, m_done} = '0;
      c_acc = 0;
      smp = s1;
      s1 = s0; s0 = sdata_i;
      old_ph = ph;
      tick = t == int'(cfg_div) && ph != P_IDLE && ph != P_WAIT;
      t = ph == P_IDLE || ph == P_WAIT || tick ? 0 : t + 1;
      case (old_ph)
        P_IDLE: if (cmd_valid) begin : b_cmd
          logic [7:0] c;
          int nd, nr;
          v_type[cmd_type] = 1;
          c_acc = 1; c_ty = cmd_type; l_ty = cmd_type; c_sa0 = cmd_sa == 0; c_bc = cmd_bc;
          if (cmd_type == 7) begin m_done = 1; m_dp = 0; end
          else begin
            case (cmd_type)
              0: c = {1'b1, cmd_addr[6:0]};
              1: c = {3'b010, cmd_addr[4:0]};
              2: c = {3'b011, cmd_addr[4:0]};
              3: c = {4'b0000, cmd_bc};
              4: c = {4'b0010, cmd_bc};
              5: c = {5'b00110, cmd_bc[2:0]};
              default: c = {5'b00111, cmd_bc[2:0]};
            endcase
            n = 0; ci = 0;
            for (int i = 3; i >= 0; i--) begin cells[n] = int'(cmd_sa[i]); n++; end
            put_frame(c);
            cells[n - 1] = int'(~^{cmd_sa, c});          // the command's parity covers SA too
            if (cmd_type >= 5) put_frame(cmd_addr[15:8]);
            if (cmd_type >= 3) put_frame(cmd_addr[7:0]);
            nd = cmd_type == 1 ? 1 : (cmd_type == 3 ? int'(cmd_bc) + 1 : (cmd_type == 5 ? int'(cmd_bc[2:0]) + 1 : 0));
            nr = cmd_type == 2 ? 1 : (cmd_type == 4 ? int'(cmd_bc) + 1 : (cmd_type == 6 ? int'(cmd_bc[2:0]) + 1 : 0));
            if (cmd_type == 3 && cmd_bc == 15) v_bc16 = 1;
            if (cmd_type >= 5 && cmd_bc[2:0] == 7) v_long8 = 1;
            for (int k = 0; k < nd; k++) for (int i = 0; i < 9; i++) begin cells[n] = C_DATA; n++; end
            cells[n] = C_BP; n++;
            for (int k = 0; k < nr * 9; k++) begin cells[n] = C_RD; n++; end
            if (nr > 0) begin cells[n] = C_SP; n++; end
            ph = P_SSC; halves = 0; m_oe = 1; m_do = 1; seq_perr = 0; nrb = 0;
          end
        end
        P_SSC: if (tick) begin
          halves++;
          if (halves == 2) m_do = 0;
          if (halves == 4) ph = P_CELLS;
        end
        P_WAIT: if (wr_valid) begin
          fetch();
          ph = P_CELLS;
        end
        P_CELLS: if (tick) begin
          if (!m_sclk) begin                     // rising edge
            m_sclk = 1;
            if (cells[ci] <= 1) m_do = cells[ci][0];
            else if (cells[ci] == C_BP) m_do = 0;
          end else begin                         // falling edge
            m_sclk = 0;
            if (cells[ci] == C_BP) m_oe = 0;
            if (cells[ci] == C_RD) begin
              rf = {rf[7:0], smp}; nrb++;
              if (nrb % 9 == 0) begin
                m_rv = 1; m_rd = rf[8:1]; m_rp = !(^rf);
                if (m_rp) begin seq_perr = 1; v_perr = 1; end else v_rd_ok = 1;
              end
            end
            ci++;
            if (ci == n) begin
              if (cells[ci - 1] == C_SP) ph = P_TAIL;
              else begin ph = P_IDLE; m_done = 1; m_dp = 0; end
            end else begin
              fetch();
              if (ph == P_WAIT) begin v_stall = 1; if (ci == 13) v_stall_at_cmd = 1; end
            end
          end
        end
        P_TAIL: if (tick) begin ph = P_IDLE; m_done = 1; m_dp = seq_perr; end
        default: ;
      endcase
      if (ph != P_IDLE && cfg_div == 15) v_div15 = 1;
      c_wv = m_wr; c_rv = m_rv; c_rd = m_rd; c_rp = m_rp; c_dn = m_done; c_dp = m_dp;
    end

  // ---------------- assertions ----------------
  `SVA_INV(a_ready, cmd_ready == (ph == P_IDLE) && busy == (ph != P_IDLE))
  `SVA_INV(a_sclk, sclk == m_sclk)
  `SVA_INV(a_oe, sdata_oe == m_oe)
  `SVA_IMP(a_sdata, m_oe, sdata_o == m_do)
  `SVA_INV(a_wr_ready, wr_ready == m_wr)
  `SVA_INV(a_rd_valid, rd_valid == m_rv)
  `SVA_IMP(a_rd, m_rv, rd_data == m_rd && rd_perr == m_rp)
  `SVA_INV(a_done, done == m_done)
  `SVA_IMP(a_done_perr, m_done, done_perr == m_dp)
  `SVA_RST(a_reset, 1'b1, !sclk && !sdata_oe && cmd_ready && !busy && !done && !rd_valid && !wr_ready)

  // ---------------- functional coverage ----------------
  // command type x unicast / broadcast, byte-count edges of the extended
  // and long types, write and read data classes per command type, read
  // parity errors and completion status per type
  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : (v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA ? 2 : 3));
  endfunction
  function automatic int ext_idx(input logic [2:0] ty, input logic [3:0] bc);
    int c;
    if (ty <= 4) c = bc == 0 ? 0 : (bc == 15 ? 2 : 1);
    else c = bc[2:0] == 0 ? 0 : (bc[2:0] == 7 ? 2 : 1);
    return (int'(ty) - 3) * 3 + c;
  endfunction
  function automatic int ty3(input logic [2:0] ty);   // 1 / 2 short, 3 / 4 extended, 5 / 6 long
    return ty <= 2 ? 0 : (ty <= 4 ? 1 : 2);
  endfunction
  covergroup cg_seq @(negedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint {c_ty, c_sa0} iff (rst_n && c_acc)
      { bins k[] = {[0:13]}; bins reserved = {14, 15}; }
    cp_ext: coverpoint ext_idx(c_ty, c_bc) iff (rst_n && c_acc && c_ty >= 3 && c_ty <= 6)
      { bins e[] = {[0:11]}; }
    cp_wdata: coverpoint ty3(l_ty) * 4 + dcls(c_wd) iff (rst_n && c_wv)
      { bins w[] = {[0:11]}; }
    cp_rdata: coverpoint ty3(l_ty) * 4 + dcls(c_rd) iff (rst_n && c_rv && !c_rp)
      { bins r[] = {[0:11]}; }
    cp_rperr: coverpoint ty3(l_ty) iff (rst_n && c_rv && c_rp)
      { bins p[] = {[0:2]}; }
    cp_done: coverpoint {l_ty, c_dp} iff (rst_n && c_dn)
      { bins ok[] = {0, 2, 4, 6, 8, 10, 12, 14}; bins perr[] = {5, 9, 13}; }
  endgroup
  cg_seq u_cg_seq = new;
  `FC(reg0_write, v_type[0])
  `FC(reg_write, v_type[1])
  `FC(reg_read, v_type[2])
  `FC(ext_write, v_type[3])
  `FC(ext_read, v_type[4])
  `FC(ext_long_write, v_type[5])
  `FC(ext_long_read, v_type[6])
  `FC(reserved_type, v_type[7])
  `FC(ext_16_bytes, v_bc16)
  `FC(long_8_bytes, v_long8)
  `FC(write_stall, v_stall)
  `FC(stall_after_command, v_stall_at_cmd)
  `FC(read_ok, v_rd_ok)
  `FC(read_parity_error, v_perr)
  `FC(done_with_error, done && done_perr)
  `FC(slow_bus, v_div15)
  `FC(fast_bus, sclk && cfg_div == 4'd7)
  `FC(back_to_back, cmd_valid && cmd_ready && $past(done))
endmodule

bind RFFE_top RFFE_sva u_sva (.*);
