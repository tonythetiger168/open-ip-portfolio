// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HDMI_2_1 protocol Open IP -- HDMI source (TMDS mode) educational slice:
//  full TMDS 8b/10b encode algorithm (transition minimisation with XOR/XNOR
//  selection + disparity tracking + DC-balance bits 8/9), 3 data channels +
//  TMDS clock channel (serial 1 bit/clk simplification), control period with
//  8-pixel video/data-island preambles and CTL0-3 codes (4 fixed 10-bit
//  codes), video period RGB888 active pixels on 3 channels, data island
//  period with TERC4 4b/10b encoding and packet structure (24-bit header +
//  4 subpackets x 56 bit, BCH(32,24) / BCH(64,56) ECC, precomputed - see below),
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
//    B=x[7:0]^y[7:0]. HSYNC/VSYNC are active low as VIC 1 specifies; the
//    sync levels are carried on channel 0 (D0=HSYNC, D1=VSYNC) in control
//    and data island periods, CTL1:0 on channel 1, CTL3:2 on channel 2.
//  - The TMDS disparity counter is cleared in every non-video period.
//  - Video preamble (CTL0=1) and leading guard band precede every active
//    line, including line 0 after vertical blanking.
//  - Data islands: AVI InfoFrame on line VACT+1, SPD InfoFrame on line
//    490 (inside vsync), both at x=636..679 so they span the hsync edge:
//    8 px preamble (CTL0=CTL2=1), 2 px leading guard band, 32 px packet,
//    2 px trailing guard band. Packet header HB0..HB2 + BCH(32,24) ECC and
//    4 subpackets of 7 bytes + BCH(64,56) ECC, generator x^8+x^7+x^6+1
//    (precomputed: both packets are constant).
//    Per packet pixel i (0..31), TERC4 inputs:
//      ch0 = {i != 0, header[i], VSYNC, HSYNC}
//      ch1 = {sp3[2i],   sp2[2i],   sp1[2i],   sp0[2i]}
//      ch2 = {sp3[2i+1], sp2[2i+1], sp1[2i+1], sp0[2i+1]}
//    guard bands: ch0 = TERC4({1,1,VSYNC,HSYNC}), ch1 = ch2 = 0100110011.
//  - AVI InfoFrame: type=0x82 ver=0x02 len=0x0D, PB1=0x10 (RGB, active
//    format present), PB2=0x18 (4:3, active format = picture), PB4=VIC 1,
//    checksum = two's complement of the byte sum.
//  - hpd=0: TMDS outputs stop (all zero), timing restarts at (0,0) on
//    hpd return; irq = level "link was running and hpd was lost".
// ============================================================================
module HDMI_2_1_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       hpd,        // hot plug detect
  output logic       tmds_clk,   // TMDS clock channel (serial pattern)
  output logic [2:0] tmds_d,     // TMDS data channels 0/1/2 (serial)
  output logic       hsync,      // horizontal sync (active low, VIC 1)
  output logic       vsync,      // vertical sync (active low, VIC 1)
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
  localparam int ISL_Y  = VACT + 1;               // AVI island line 481
  localparam int SPD_Y  = VS_B;                   // SPD island line 490 (in vsync)
  localparam int ISL_X  = HS_B - 20;              // islands span the hsync edge
  localparam int PRE_B  = HACT + HFP + HSW + HBP - 10; // 790: video preamble
  localparam int GRD_B  = PRE_B + 8;              // 798: video guard band

  localparam logic [9:0] CLK_PAT = 10'b1111100000;

  // ------------------------- TMDS 8b/10b encoder -------------------------
  // Full DVI 1.0 section 3.2 algorithm.  cnt is the running disparity
  // (signed, always even).  Returns {cnt'[5:1], q[9:0]}, cnt' as 2's
  // complement.
  function automatic logic [14:0] tmds_enc(input logic [7:0] d,
                                           input logic signed [5:0] cnt);
    logic [8:0] qm;
    logic [9:0] q;
    logic [3:0] ones_d;
    logic [3:0] n1;
    logic       use_xnor;
    logic signed [5:0] n1s;   // 2*n1, signed
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [5:0] ncnt;               // bit 0 is always 0
    /* verilator lint_on UNUSEDSIGNAL */
    begin
      ones_d = 4'd0;
      for (int i = 0; i < 8; i++) ones_d = ones_d + {3'd0, d[i]};
      use_xnor = (ones_d > 4) || ((ones_d == 4) && !d[0]);
      qm[0] = d[0];
      for (int i = 1; i < 8; i++) begin
        if (use_xnor) qm[i] = ~(qm[i-1] ^ d[i]);
        else          qm[i] =   qm[i-1] ^ d[i];
      end
      qm[8] = ~use_xnor;
      n1 = 4'd0;
      for (int i = 0; i < 8; i++) n1 = n1 + {3'd0, qm[i]};
      n1s = {2'b00, n1} <<< 1;                    // 2*N1(q_m)
      if ((cnt == 0) || (n1 == 4)) begin
        q[9] = ~qm[8];
        q[8] =  qm[8];
        q[7:0] = qm[8] ? qm[7:0] : ~qm[7:0];
        ncnt = cnt + (qm[8] ? (n1s - 6'sd8) : (6'sd8 - n1s));
      end else if (((cnt > 0) && (n1 > 4)) || ((cnt < 0) && (n1 < 4))) begin
        q[9] = 1'b1;
        q[8] = qm[8];
        q[7:0] = ~qm[7:0];
        ncnt = cnt + (qm[8] ? 6'sd2 : 6'sd0) + (6'sd8 - n1s);
      end else begin
        q[9] = 1'b0;
        q[8] = qm[8];
        q[7:0] = qm[7:0];
        ncnt = cnt + (n1s - 6'sd8) - (qm[8] ? 6'sd0 : 6'sd2);
      end
      tmds_enc = {ncnt[5:1], q};                  // disparity is always even
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
  // header {ECC, HB2, HB1, HB0}, bit 0 sent first
  localparam logic [31:0] AVI_HDR = 32'hE40D0282;
  // subpacket {ECC, byte6 .. byte0}; SP0 = PB0 (checksum 0x46) .. PB6
  localparam logic [63:0] AVI_SP0 = 64'h0100000100181046;
  localparam logic [63:0] AVI_SP1 = 64'h0;
  localparam logic [63:0] AVI_SP2 = 64'h0;
  localparam logic [63:0] AVI_SP3 = 64'h0;
  // SPD InfoFrame: type=0x83 ver=0x01 len=0x19, vendor "OpenIP", product
  // "HDMI 2.1 TX Core", source information 0x00 (unknown)
  localparam logic [31:0] SPD_HDR = 32'h64190183;
  localparam logic [63:0] SPD_SP0 = 64'h7D50496E65704FF0;
  localparam logic [63:0] SPD_SP1 = 64'h8220494D44480000;
  localparam logic [63:0] SPD_SP2 = 64'hA020585420312E32;
  localparam logic [63:0] SPD_SP3 = 64'hE500000065726F43;

  // ------------------------- period classification (next pixel) -------------------------
  logic [9:0] x, y;
  logic [3:0] bit_cnt;

  logic [9:0] nx, ny;
  always_comb begin
    if (x == 10'(HT-1)) begin
      nx = 10'd0;
      ny = (y == 10'(VT-1)) ? 10'd0 : y + 10'd1;
    end else begin
      nx = x + 10'd1;
      ny = y;
    end
  end

  logic n_hs, n_vs, n_de, n_pre_line, n_spd, n_isl_line;
  always_comb begin
    n_hs = !((nx >= HS_B[9:0]) && (nx < HS_E[9:0]));     // active low
    n_vs = !((ny >= VS_B[9:0]) && (ny < VS_E[9:0]));
    n_de = (ny < VACT[9:0]) && (nx < HACT[9:0]);
    // the line after this one is active: preamble + guard at its end
    n_pre_line = (ny == VT[9:0] - 10'd1) || (ny < VACT[9:0] - 10'd1);
    n_spd      = (ny == SPD_Y[9:0]);
    n_isl_line = (ny == ISL_Y[9:0]) || n_spd;
  end

  typedef enum logic [2:0] {M_CTRL, M_VIDEO, M_PRE, M_GUARD_V,
                            M_ISL_PRE, M_ISL_GRD, M_ISL_DATA} mode_t;
  mode_t mode;
  always_comb begin
    if (n_de)                          mode = M_VIDEO;
    else if (n_pre_line && nx >= GRD_B[9:0]) mode = M_GUARD_V;
    else if (n_pre_line && nx >= PRE_B[9:0]) mode = M_PRE;
    else if (n_isl_line && nx >= ISL_X[9:0] && nx < ISL_X[9:0] + 10'd8)  mode = M_ISL_PRE;
    else if (n_isl_line && nx >= ISL_X[9:0] && nx < ISL_X[9:0] + 10'd10) mode = M_ISL_GRD;
    else if (n_isl_line && nx >= ISL_X[9:0] && nx < ISL_X[9:0] + 10'd42) mode = M_ISL_DATA;
    else if (n_isl_line && nx >= ISL_X[9:0] && nx < ISL_X[9:0] + 10'd44) mode = M_ISL_GRD;
    else                               mode = M_CTRL;
  end

  // ------------------------- code selection for next pixel -------------------------
  logic signed [4:0] disp0, disp1, disp2;       // running disparity / 2
  logic [14:0] enc0, enc1, enc2;
  logic [9:0]  code0, code1, code2;
  logic [7:0]  r_pix, g_pix, b_pix;
  logic [4:0]  isl_idx;

  // packet bits for island pixel i: {hdr[i], sp3..0[2i+1], sp3..0[2i]};
  // AVI InfoFrame on line 481, SPD InfoFrame on line 490
  function automatic logic [8:0] pkt_bits(input logic spd, input logic [4:0] i);
    logic [31:0] h;
    logic [63:0] s0, s1, s2, s3;
    h  = spd ? SPD_HDR : AVI_HDR;
    s0 = spd ? SPD_SP0 : AVI_SP0;
    s1 = spd ? SPD_SP1 : AVI_SP1;
    s2 = spd ? SPD_SP2 : AVI_SP2;
    s3 = spd ? SPD_SP3 : AVI_SP3;
    pkt_bits = {h[i], s3[{i, 1'b1}], s2[{i, 1'b1}], s1[{i, 1'b1}], s0[{i, 1'b1}],
                s3[{i, 1'b0}], s2[{i, 1'b0}], s1[{i, 1'b0}], s0[{i, 1'b0}]};
  endfunction
  logic [8:0] pk;

  always_comb begin
    r_pix = nx[7:0];
    g_pix = ny[7:0];
    b_pix = nx[7:0] ^ ny[7:0];
    enc0 = tmds_enc(b_pix, {disp0, 1'b0});
    enc1 = tmds_enc(g_pix, {disp1, 1'b0});
    enc2 = tmds_enc(r_pix, {disp2, 1'b0});
    isl_idx = 5'(nx - ISL_X[9:0] - 10'd10);
    pk = pkt_bits(n_spd, isl_idx);
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
        code2 = 10'b1011001100;
      end
      M_ISL_PRE: begin
        code0 = ctl_code({n_vs, n_hs});
        code1 = ctl_code(2'b01);        // CTL0=1, CTL2=1: data island preamble
        code2 = ctl_code(2'b01);
      end
      M_ISL_GRD: begin
        code0 = terc4({2'b11, n_vs, n_hs});
        code1 = 10'b0100110011;
        code2 = 10'b0100110011;
      end
      M_ISL_DATA: begin
        code0 = terc4({isl_idx != 5'd0, pk[8], n_vs, n_hs});
        code1 = terc4(pk[3:0]);
        code2 = terc4(pk[7:4]);
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
      x <= 10'(HT-1);   y <= 10'(VT-1);   bit_cnt <= 4'd0;  // -> first pixel is (0,0)
      sh0 <= 10'h000; sh1 <= 10'h000; sh2 <= 10'h000;
      shc <= CLK_PAT;
      tmds_clk <= 1'b0;
      tmds_d   <= 3'b000;
      hsync <= 1'b1; vsync <= 1'b1; de <= 1'b0;
      disp0 <= 5'sd0; disp1 <= 5'sd0; disp2 <= 5'sd0;
      ever_hpd <= 1'b0;
    end else if (!hpd) begin
      // sink detached: stop TMDS, restart timing from (0,0) on return
      x <= 10'(HT-1);   y <= 10'(VT-1);   bit_cnt <= 4'd0;
      sh0 <= 10'h000; sh1 <= 10'h000; sh2 <= 10'h000;
      shc <= CLK_PAT;
      tmds_clk <= 1'b0;
      tmds_d   <= 3'b000;
      hsync <= 1'b1; vsync <= 1'b1; de <= 1'b0;
      disp0 <= 5'sd0; disp1 <= 5'sd0; disp2 <= 5'sd0;
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
          disp0 <= enc0[14:10];
          disp1 <= enc1[14:10];
          disp2 <= enc2[14:10];
        end else begin                   // and restarts after blanking
          disp0 <= 5'sd0; disp1 <= 5'sd0; disp2 <= 5'sd0;
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
