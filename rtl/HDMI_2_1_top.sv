// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HDMI_2_1 protocol Open IP -- HDMI source (TMDS mode) educational slice:
//  full TMDS 8b/10b encode algorithm (transition minimisation with XOR/XNOR
//  selection + disparity tracking + DC-balance bits 8/9), 3 data channels +
//  TMDS clock channel (serial 1 bit/clk simplification), control period with
//  8-pixel video/data-island preambles and CTL0-3 codes (4 fixed 10-bit
//  codes), video period RGB888 active pixels on 3 channels, data island
//  period with TERC4 4b/10b encoding and packet structure (24-bit header +
//  4 subpackets x 56 bit, BCH ECC simplified to XOR parity - see comments),
//  AVI InfoFrame (type 0x82) sent once per frame, built-in 640x480@60
//  timing generator (hact=640 hfp=16 hsw=96 hbp=48 / vact=480 vfp=10
//  vsw=2 vbp=33).
// IP design implementation v1.0 -- Apache-2.0
// ----------------------------------------------------------------------------
// Documented simplifications (educational slice of the HDMI physical layer):
//  - Serialisation is 1 bit/clk per channel (real TMDS runs 10x pixel clk);
//    pixel period = 10 clk, all 3 channels + clock channel in lock-step,
//    TMDS bit0 transmitted first. TMDS clock channel = 10'b1111100000
//    repeated (LSB first).
//  - Pixel source is an internal demo generator: R=x[7:0], G=y[7:0],
//    B=x[7:0]^y[7:0]. Sync polarity is positive logic (VGA 640x480 uses
//    negative; documented deviation), encoded {VSYNC,HSYNC} on channel 0
//    control bits, CTL1:0 on channel 1, CTL3:2 on channel 2.
//  - Data island: once per frame at line y=VACT+1, pixels x=0..43:
//    8 px preamble (CTL3=CTL2=1), 2 px leading guard band, 32 px data,
//    2 px trailing guard band. Header = {type,ver,len} + 1 XOR-parity byte
//    (BCH(32,24) simplified to XOR parity, NOT real ECC). Each subpacket =
//    56 data bits + 8 XOR-parity bits (BCH(64,56) simplified, NOT real ECC).
//    Bit map per island pixel i (0..31), TERC4 4-bit inputs:
//      ch0 = {VSYNC, HSYNC, 1'b0, header[i]}
//      ch1 = {sp1[2i+1], sp1[2i], sp0[2i+1], sp0[2i]}
//      ch2 = {sp3[2i+1], sp3[2i], sp2[2i+1], sp2[2i]}
//  - AVI InfoFrame: type=0x82 ver=0x02 len=0x0D, PB1=0x10 (RGB, active
//    info), PB2=0x10 (4:3 picture aspect), PB4=VIC=0x01 (640x480p60),
//    checksum = two's complement of byte sum (real HDMI rule).
//  - hpd=0: TMDS outputs stop (all zero), timing restarts at (0,0) on
//    hpd return; irq = level "link was running and hpd was lost".
// ============================================================================
module HDMI_2_1_top #(
  parameter int DW   = 32,      // data width (reserved, pixel path RGB888)
  parameter int AW   = 32       // address width (reserved)
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       hpd,        // hot plug detect
  output logic       tmds_clk,   // TMDS clock channel (serial pattern)
  output logic [2:0] tmds_d,     // TMDS data channels 0/1/2 (serial)
  output logic       hsync,      // horizontal sync (positive logic)
  output logic       vsync,      // vertical sync (positive logic)
  output logic       de,         // data enable (active video pixel)
  output logic       irq         // hpd lost while link was running
);

  // ------------------------- timing constants (640x480@60) -------------------------
  localparam int HACT = 640, HFP = 16, HSW = 96, HBP = 48;
  localparam int VACT = 480, VFP = 10, VSW = 2,  VBP = 33;
  localparam int HT   = HACT + HFP + HSW + HBP;   // 800
  localparam int VT   = VACT + VFP + VSW + VBP;   // 525
  localparam int HS_B = HACT + HFP;               // hsync start 656
  localparam int HS_E = HS_B + HSW;               // hsync end   752
  localparam int VS_B = VACT + VFP;               // vsync start 490
  localparam int VS_E = VS_B + VSW;               // vsync end   492
  localparam int ISL_Y  = VACT + 1;               // data island line 481
  localparam int PRE_B  = HACT + HFP + HSW + HBP - 10; // 790: video preamble
  localparam int GRD_B  = PRE_B + 8;              // 798: video guard band

  localparam logic [9:0] CLK_PAT = 10'b1111100000;

  // ------------------------- TMDS 8b/10b encoder -------------------------
  // Full DVI 1.0 section 3.2 algorithm.  cnt is the running disparity
  // (signed).  Returns {cnt'[5:0], q[9:0]}; cnt' encoded as 2's complement.
  function automatic logic [15:0] tmds_enc(input logic [7:0] d,
                                           input logic signed [5:0] cnt);
    logic [8:0] qm;
    logic [9:0] q;
    logic [3:0] ones_d;
    logic [3:0] n1;
    logic       use_xnor;
    logic signed [6:0] n1s;   // 2*n1, signed
    logic signed [6:0] ncnt;
    begin
      ones_d = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
      use_xnor = (ones_d > 4) || ((ones_d == 4) && !d[0]);
      qm[0] = d[0];
      for (int i = 1; i < 8; i++) begin
        if (use_xnor) qm[i] = ~(qm[i-1] ^ d[i]);
        else          qm[i] =   qm[i-1] ^ d[i];
      end
      qm[8] = ~use_xnor;
      n1 = qm[0] + qm[1] + qm[2] + qm[3] + qm[4] + qm[5] + qm[6] + qm[7];
      n1s = {3'b000, n1} <<< 1;                     // 2*N1(q_m)
      if ((cnt == 0) || (n1 == 4)) begin
        q[9] = ~qm[8];
        q[8] =  qm[8];
        q[7:0] = qm[8] ? qm[7:0] : ~qm[7:0];
        ncnt = cnt + (qm[8] ? (n1s - 7'sd8) : (7'sd8 - n1s));
      end else if (((cnt > 0) && (n1 > 4)) || ((cnt < 0) && (n1 < 4))) begin
        q[9] = 1'b1;
        q[8] = qm[8];
        q[7:0] = ~qm[7:0];
        ncnt = cnt + (qm[8] ? 7'sd2 : 7'sd0) + (7'sd8 - n1s);
      end else begin
        q[9] = 1'b0;
        q[8] = qm[8];
        q[7:0] = qm[7:0];
        ncnt = cnt + (n1s - 7'sd8) - (qm[8] ? 7'sd0 : 7'sd2);
      end
      tmds_enc = {ncnt[5:0], q};
    end
  endfunction

  // ------------------------- control period codes -------------------------
  function automatic logic [9:0] ctl_code(input logic [1:0] c);
    begin
      case (c)
        2'b00: ctl_code = 10'b1101010100;
        2'b01: ctl_code = 10'b0010101011;
        2'b10: ctl_code = 10'b0101010100;
        default: ctl_code = 10'b1010101011;
      endcase
    end
  endfunction

  // ------------------------- TERC4 encoder (data island) -------------------------
  function automatic logic [9:0] terc4(input logic [3:0] d);
    begin
      case (d)
        4'h0: terc4 = 10'b1010011100;
        4'h1: terc4 = 10'b1001100011;
        4'h2: terc4 = 10'b1011100100;
        4'h3: terc4 = 10'b1011100010;
        4'h4: terc4 = 10'b0101110001;
        4'h5: terc4 = 10'b0100011110;
        4'h6: terc4 = 10'b0110001110;
        4'h7: terc4 = 10'b0100111100;
        4'h8: terc4 = 10'b1011001100;
        4'h9: terc4 = 10'b0100111001;
        4'hA: terc4 = 10'b0110011100;
        4'hB: terc4 = 10'b1011000110;
        4'hC: terc4 = 10'b1010001110;
        4'hD: terc4 = 10'b1001110001;
        4'hE: terc4 = 10'b0101100011;
        default: terc4 = 10'b1011000011;
      endcase
    end
  endfunction

  // ------------------------- AVI InfoFrame packet (constants) -------------------------
  // header: 0x82 / 0x02 / 0x0D + XOR parity byte (BCH simplified, see header)
  localparam logic [31:0] AVI_HDR = {8'h8D, 8'h0D, 8'h02, 8'h82}; // [7:0]=0x82
  // subpackets: {8-bit XOR parity, byte6..byte0}  -> 64 bits, [1:0] sent 1st
  localparam logic [63:0] AVI_SP0 = {8'h4F, 8'h00, 8'h00, 8'h01, 8'h00,
                                     8'h10, 8'h10, 8'h4E};
  localparam logic [63:0] AVI_SP1 = 64'h0;
  localparam logic [63:0] AVI_SP2 = 64'h0;
  localparam logic [63:0] AVI_SP3 = 64'h0;

  // ------------------------- period classification (next pixel) -------------------------
  logic [9:0] x, y;
  logic [3:0] bit_cnt;

  logic [9:0] nx, ny;
  always_comb begin
    if (x == HT-1) begin
      nx = 10'd0;
      ny = (y == VT-1) ? 10'd0 : y + 10'd1;
    end else begin
      nx = x + 10'd1;
      ny = y;
    end
  end

  logic n_hs, n_vs, n_de;
  always_comb begin
    n_hs = (nx >= HS_B[9:0]) && (nx < HS_E[9:0]);
    n_vs = (ny >= VS_B[9:0]) && (ny < VS_E[9:0]);
    n_de = (ny < VACT[9:0]) && (nx < HACT[9:0]);
  end

  typedef enum logic [2:0] {M_CTRL, M_VIDEO, M_PRE, M_GUARD_V,
                            M_ISL_PRE, M_ISL_GRD, M_ISL_DATA} mode_t;
  mode_t mode;
  always_comb begin
    if (n_de)                          mode = M_VIDEO;
    else if (ny < VACT[9:0] && nx >= GRD_B[9:0]) mode = M_GUARD_V;
    else if (ny < VACT[9:0] && nx >= PRE_B[9:0]) mode = M_PRE;
    else if (ny == ISL_Y[9:0] && nx < 10'd8)  mode = M_ISL_PRE;
    else if (ny == ISL_Y[9:0] && nx < 10'd10) mode = M_ISL_GRD;
    else if (ny == ISL_Y[9:0] && nx < 10'd42) mode = M_ISL_DATA;
    else if (ny == ISL_Y[9:0] && nx < 10'd44) mode = M_ISL_GRD;
    else                               mode = M_CTRL;
  end

  // ------------------------- code selection for next pixel -------------------------
  logic signed [5:0] disp0, disp1, disp2;
  logic [15:0] enc0, enc1, enc2;
  logic [9:0]  code0, code1, code2;
  logic [7:0]  r_pix, g_pix, b_pix;
  logic [5:0]  isl_idx;
  logic [9:0]  vguard2;

  always_comb begin
    r_pix = nx[7:0];
    g_pix = ny[7:0];
    b_pix = nx[7:0] ^ ny[7:0];
    enc0 = tmds_enc(b_pix, disp0);
    enc1 = tmds_enc(g_pix, disp1);
    enc2 = tmds_enc(r_pix, disp2);
    isl_idx = nx[5:0] - 6'd10;
    vguard2 = (n_vs == n_hs) ? 10'b1011001100 : 10'b0100110011;
    case (mode)
      M_VIDEO: begin
        code0 = enc0[9:0];
        code1 = enc1[9:0];
        code2 = enc2[9:0];
      end
      M_PRE: begin
        code0 = ctl_code({n_vs, n_hs});
        code1 = ctl_code(2'b01);        // CTL0=1 (video preamble)
        code2 = ctl_code(2'b00);
      end
      M_GUARD_V: begin
        code0 = 10'b1011001100;
        code1 = 10'b0100110011;
        code2 = vguard2;
      end
      M_ISL_PRE: begin
        code0 = ctl_code({n_vs, n_hs});
        code1 = ctl_code(2'b00);
        code2 = ctl_code(2'b11);        // CTL3=CTL2=1 (data island preamble)
      end
      M_ISL_GRD: begin
        code0 = terc4({n_vs, n_hs, 2'b11});
        code1 = 10'b0100110011;
        code2 = 10'b0100110011;
      end
      M_ISL_DATA: begin
        code0 = terc4({n_vs, n_hs, 1'b0, AVI_HDR[isl_idx]});
        code1 = terc4({AVI_SP1[2*isl_idx+1], AVI_SP1[2*isl_idx],
                       AVI_SP0[2*isl_idx+1], AVI_SP0[2*isl_idx]});
        code2 = terc4({AVI_SP3[2*isl_idx+1], AVI_SP3[2*isl_idx],
                       AVI_SP2[2*isl_idx+1], AVI_SP2[2*isl_idx]});
      end
      default: begin                    // M_CTRL
        code0 = ctl_code({n_vs, n_hs});
        code1 = ctl_code(2'b00);
        code2 = ctl_code(2'b00);
      end
    endcase
  end

  // ------------------------- serializers + counters -------------------------
  logic [9:0] sh0, sh1, sh2, shc;
  logic       ever_hpd;

  assign irq = ever_hpd && !hpd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x <= HT-1;   y <= VT-1;   bit_cnt <= 4'd0;  // -> first pixel is (0,0)
      sh0 <= 10'h000; sh1 <= 10'h000; sh2 <= 10'h000;
      shc <= CLK_PAT;
      tmds_clk <= 1'b0;
      tmds_d   <= 3'b000;
      hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0;
      disp0 <= 6'sd0; disp1 <= 6'sd0; disp2 <= 6'd0;
      ever_hpd <= 1'b0;
    end else if (!hpd) begin
      // sink detached: stop TMDS, restart timing from (0,0) on return
      x <= HT-1;   y <= VT-1;   bit_cnt <= 4'd0;
      sh0 <= 10'h000; sh1 <= 10'h000; sh2 <= 10'h000;
      shc <= CLK_PAT;
      tmds_clk <= 1'b0;
      tmds_d   <= 3'b000;
      hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0;
      disp0 <= 6'sd0; disp1 <= 6'sd0; disp2 <= 6'sd0;
    end else begin
      ever_hpd <= 1'b1;
      tmds_clk <= shc[0];
      shc      <= {shc[0], shc[9:1]};
      tmds_d   <= {sh2[0], sh1[0], sh0[0]};
      if (bit_cnt == 4'd9) begin
        bit_cnt <= 4'd0;
        sh0 <= code0;
        sh1 <= code1;
        sh2 <= code2;
        x   <= nx;
        y   <= ny;
        hsync <= n_hs;
        vsync <= n_vs;
        de    <= n_de;
        if (mode == M_VIDEO) begin       // disparity runs on video only
          disp0 <= enc0[15:10];
          disp1 <= enc1[15:10];
          disp2 <= enc2[15:10];
        end
      end else begin
        bit_cnt <= bit_cnt + 4'd1;
        sh0 <= {1'b0, sh0[9:1]};
        sh1 <= {1'b0, sh1[9:1]};
        sh2 <= {1'b0, sh2[9:1]};
      end
    end
  end

endmodule
