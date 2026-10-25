// SPDX-License-Identifier: Apache-2.0
// MIPI DPI timing generator: a reference model of the register file and
// the raster position (integer arithmetic, no 16-bit wrap) predicts
// hsync/vsync/de/rgb, frame_cnt, irq and the register readback.
`include "cov_macros.svh"
module MIPI_DPI__Display_Pixel_Interface__sva (
  input logic        clk, rst_n, irq, hsync, vsync, de, reg_wr,
  input logic [23:0] rgb, pixel,
  input logic [3:0]  reg_addr,
  input logic [15:0] reg_wdata, reg_rdata, frame_cnt
);
  `COV_CLOCKING(clk, !rst_n)

  int          t [0:7];
  logic [2:0]  m_ctrl;
  logic        m_irq, m_hs, m_vs, m_de;
  logic [23:0] m_rgb;
  int          x, y;
  logic [15:0] m_fc;
  wire  integer ht = t[0] + t[1] + t[2] + t[3], vt = t[4] + t[5] + t[6] + t[7];
  wire         ok = t[0] && t[1] && t[2] && t[3] && t[4] && t[5] && t[6] && t[7] &&
                    ht <= 65536 && vt <= 65536;
  wire         act = x >= t[0] + t[1] + t[2] && x < ht && y >= t[4] + t[5] + t[6] && y < vt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) t[i] <= 0;
      m_ctrl <= 0; m_irq <= 0; m_hs <= 0; m_vs <= 0; m_de <= 0; m_rgb <= 0;
      x <= 0; y <= 0; m_fc <= 0;
    end else begin
      if (reg_wr && reg_addr < 8) t[reg_addr] <= reg_wdata;
      if (reg_wr && reg_addr == 8) begin
        if (reg_wdata[0] && !ok) m_irq <= 1; else begin m_ctrl <= reg_wdata[2:0]; m_irq <= 0; end
      end
      if (!m_ctrl[0]) begin
        x <= 0; y <= 0; {m_hs, m_vs, m_de} <= 0; m_rgb <= 0;
      end else if (m_ctrl[1]) begin
        {m_hs, m_vs, m_de} <= 0; m_rgb <= 0;
      end else begin
        m_hs  <= x >= t[0] && x < t[0] + t[1];
        m_vs  <= y >= t[4] && y < t[4] + t[5];
        m_de  <= act;
        m_rgb <= act ? (m_ctrl[2] ? pixel & 24'hFCFCFC : pixel) : 0;
        if (x >= ht - 1) begin
          x <= 0;
          if (y >= vt - 1) begin y <= 0; m_fc <= m_fc + 1; end else y <= y + 1;
        end else x <= x + 1;
      end
    end
  end
  wire [15:0] m_rd = (reg_addr < 8) ? 16'(t[reg_addr]) : (reg_addr == 8) ? {13'h0, m_ctrl} :
                     (reg_addr == 9) ? m_fc : (reg_addr == 10) ? 16'(x) :
                     (reg_addr == 11) ? 16'(y) : 16'h0;

  `SVA_RST(a_reset_blank, !rst_n, !hsync && !vsync && !de && rgb == 0 && !irq && frame_cnt == 0)
  `SVA_INV(a_video_model, hsync == m_hs && vsync == m_vs && de == m_de && rgb == m_rgb)
  `SVA_INV(a_frame_cnt_model, frame_cnt == m_fc)
  `SVA_INV(a_irq_model, irq == m_irq)
  `SVA_INV(a_readback_model, reg_rdata == m_rd)
  `SVA_IMP(a_de_inside_frame, de, !hsync && !vsync)

  `FC(enable_rejected_zero_field, reg_wr && reg_addr == 8 && reg_wdata[0] && !ok && ht <= 65536 && vt <= 65536)
  `FC(enable_rejected_overflow, reg_wr && reg_addr == 8 && reg_wdata[0] && (ht > 65536 || vt > 65536))
  `FC(total_exactly_65536, m_ctrl[0] && (ht == 65536 || vt == 65536))
  `FC(shrink_wrap, m_ctrl[0] && !m_ctrl[1] && x > ht - 1)
  `FC(shutdown_hold, m_ctrl[0] && m_ctrl[1])
  `FC(color_mode_18bit, de && m_ctrl[2] && (pixel & 24'h030303) != 0)
  `FC(frame_wrap, m_ctrl[0] && !m_ctrl[1] && x >= ht - 1 && y >= vt - 1)
  `FC(write_read_only_addr, reg_wr && reg_addr > 8)
  `FC(read_unused_addr, reg_addr > 11)
  `FC_RST(reset_while_active, rst_n && de ##1 !rst_n)
endmodule

bind MIPI_DPI__Display_Pixel_Interface__top MIPI_DPI__Display_Pixel_Interface__sva u_sva (.*);
