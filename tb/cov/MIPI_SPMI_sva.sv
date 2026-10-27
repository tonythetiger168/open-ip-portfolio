// SPDX-License-Identifier: Apache-2.0
// MIPI SPMI slave: a pin-level model counts SCLK edges from each SSC,
// decodes the command / address / data frames into a shadow register file
// and predicts the slave's SDATA drive (write ACK, read frames with odd
// parity, bus park and release), irq and every register.
`include "cov_macros.svh"
module MIPI_SPMI_sva #(parameter logic [3:0] USID = 4'h5) (
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
  localparam int P_IDLE = 0, P_IN = 1, P_RD = 2, P_PARK = 3, P_ACK = 4;
  int          ph, n, nfr, nad, k, r;
  logic        arm, m_err, m_drv, m_val, is_rd, ack;
  logic [12:0] cmdf;
  logic [8:0]  fr;                    // current 9-bit frame
  logic [15:0] a;
  logic [7:0]  rb;
  logic [7:0]  m_mem [0:31];
  wire         ssc = arm && d[2:1] == 2'b10 && low && ph != P_RD && ph != P_PARK && ph != P_ACK;
  wire [12:0]  cf  = {cmdf[11:0], bit_in};
  wire [8:0]   ff  = {fr[7:0], bit_in};
  wire [7:0]   cc  = cf[8:1];
  wire         mine = cf[12:9] == USID, bc = cf[12:9] == 4'h0;
  wire [7:0]   rv  = a < 32 ? m_mem[a[4:0]] : 8'h00;

  // event strobes for coverage
  logic ev_reg0, ev_wr, ev_rd, ev_xw, ev_xr, ev_lw, ev_lr, ev_rst, ev_pwr, ev_cpar, ev_fpar;
  logic ev_unsup, ev_other, ev_abort, ev_xw_end, ev_xr_wrap, ev_a16_wrap, ev_mine, ev_bc, ev_ack;
  // covergroup samples: a register byte written / read (address, data)
  logic       c_wv, c_rv;
  logic [4:0] c_wa, c_ra;
  logic [7:0] c_wd, c_rd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= P_IDLE; n <= 0; nfr <= 0; nad <= 0; k <= 0; r <= 0; arm <= 0; m_err <= 0;
      m_drv <= 0; m_val <= 0; is_rd <= 0; ack <= 0; cmdf <= '0; fr <= '0; a <= '0; rb <= '0;
      for (int i = 0; i < 32; i++) m_mem[i] <= '0;
      {ev_reg0, ev_wr, ev_rd, ev_xw, ev_xr, ev_lw, ev_lr, ev_rst, ev_pwr, ev_cpar, ev_fpar} <= '0;
      {ev_unsup, ev_other, ev_abort, ev_xw_end, ev_xr_wrap, ev_a16_wrap, ev_mine, ev_bc, ev_ack} <= '0;
      c_wv <= 0; c_rv <= 0; c_wa <= 0; c_ra <= 0; c_wd <= 0; c_rd <= 0;
    end else begin
      c_wv <= 0; c_rv <= 0;
      {ev_reg0, ev_wr, ev_rd, ev_xw, ev_xr, ev_lw, ev_lr, ev_rst, ev_pwr, ev_cpar, ev_fpar} <= '0;
      {ev_unsup, ev_other, ev_abort, ev_xw_end, ev_xr_wrap, ev_a16_wrap, ev_ack} <= '0;
      if (!low) arm <= 0; else if (d[2:1] == 2'b01) arm <= 1;
      if (ssc) begin
        arm <= 0; ph <= P_IN; n <= 0; m_err <= 0; ev_abort <= ph != P_IDLE;
      end else if (ph == P_IN && fall) begin
        n <= n + 1;
        if (n < 13) cmdf <= cf;
        else fr <= ff;
        if (n == 12) begin                          // command frame done
          ev_mine <= mine; ev_bc <= bc; ack <= mine; ph <= P_IDLE; nad <= 0;
          if (^cf != 1'b1) begin m_err <= 1; ev_cpar <= 1; end
          else if (!(mine || bc)) ev_other <= 1;
          else if (cc[7]) begin
            m_mem[0] <= {1'b0, cc[6:0]}; ev_reg0 <= 1;
            if (mine) begin ph <= P_ACK; r <= 0; end
          end else if (cc[7:5] == 3'b010) begin
            a <= 16'(cc[4:0]); nfr <= 1; is_rd <= 0; ph <= P_IN; ev_wr <= 1;
          end else if (cc[7:5] == 3'b011) begin
            if (mine) begin a <= 16'(cc[4:0]); nfr <= 1; ph <= P_RD; r <= 0; ev_rd <= 1; end
            else ev_other <= 1;
          end else if (cc[7:4] == 4'b0000 || (cc[7:4] == 4'b0010 && mine)) begin
            nfr <= cc[3:0] + 1; nad <= 1; is_rd <= cc[5]; ph <= P_IN;
            ev_xw <= !cc[5]; ev_xr <= cc[5];
          end else if (cc[7:4] == 4'b0011 && (!cc[3] || mine)) begin
            nfr <= cc[2:0] + 1; nad <= 2; is_rd <= cc[3]; ph <= P_IN;
            ev_lw <= !cc[3]; ev_lr <= cc[3];
          end else if (cc[7:5] == 3'b001) ev_other <= 1;  // read for another slave
          else if (cc == 8'h10) begin
            for (int i = 0; i < 32; i++) m_mem[i] <= '0;
            ev_rst <= 1;
          end else if (cc >= 8'h11 && cc <= 8'h13) ev_pwr <= 1;
          else begin m_err <= 1; ev_unsup <= 1; end
        end else if (n > 12 && (n - 12) % 9 == 0) begin   // 9-bit frame done
          if (^ff != 1'b1) begin m_err <= 1; ph <= P_IDLE; ev_fpar <= 1; end
          else if (nad != 0) begin
            nad <= nad - 1;
            a <= {a[7:0], ff[8:1]};
            if (nad == 1) begin
              if (n == 21) a <= 16'(ff[8:1]);
              if (is_rd) begin ph <= P_RD; r <= 0; end
            end
          end else begin
            if (a < 32) begin m_mem[a[4:0]] <= ff[8:1]; c_wv <= 1; c_wa <= a[4:0]; c_wd <= ff[8:1]; end
            a <= a + 1;
            ev_a16_wrap <= a == 16'hFFFF;
            nfr <= nfr - 1;
            if (nfr == 1) begin
              ph <= ack ? P_ACK : P_IDLE; r <= 0; ev_xw_end <= a >= 31;
            end
          end
        end
      end else if (ph == P_ACK && rise) begin
        m_drv <= 1; r <= r + 1;
        if (r == 0) begin m_val <= 1; ev_ack <= 1; end
        else begin m_val <= 0; ph <= P_PARK; end
      end else if (ph == P_RD && rise) begin
        // rising 0 = master bus park; then 9 bits per frame; then slave park
        r <= r + 1;
        if (r == 0) begin rb <= rv; k <= 0; c_rv <= a < 32; c_ra <= a[4:0]; c_rd <= rv; end
        else if (k < 9) begin
          m_drv <= 1;
          m_val <= k < 8 ? rb[7 - k] : ~^rb;
          k <= k + 1;
          if (k == 8) begin a <= a + 1; ev_a16_wrap <= a == 16'hFFFF; end
        end else if (nfr > 1) begin
          nfr <= nfr - 1; rb <= rv; m_val <= rv[7]; k <= 1; ev_xr_wrap <= a >= 32;
          c_rv <= a < 32; c_ra <= a[4:0]; c_rd <= rv;
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

  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  // every register written and read, data classes both ways
  covergroup cg_spmi @(negedge clk);
    option.per_instance = 1;
    cp_wa: coverpoint c_wa iff (rst_n && c_wv) { bins r[] = {[0:31]}; }
    cp_wd: coverpoint dcls(c_wd) iff (rst_n && c_wv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_ra: coverpoint c_ra iff (rst_n && c_rv) { bins r[] = {[0:31]}; }
    cp_rd: coverpoint dcls(c_rd) iff (rst_n && c_rv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_spmi u_cg_spmi = new;

  `SVA_RST(a_reset_released, !rst_n, !drv_en && !irq)
  `SVA_INV(a_irq_model, irq == m_err)
  `SVA_INV(a_drive_enable_model, drv_en == m_drv)
  `SVA_IMP(a_drive_value_model, m_drv, sdata == m_val)
  `SVA_INV(a_regs_model, mem_ok)
  `SVA_NXT(a_ssc_clears_irq, ssc, !irq)
  `SVA_IMP(a_drive_only_when_owned, drv_en, ph == P_RD || ph == P_PARK || ph == P_ACK)

  `FC(reg0_write_own_acked, ev_reg0 && ev_mine)
  `FC(reg0_write_broadcast, ev_reg0 && ev_bc)
  `FC(reg_write_broadcast, ev_wr && ev_bc)
  `FC(reg_read, ev_rd)
  `FC(ext_write_broadcast, ev_xw && ev_bc)
  `FC(ext_write_16, ev_xw && nfr == 16)
  `FC(ext_read_16, ev_xr && nfr == 16)
  `FC(long_write_8, ev_lw && nfr == 8 && ev_mine)
  `FC(long_write_broadcast, ev_lw && ev_bc)
  `FC(long_read_8, ev_lr && nfr == 8)
  `FC(ext_write_past_file, ev_xw_end)
  `FC(ext_read_past_file, ev_xr_wrap)
  `FC(address_wraps_16bit, ev_a16_wrap)
  `FC(write_acked, ev_ack)
  `FC(read_frame_boundary, ph == P_RD && rise && k == 9 && nfr > 1)
  `FC(reset_command_own, ev_rst && ev_mine)
  `FC(reset_command_broadcast, ev_rst && ev_bc)
  `FC(power_command, ev_pwr)
  `FC(cmd_parity_error, ev_cpar)
  `FC(frame_parity_error, ev_fpar)
  `FC(unsupported_command, ev_unsup)
  `FC(other_slave_ignored, ev_other)
  `FC(ssc_aborts_sequence, ev_abort)
  `FC(sdata_pulse_not_ssc, arm && !low)
  `FC_RST(reset_while_driving_read, rst_n && drv_en && ph == P_RD ##1 !rst_n)
  `FC_RST(reset_while_driving_ack, rst_n && drv_en && ph == P_ACK ##1 !rst_n)
endmodule

bind MIPI_SPMI_top MIPI_SPMI_sva #(.USID(USID)) u_sva (.*);
