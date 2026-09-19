// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI DPI (Display Pixel Interface) transmitter -- parallel RGB video timing
// Implementation scope:
//   * Programmable timing generator: horizontal hfp/hsw/hbp/hact and vertical
//     vfp/vsw/vbp/vact in 8 x 16-bit registers (reg 0..7); frame FSM walks
//     front porch -> sync -> back porch -> active in both dimensions,
//     1 pixel per clk (pclk forwarded 1:1 from clk, all video outputs change
//     on the pclk rising edge)
//   * Outputs: pclk, hsync, vsync (active high), de, rgb[23:0]; pixel source
//     is the pixel[23:0] input, sampled in the active region
//   * Control register (reg 8): bit0 enable, bit1 shutdown (outputs forced
//     low, counters held), bit2 color_mode (18-bit color: 2 LSBs of each
//     channel masked)
//   * Enabling with any timing register == 0 is rejected and raises irq
//   * frame_cnt output increments at each vertical wrap; reg readback port
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module MIPI_DPI__Display_Pixel_Interface__top #(
  parameter int DW = 32,          // retained framework parameter (data width)
  parameter int AW = 32           // retained framework parameter (address width)
)(
  input  logic        clk,
  input  logic        rst_n,
  output logic        irq,
  // video interface
  output logic        pclk,
  output logic        hsync,
  output logic        vsync,
  output logic        de,
  output logic [23:0] rgb,
  input  logic [23:0] pixel,
  // register interface (16 x 16-bit)
  input  logic        reg_wr,
  input  logic [3:0]  reg_addr,
  input  logic [15:0] reg_wdata,
  output logic [15:0] reg_rdata,
  // status
  output logic [15:0] frame_cnt
);

  // ------------------------------------------------------------------
  // register file
  // ------------------------------------------------------------------
  logic [15:0] treg [0:7];        // 0 hfp, 1 hsw, 2 hbp, 3 hact,
                                  // 4 vfp, 5 vsw, 6 vbp, 7 vact
  logic [2:0]  ctrl;              // bit0 enable, bit1 shutdown, bit2 color_mode

  wire [15:0] hfp = treg[0], hsw = treg[1], hbp = treg[2], hact = treg[3];
  wire [15:0] vfp = treg[4], vsw = treg[5], vbp = treg[6], vact = treg[7];

  wire cfg_ok = (hfp != 0) && (hsw != 0) && (hbp != 0) && (hact != 0) &&
                (vfp != 0) && (vsw != 0) && (vbp != 0) && (vact != 0);

  // region boundaries
  wire [15:0] hs_start  = hfp;
  wire [15:0] hs_end    = hfp + hsw;
  wire [15:0] act_h_s   = hfp + hsw + hbp;
  wire [15:0] htotal    = hfp + hsw + hbp + hact;
  wire [15:0] vs_start  = vfp;
  wire [15:0] vs_end    = vfp + vsw;
  wire [15:0] act_v_s   = vfp + vsw + vbp;
  wire [15:0] vtotal    = vfp + vsw + vbp + vact;

  logic [15:0] hcnt, vcnt;

  wire hsync_n = (hcnt >= hs_start) && (hcnt < hs_end);
  wire vsync_n = (vcnt >= vs_start) && (vcnt < vs_end);
  wire act_n   = (hcnt >= act_h_s) && (hcnt < htotal) &&
                 (vcnt >= act_v_s) && (vcnt < vtotal);
  wire [23:0] pix_mask = ctrl[2] ? (pixel & 24'hFCFCFC) : pixel;

  // ------------------------------------------------------------------
  // sequential
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt      <= 16'h0;
      vcnt      <= 16'h0;
      hsync     <= 1'b0;
      vsync     <= 1'b0;
      de        <= 1'b0;
      rgb       <= 24'h0;
      ctrl      <= 3'b000;
      irq       <= 1'b0;
      frame_cnt <= 16'h0;
      for (int i = 0; i < 8; i++)
        treg[i] <= 16'h0;
    end else begin
      // ---------------- register write ----------------
      if (reg_wr) begin
        if (reg_addr < 4'd8) begin
          treg[reg_addr[2:0]] <= reg_wdata;
        end else if (reg_addr == 4'd8) begin
          if (reg_wdata[0] && !cfg_ok) begin
            irq <= 1'b1;          // invalid timing config: reject enable
          end else begin
            ctrl <= reg_wdata[2:0];
            irq  <= 1'b0;
          end
        end
      end

      // ---------------- timing generator ----------------
      if (!ctrl[0]) begin
        hcnt  <= 16'h0;
        vcnt  <= 16'h0;
        hsync <= 1'b0;
        vsync <= 1'b0;
        de    <= 1'b0;
        rgb   <= 24'h0;
      end else if (ctrl[1]) begin
        // shutdown: blank outputs, hold position
        hsync <= 1'b0;
        vsync <= 1'b0;
        de    <= 1'b0;
        rgb   <= 24'h0;
      end else begin
        hsync <= hsync_n;
        vsync <= vsync_n;
        de    <= act_n;
        rgb   <= act_n ? pix_mask : 24'h0;
        if (hcnt == htotal - 16'd1) begin
          hcnt <= 16'h0;
          if (vcnt == vtotal - 16'd1) begin
            vcnt      <= 16'h0;
            frame_cnt <= frame_cnt + 16'd1;
          end else begin
            vcnt <= vcnt + 16'd1;
          end
        end else begin
          hcnt <= hcnt + 16'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // readback + pclk forward
  // ------------------------------------------------------------------
  always @* begin
    case (reg_addr)
      4'd8:    reg_rdata = {13'h0, ctrl};
      4'd9:    reg_rdata = frame_cnt;
      4'd10:   reg_rdata = hcnt;
      4'd11:   reg_rdata = vcnt;
      default: reg_rdata = (reg_addr < 4'd8) ? treg[reg_addr[2:0]] : 16'h0;
    endcase
  end

  assign pclk = clk;   // 1 pixel per clk; outputs change on the pclk edge

endmodule
