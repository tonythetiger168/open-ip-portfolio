// SPDX-License-Identifier: Apache-2.0
// Ethernet MAC: concurrent SVA against an independent reference model, plus
// functional coverage.
//  * Byte time: a counter to cfg_div; everything below acts once per byte
//    time.
//  * Transmit: a line-byte index from the frame start (7 x 0x55, 0xD5, the
//    host bytes, zero padding to 60, FCS low byte first), its own CRC, a
//    12-byte gap; underruns, and the PAUSE counter that holds frame starts.
//  * Receive: preamble hunt, the frame bytes in an 8-byte ring, CRC
//    residue, length rules (VLAN), DA filter at the sixth byte, PAUSE fields,
//    each byte released six byte times late and the last two after the end.
// Every output is compared on every clock.
`include "cov_macros.svh"
module Ethernet_sva (
  input logic        clk, rst_n,
  input logic [4:0]  cfg_div,
  input logic [47:0] cfg_mac,
  input logic        cfg_promisc, cfg_pause_en,
  input logic        tx_valid, tx_ready,
  input logic [7:0]  tx_data,
  input logic        tx_last, tx_done, tx_underrun, tx_paused,
  input logic [7:0]  gtxd,
  input logic        gtx_en, gtx_er,
  input logic [7:0]  grxd,
  input logic        grx_dv, grx_er,
  input logic        rx_valid,
  input logic [7:0]  rx_data,
  input logic        rx_last,
  input logic [3:0]  rx_stat,
  input logic        rx_frag
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [31:0] crc_b(input logic [31:0] c, input logic [7:0] d);
    for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction

  int          bc;                       // clocks into the byte time
  // transmit
  int          tph, tk, tlen, tgap;      // tph: 0 idle, 1 preamble, 2 host bytes, 3 pad, 4 FCS, 5 gap
  logic [31:0] tcrc;
  logic [7:0]  m_d;
  bit          m_en, m_er, m_done, m_ur;
  int          mp;                       // PAUSE byte times left
  // receive
  int          rph, rn, ri;              // rph: 0 idle / preamble, 1 frame, 2 drop, 3 / 4 flush; rn saturates, ri does not
  bit          seen55, racc, rer;
  logic [7:0]  ring [0:7];
  logic [31:0] rcrc;
  logic [47:0] rda;
  logic [15:0] rty, rop, rqa;
  bit          m_rv, m_rl, m_fr;
  logic [7:0]  m_rd;
  logic [3:0]  m_rs;
  // coverage
  bit          v_pad, v_nopad, v_ur_hdr, v_held, v_promisc_only, v_drop, v_runt, v_long, v_vlan_ok, v_vlan_long;
  bit          v_crc, v_phy, v_pause_ok, v_pause_ign, v_div0, v_div31, v_sat, v_bad_pre, v_nopre;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      bc = 0; tph = 0; tk = 0; tlen = 0; tgap = 0; tcrc = 0; m_d = 0; {m_en, m_er, m_done, m_ur} = '0; mp = 0;
      rph = 0; rn = 0; ri = 0; {seen55, racc, rer} = '0; rcrc = 0; rda = 0; rty = 0; rop = 0; rqa = 0;
      for (int i = 0; i < 8; i++) ring[i] = 0;
      {m_rv, m_rl, m_fr} = '0; m_rd = 0; m_rs = 0;
    end else begin : b_step
      bit byte_t;
      {m_done, m_ur, m_rv, m_fr} = '0;
      byte_t = bc == int'(cfg_div);
      bc = byte_t ? 0 : (bc + 1) % 32;
      if (byte_t) begin
        int p_now;
        if (cfg_div == 0) v_div0 = 1;
        if (cfg_div == 31) v_div31 = 1;
        p_now = mp;
        if (mp > 0) mp--;
        // ---------------- transmit ----------------
        case (tph)
          0: if (tx_valid && p_now == 0) begin tph = 1; tk = 1; m_en = 1; m_d = 8'h55; end
             else if (tx_valid) v_held = 1;
          1: begin
            m_d = tk == 7 ? 8'hD5 : 8'h55;
            tk++;
            if (tk == 8) begin tph = 2; tlen = 0; tcrc = '1; end
          end
          2: if (tx_valid) begin
            m_d = tx_data; tcrc = crc_b(tcrc, tx_data); tlen++;
            if (tx_last) begin
              tph = tlen >= 60 ? 4 : 3; tk = 0;
              if (tlen >= 60) v_nopad = 1; else v_pad = 1;
            end
          end else begin
            m_d = 0; m_er = 1; m_ur = 1; tph = 5; tgap = 0;
            if (tlen < 14) v_ur_hdr = 1;
          end
          3: begin
            m_d = 0; tcrc = crc_b(tcrc, 8'h00); tlen++;
            if (tlen == 60) begin tph = 4; tk = 0; end
          end
          4: begin
            m_d = ~tcrc[8 * tk +: 8];
            tk++;
            if (tk == 4) begin tph = 5; tgap = 0; m_done = 1; end
          end
          default: begin
            m_en = 0; m_er = 0; m_d = 0;
            tgap++;
            if (tgap == 12) tph = 0;
          end
        endcase

        // ---------------- receive ----------------
        case (rph)
          0: if (!grx_dv) begin if (seen55) m_fr = 1; seen55 = 0; end
             else if (grxd == 8'hD5) begin
               rph = 1; rn = 0; ri = 0; rcrc = '1; rer = 0; racc = 0;
               if (!seen55) v_nopre = 1;
               seen55 = 0;
             end else if (grxd == 8'h55) seen55 = 1;
             else begin rph = 2; m_fr = 1; seen55 = 0; v_bad_pre = 1; end
          1: if (grx_dv) begin
               if (ri >= 6 && racc) begin m_rv = 1; m_rd = ring[(ri - 6) % 8]; m_rl = 0; end
               ring[ri % 8] = grxd;
               rcrc = crc_b(rcrc, grxd);
               if (grx_er) rer = 1;
               if (rn < 6) rda = {rda[39:0], grxd};
               if (rn == 5) begin
                 racc = cfg_promisc || rda == cfg_mac || rda == 48'hFFFF_FFFF_FFFF || rda == 48'h0180_C200_0001;
                 if (!racc) v_drop = 1;
                 if (cfg_promisc && rda != cfg_mac && rda != 48'hFFFF_FFFF_FFFF && rda != 48'h0180_C200_0001) v_promisc_only = 1;
               end
               if (rn == 12 || rn == 13) rty = {rty[7:0], grxd};
               if (rn == 14 || rn == 15) rop = {rop[7:0], grxd};
               if (rn == 16 || rn == 17) rqa = {rqa[7:0], grxd};
               if (rn < 2047) rn++; else v_sat = 1;
               ri++;
             end else if (rn < 6) begin rph = 0; m_fr = 1; end
             else rph = racc ? 3 : 0;
          2: if (!grx_dv) rph = 0;
          3: begin m_rv = 1; m_rd = ring[(ri - 6) % 8]; m_rl = 0; rph = 4; end
          default: begin : b_last
            bit ce, le, pz;
            ce = rcrc != 32'hDEBB20E3;
            le = rn < 64 || rn > (rty == 16'h8100 ? 1522 : 1518);
            pz = rty == 16'h8808 && rop == 16'h0001 && rn >= 18;
            m_rv = 1; m_rd = ring[(ri - 5) % 8]; m_rl = 1; m_rs = {pz, rer, le, ce};
            if (ce) v_crc = 1;
            if (rer) v_phy = 1;
            if (rn < 64) v_runt = 1;
            if (rn > 1518 && rty != 16'h8100) v_long = 1;
            if (rty == 16'h8100 && rn > 1518 && !le) v_vlan_ok = 1;
            if (rty == 16'h8100 && rn > 1522) v_vlan_long = 1;
            if (pz && cfg_pause_en && !ce && !le && !rer) begin mp = int'(rqa) * 64; v_pause_ok = 1; end
            else if (pz) v_pause_ign = 1;
            rph = 0;
          end
        endcase
      end
    end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_ready, tx_ready == (tph == 2 && bc == int'(cfg_div)))
  `SVA_INV(a_gtx, gtx_en == m_en && gtx_er == m_er && gtxd == m_d)
  `SVA_INV(a_tx_events, tx_done == m_done && tx_underrun == m_ur)
  `SVA_INV(a_paused, tx_paused == (mp != 0))
  `SVA_INV(a_rx_valid, rx_valid == m_rv && rx_frag == m_fr)
  `SVA_IMP(a_rx, m_rv, rx_data == m_rd && rx_last == m_rl)
  `SVA_IMP(a_rx_stat, m_rv && m_rl, rx_stat == m_rs)
  `SVA_RST(a_reset, 1'b1, !gtx_en && !gtx_er && !tx_ready && !rx_valid && !tx_paused && !tx_done)

  // ---------------- functional coverage ----------------
  `FC(padded_frame, v_pad)
  `FC(unpadded_frame, v_nopad)
  `FC(underrun_in_header, v_ur_hdr)
  `FC(underrun, tx_underrun)
  `FC(held_by_pause, v_held)
  `FC(pause_obeyed, v_pause_ok)
  `FC(pause_ignored, v_pause_ign)
  `FC(rx_good, rx_valid && rx_last && rx_stat == 4'b0000)
  `FC(rx_crc_error, v_crc)
  `FC(rx_phy_error, v_phy)
  `FC(rx_runt, v_runt)
  `FC(rx_too_long, v_long)
  `FC(rx_vlan_max, v_vlan_ok)
  `FC(rx_vlan_too_long, v_vlan_long)
  `FC(rx_count_saturates, v_sat)
  `FC(rx_filtered, v_drop)
  `FC(rx_promiscuous, v_promisc_only)
  `FC(rx_fragment, rx_frag)
  `FC(rx_bad_preamble, v_bad_pre)
  `FC(rx_sfd_only, v_nopre)
  `FC(byte_per_clock, v_div0)
  `FC(slowest_byte_time, v_div31)
endmodule

bind Ethernet_top Ethernet_sva u_sva (.*);
