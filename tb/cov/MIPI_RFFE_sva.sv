// SPDX-License-Identifier: Apache-2.0
// MIPI RFFE slave: a pin-level model counts SCLK edges from each SSC,
// decodes the command / address / data frames into a shadow register file
// and predicts the slave's SDATA drive (read frames, odd parity, bus park
// and release), irq and every register.
`include "cov_macros.svh"
module MIPI_RFFE_sva #(parameter logic [3:0] USID = 4'h5) (
  input logic       clk, rst_n, sclk, sdata, irq, drv_en,
  input logic [7:0] mem [0:31]
);
  `COV_CLOCKING(clk, !rst_n)

  logic [2:0] c, d;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin c <= '0; d <= '0; end
    else begin c <= {c[1:0], sclk}; d <= {d[1:0], sdata}; end
  wire rise = c[2:1] == 2'b01, fall = c[2:1] == 2'b10, low = !c[1] && !c[2];
  wire bit_in = d[1];

  // sequence phases
  localparam int P_IDLE = 0, P_IN = 1, P_RD = 2, P_PARK = 3;
  int          ph, n, nfr, k, r;
  logic        arm, m_err, m_drv, m_val, is_rd, is_ext;
  logic [21:0] bits;                  // command + address, oldest first
  logic [8:0]  fr;                    // current 9-bit frame
  logic [7:0]  a, rb;
  logic [7:0]  m_mem [0:31];
  wire         ssc = arm && d[2:1] == 2'b10 && low && ph != P_RD && ph != P_PARK;
  wire [12:0]  cf  = {bits[11:0], bit_in};
  wire [7:0]   cc  = cf[8:1];
  wire         mine = cf[12:9] == USID, bc = cf[12:9] == 4'h0;
  wire [7:0]   rv  = a < 32 ? m_mem[a[4:0]] : 8'h00;

  // event strobes for coverage
  logic ev_reg0, ev_wr, ev_rd, ev_xw, ev_xr, ev_cpar, ev_fpar, ev_unsup, ev_other, ev_abort;
  logic ev_xw_end, ev_xr_wrap, ev_mine, ev_bc;
  // registered copies for the covergroup: command kind, extended length,
  // written / read bytes, parity-error frame and abort position
  logic       c_k, c_xv, c_wv, c_wext, c_rv, c_rext, c_pv, c_av;
  logic [3:0] c_kind;
  logic [2:0] c_xl, c_pos, c_apos;
  logic [4:0] c_wa;
  logic [7:0] c_wd, c_rd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= P_IDLE; n <= 0; nfr <= 0; k <= 0; r <= 0; arm <= 0; m_err <= 0;
      m_drv <= 0; m_val <= 0; is_rd <= 0; is_ext <= 0; bits <= '0; fr <= '0; a <= '0; rb <= '0;
      for (int i = 0; i < 32; i++) m_mem[i] <= '0;
      {ev_reg0, ev_wr, ev_rd, ev_xw, ev_xr, ev_cpar, ev_fpar, ev_unsup, ev_other, ev_abort} <= '0;
      {ev_xw_end, ev_xr_wrap, ev_mine, ev_bc} <= '0;
      {c_k, c_xv, c_wv, c_wext, c_rv, c_rext, c_pv, c_av} <= '0;
      c_kind <= 0; c_xl <= 0; c_pos <= 0; c_apos <= 0; c_wa <= 0; c_wd <= 0; c_rd <= 0;
    end else begin
      {ev_reg0, ev_wr, ev_rd, ev_xw, ev_xr, ev_cpar, ev_fpar, ev_unsup, ev_other, ev_abort} <= '0;
      {ev_xw_end, ev_xr_wrap} <= '0;
      {c_k, c_xv, c_wv, c_rv, c_pv, c_av} <= '0;
      if (!low) arm <= 0; else if (d[2:1] == 2'b01) arm <= 1;
      if (ssc) begin
        arm <= 0; ph <= P_IN; n <= 0; m_err <= 0; ev_abort <= ph != P_IDLE;
        c_av <= ph == P_IN; c_apos <= n < 13 ? 0 : (is_ext && n < 22 ? 1 : 2);
      end else if (ph == P_IN && fall) begin
        n <= n + 1;
        if (n < 13) bits <= {bits[20:0], bit_in};
        else fr <= {fr[7:0], bit_in};
        if (n == 12) begin                          // command frame done
          ev_mine <= mine; ev_bc <= bc;
          c_k <= 1;
          c_kind <= ^cf != 1'b1 ? 8 : (!(mine || bc) ? 9 : (cc[7] ? (mine ? 0 : 1) :
                    cc[7:5] == 3'b010 ? (mine ? 2 : 3) : (cc[7:5] == 3'b011 ? (mine ? 4 : 9) :
                    cc[7:4] == 4'b0000 ? (mine ? 5 : 6) : (cc[7:4] == 4'b0010 ? (mine ? 7 : 9) : 10))));
          c_xv <= ^cf == 1'b1 && (mine && cc[7:4] == 4'b0010 || (mine || bc) && cc[7:4] == 4'b0000);
          c_xl <= (cc[5] ? 3 : 0) + (cc[3:0] == 0 ? 0 : (cc[3:0] == 15 ? 2 : 1));
          if (^cf != 1'b1) begin m_err <= 1; ph <= P_IDLE; ev_cpar <= 1; end
          else if (!(mine || bc)) begin ph <= P_IDLE; ev_other <= 1; end
          else if (cc[7]) begin m_mem[0] <= {1'b0, cc[6:0]}; ph <= P_IDLE; ev_reg0 <= 1; end
          else if (cc[7:5] == 3'b010) begin a <= {3'b0, cc[4:0]}; nfr <= 1; is_ext <= 0; is_rd <= 0; ev_wr <= 1; end
          else if (cc[7:5] == 3'b011) begin
            if (mine) begin a <= {3'b0, cc[4:0]}; nfr <= 1; is_ext <= 0; ph <= P_RD; r <= 0; ev_rd <= 1; end
            else begin ph <= P_IDLE; ev_other <= 1; end
          end else if (cc[7:4] == 4'b0000) begin nfr <= cc[3:0] + 1; is_ext <= 1; is_rd <= 0; ev_xw <= 1; end
          else if (cc[7:4] == 4'b0010) begin
            if (mine) begin nfr <= cc[3:0] + 1; is_ext <= 1; is_rd <= 1; ev_xr <= 1; end
            else begin ph <= P_IDLE; ev_other <= 1; end
          end else begin m_err <= 1; ph <= P_IDLE; ev_unsup <= 1; end
        end else if (n > 12 && (n - 12) % 9 == 0) begin   // 9-bit frame done
          if (^{fr[7:0], bit_in} != 1'b1) begin
            m_err <= 1; ph <= P_IDLE; ev_fpar <= 1;
            c_pv <= 1; c_pos <= !is_ext ? 0 : (n == 21 ? (is_rd ? 2 : 1) : (n == 30 ? 3 : 4));
          end
          else if (is_ext && n == 21) begin
            a <= {fr[7:0], bit_in} >> 1;
            if (is_rd) begin ph <= P_RD; r <= 0; end
          end else begin
            if (a < 32) m_mem[a[4:0]] <= fr[7:0];
            c_wv <= a < 32; c_wa <= a[4:0]; c_wd <= fr[7:0]; c_wext <= is_ext;
            a <= a + 1;
            nfr <= nfr - 1;
            if (nfr == 1) begin ph <= P_IDLE; ev_xw_end <= is_ext && a >= 31; end
          end
        end
      end else if (ph == P_RD && rise) begin
        // rising 0 = master bus park; then 9 bits per frame; then slave park
        r <= r + 1;
        if (r == 0) begin rb <= rv; k <= 0; c_rv <= a < 32; c_rd <= rv; c_rext <= is_ext; end
        else if (k < 9) begin
          m_drv <= 1;
          m_val <= k < 8 ? rb[7 - k] : ~^rb;
          k <= k + 1;
          if (k == 8) a <= a + 1;
        end else if (nfr > 1) begin
          nfr <= nfr - 1; rb <= rv; m_val <= rv[7]; k <= 1; ev_xr_wrap <= a >= 32;
          c_rv <= a < 32; c_rd <= rv; c_rext <= 1;
        end else begin m_val <= 0; ph <= P_PARK; end
      end else if (ph == P_PARK && fall) begin
        m_drv <= 0; ph <= P_IDLE;
      end
    end
  end

  logic mem_ok;
  always_comb begin
    mem_ok = 1'b1;
    for (int i = 0; i < 32; i++) if (mem[i] != m_mem[i]) mem_ok = 1'b0;
  end

  `SVA_RST(a_reset_released, !rst_n, !drv_en && !irq)
  `SVA_INV(a_irq_model, irq == m_err)
  `SVA_INV(a_drive_enable_model, drv_en == m_drv)
  `SVA_IMP(a_drive_value_model, m_drv, sdata == m_val)
  `SVA_INV(a_regs_model, mem_ok)
  `SVA_NXT(a_ssc_clears_irq, ssc, !irq)
  `SVA_IMP(a_drive_only_in_read, drv_en, ph == P_RD || ph == P_PARK)

  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : (v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA ? 2 : 3));
  endfunction
  covergroup cg_slave @(negedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint c_kind iff (rst_n && c_k)
      { bins reg0_own = {0}; bins reg0_bc = {1}; bins wr_own = {2}; bins wr_bc = {3};
        bins rd_own = {4}; bins xw_own = {5}; bins xw_bc = {6}; bins xr_own = {7};
        bins cmd_parity = {8}; bins other_or_bc_read = {9}; bins unsupported = {10}; }
    cp_xlen: coverpoint c_xl iff (rst_n && c_xv)
      { bins w1 = {0}; bins w_mid = {1}; bins w16 = {2}; bins r1 = {3}; bins r_mid = {4}; bins r16 = {5}; }
    cp_waddr: coverpoint c_wa iff (rst_n && c_wv);
    cp_wdata: coverpoint int'(c_wext) * 4 + dcls(c_wd) iff (rst_n && c_wv)
      { bins short_[] = {[0:3]}; bins ext[] = {[4:7]}; }
    cp_rdata: coverpoint int'(c_rext) * 4 + dcls(c_rd) iff (rst_n && c_rv)
      { bins short_[] = {[0:3]}; bins ext[] = {[4:7]}; }
    cp_perr: coverpoint c_pos iff (rst_n && c_pv)
      { bins wr_data = {0}; bins xw_addr = {1}; bins xr_addr = {2}; bins xw_first = {3}; bins xw_later = {4}; }
    cp_abort: coverpoint c_apos iff (rst_n && c_av)
      { bins in_cmd = {0}; bins in_addr = {1}; bins in_data = {2}; }
  endgroup
  cg_slave u_cg_slave = new;

  `FC(reg0_write_own, ev_reg0 && ev_mine)
  `FC(reg0_write_broadcast, ev_reg0 && ev_bc)
  `FC(reg_write_own, ev_wr && ev_mine)
  `FC(reg_write_broadcast, ev_wr && ev_bc)
  `FC(reg_read, ev_rd)
  `FC(ext_write_broadcast, ev_xw && ev_bc)
  `FC(ext_write_16, ev_xw && nfr == 16)
  `FC(ext_read_16, ev_xr && nfr == 16)
  `FC(ext_write_past_file, ev_xw_end)
  `FC(ext_read_past_file, ev_xr_wrap)
  `FC(read_frame_boundary, ph == P_RD && rise && k == 9 && nfr > 1)
  `FC(cmd_parity_error, ev_cpar)
  `FC(frame_parity_error, ev_fpar)
  `FC(unsupported_command, ev_unsup)
  `FC(other_slave_ignored, ev_other)
  `FC(ssc_aborts_sequence, ev_abort)
  `FC(sdata_pulse_not_ssc, arm && !low)
  `FC_RST(reset_while_driving, rst_n && drv_en ##1 !rst_n)
endmodule

bind MIPI_RFFE_top MIPI_RFFE_sva #(.USID(USID)) u_sva (.*);
