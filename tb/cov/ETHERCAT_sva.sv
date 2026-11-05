// SPDX-License-Identifier: Apache-2.0
// EtherCAT ESC frame processing: concurrent SVA against an independent,
// octet-level reference model, plus functional coverage.
//  * The model parses every received octet itself (Ethernet header,
//    EtherCAT header, datagram headers, data, working counter), keeps its
//    own copy of the process RAM, station address and FMMU registers, and
//    computes the octet the station must forward (ADP + 1, read data, BRD
//    OR, WKC + increment). Its octets run through a 5-stage line; at the end
//    of a frame of 5 octets or more the last 4 become the CRC-32 of the
//    forwarded octets (inverted when the received FCS was wrong). tx_dv /
//    tx_d are compared with the line on every clock.
//  * fr_done and its result fields, host_rdata and the memory image seen
//    by the host are compared with the model; the host write that collides
//    with a frame write to the same octet is dropped by the model too.
`include "cov_macros.svh"
module ETHERCAT_sva (
  input  logic        clk, rst_n,
  input  logic        rx_dv,
  input  logic [7:0]  rx_d,
  input  logic        tx_dv,
  input  logic [7:0]  tx_d,
  input  logic        host_rd, host_wr,
  input  logic [15:0] host_addr,
  input  logic [7:0]  host_wdata,
  input  logic [7:0]  host_rdata,
  input  logic        fr_done, fr_fcs_ok, fr_ecat,
  input  logic [7:0]  fr_dgrams, fr_wkc
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- model memory ----------------
  logic [7:0] mr [0:1023];
  logic [7:0] ms [0:1];
  logic [7:0] mf [0:31];
  initial for (int i = 0; i < 1024; i++) mr[i] = 8'h00;
  function automatic logic [7:0] mrd(input logic [15:0] a);
    if (a >= 16'h1000 && a < 16'h1400) return mr[a - 16'h1000];
    if (a == 16'h0010 || a == 16'h0011) return ms[a[0]];
    if (a >= 16'h0600 && a < 16'h0620) return mf[a - 16'h0600];
    return 8'h00;
  endfunction
  function automatic logic [31:0] crc(input logic [31:0] c, input logic [7:0] d);
    c ^= {24'd0, d};
    for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction

  // ---------------- model state ----------------
  typedef enum int {M_ETH, M_ECAT, M_HDR, M_DATA, M_WKC, M_PASS} mm_t;
  mm_t         mm;
  bit          m_in;
  int          k, h;                                 // octet of the frame / of the field
  bit          m_ecat;
  logic [7:0]  cmd, w0;
  logic [15:0] adp, ado;
  int          len, di;
  bit          more, hitp, any_r, any_w;
  int          inc, ndg, wsum;
  logic [7:0]  rx_q [0:4095], ex_q [0:4095];         // octets of this frame in / out
  // the line: forwarded octets, 5 clocks
  bit   [4:0]  lv;
  logic [7:0]  ld [0:4];
  // results
  bit          e_done, e_ok, e_ecat;
  logic [7:0]  e_dg, e_wkc, e_hr;
  // coverage flags of this clock
  bit          v_short, v_bad_fcs, v_other_type, v_ecat_type, v_trunc, v_hcol, v_hrd_frame,
               v_adp_carry, v_wkc_carry, v_wsum_sat, v_ndg_wrap, v_len0, v_fmmu_both, v_lmiss,
               v_lpart, v_other_cmd, v_b2b, v_ram_top, v_unmapped;
  bit   [14:0] v_cmd_hit, v_cmd_miss;
  int          idle;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mm = M_ETH; m_in = 0; k = 0; h = 0; lv = '0; e_done = 0; e_ok = 0; e_ecat = 0;
      e_dg = 0; e_wkc = 0; e_hr = 0; idle = 99;
      for (int i = 0; i < 5; i++) ld[i] = 8'h00;
      ms[0] = 0; ms[1] = 0;
      for (int i = 0; i < 32; i++) mf[i] = 0;
      {v_short, v_bad_fcs, v_other_type, v_ecat_type, v_trunc, v_hcol, v_hrd_frame, v_adp_carry,
       v_wkc_carry, v_wsum_sat, v_ndg_wrap, v_len0, v_fmmu_both, v_lmiss, v_lpart, v_other_cmd,
       v_b2b, v_ram_top, v_unmapped} = '0;
      v_cmd_hit = '0; v_cmd_miss = '0;
    end else begin
      logic [7:0]  e, d;
      bit          f_we, end_now;
      logic [15:0] f_wa;
      logic [7:0]  f_wd, hr_now;
      {v_short, v_bad_fcs, v_other_type, v_ecat_type, v_trunc, v_hcol, v_hrd_frame, v_adp_carry,
       v_wkc_carry, v_wsum_sat, v_ndg_wrap, v_len0, v_fmmu_both, v_lmiss, v_lpart, v_other_cmd,
       v_b2b, v_ram_top, v_unmapped} = '0;
      v_cmd_hit = '0; v_cmd_miss = '0;
      e_done = 0;
      f_we = 0; f_wa = 0; f_wd = 0; end_now = 0;
      hr_now = mrd(host_addr);                         // the host reads before this clock's writes
      d = rx_d; e = rx_d;
      if (rx_dv) begin
        if (!m_in) begin
          m_in = 1; k = 0; mm = M_ETH; m_ecat = 0; ndg = 0; wsum = 0;
          v_b2b = idle == 5;
        end
        rx_q[k % 4096] = d;
        case (mm)
          M_ETH: begin
            if (k == 12 && d != 8'h88) begin mm = M_PASS; v_other_type = 1; end
            if (k == 13) begin
              if (d == 8'hA4) begin mm = M_ECAT; h = 0; end
              else begin mm = M_PASS; v_other_type = 1; end
            end
          end
          M_ECAT: begin
            if (h == 1) begin
              if (d[7:4] == 4'd1) begin mm = M_HDR; h = -1; m_ecat = 1; end
              else begin mm = M_PASS; v_ecat_type = 1; end
            end
            h++;
          end
          M_HDR: begin
            bit up;
            up = cmd_inc(h == 0 ? d : cmd);
            case (h)
              0: cmd = d;
              2: begin adp[7:0] = d; if (up) e = d + 8'd1; end
              3: begin
                adp[15:8] = d;
                if (up) begin e = d + (adp[7:0] == 8'hFF ? 8'd1 : 8'd0); v_adp_carry = adp[7:0] == 8'hFF; end
                hitp = (cmd >= 1 && cmd <= 3 || cmd == 13) ? adp == 16'd0 :
                       (cmd >= 4 && cmd <= 6 || cmd == 14) ? adp == {ms[1], ms[0]} : (cmd >= 7 && cmd <= 9);
              end
              4: ado[7:0] = d;
              5: ado[15:8] = d;
              6: len[7:0] = d;
              7: begin len = {21'd0, d[2:0], len[7:0]}; more = d[7]; end
              9: begin
                any_r = 0; any_w = 0; di = 0;
                if (cmd == 13 || cmd == 14) inc = 1;
                else if (cmd >= 1 && cmd <= 9 && hitp) inc = rw_cmd(cmd) ? 3 : 1;
                else inc = 0;
                if (cmd >= 1 && cmd <= 14) begin
                  if (cmd >= 10 && cmd <= 12 || cmd == 13 || cmd == 14 || hitp) v_cmd_hit[cmd] = 1;
                  else v_cmd_miss[cmd] = 1;
                end else if (cmd == 0) v_cmd_hit[0] = 1;
                else v_other_cmd = 1;
                v_len0 = len == 0;
                mm = len == 0 ? M_WKC : M_DATA;
                h = -1;
              end
              default: ;
            endcase
            h++;
          end
          M_DATA: begin
            logic [15:0] a;
            if (cmd >= 10 && cmd <= 12) begin
              logic [31:0] la, st0, st1, o0, o1;
              bit in0, in1;
              la = {ado, adp} + 32'(di);
              st0 = {mf[3], mf[2], mf[1], mf[0]};   st1 = {mf[19], mf[18], mf[17], mf[16]};
              o0 = la - st0; o1 = la - st1;
              in0 = mf[12][0] && la >= st0 && o0 < {16'd0, mf[5], mf[4]};
              in1 = mf[28][0] && la >= st1 && o1 < {16'd0, mf[21], mf[20]};
              v_fmmu_both = in0 && in1;
              if (in0 || in1) begin
                bit r, w;
                a = in0 ? {mf[9], mf[8]} + o0[15:0] : {mf[25], mf[24]} + o1[15:0];
                r = in0 ? mf[11][0] : mf[27][0];
                w = in0 ? mf[11][1] : mf[27][1];
                if (r && (cmd == 10 || cmd == 12)) begin e = mrd(a); any_r = 1; end
                if (w && (cmd == 11 || cmd == 12)) begin f_we = 1; f_wa = a; f_wd = d; any_w = 1; end
                v_lpart = any_r || any_w;
              end else v_lmiss = 1;
            end else begin
              a = ado + 16'(di);
              v_ram_top = a == 16'h13FF;
              v_unmapped = a >= 16'h2000;
              if (cmd == 13 || cmd == 14) begin
                if (hitp) e = mrd(a);
                else begin f_we = 1; f_wa = a; f_wd = d; end
              end else if (cmd >= 1 && cmd <= 9 && hitp) begin
                if (!wr_cmd(cmd)) e = (cmd == 7 || cmd == 9) ? d | mrd(a) : mrd(a);
                if (!rd_cmd(cmd)) begin f_we = 1; f_wa = a; f_wd = d; end
              end
            end
            di++;
            if (di == len) begin
              mm = M_WKC; h = 0;
              if (cmd == 10) inc = any_r ? 1 : 0;
              if (cmd == 11) inc = any_w ? 1 : 0;
              if (cmd == 12) inc = (any_r ? 1 : 0) + (any_w ? 2 : 0);
            end
          end
          M_WKC: begin
            if (h == 0) begin
              logic [8:0] s;
              s = {1'b0, d} + 9'(inc);
              e = s[7:0]; w0 = d; v_wkc_carry = s[8];
            end else begin
              e = d + ({1'b0, w0} + 9'(inc) > 9'd255 ? 8'd1 : 8'd0);
              ndg++; v_ndg_wrap = ndg == 256;
              v_wsum_sat = wsum + inc > 255;
              wsum = wsum + inc > 255 ? 255 : wsum + inc;
              mm = more ? M_HDR : M_PASS;
              h = -1;
            end
            h++;
          end
          default: ;
        endcase
        ex_q[k % 4096] = e;
        k++;
        idle = 0;
      end else if (m_in) begin
        // end of the frame: results and the FCS octets of the line
        logic [31:0] ci, co, fr, ft;
        m_in = 0; end_now = 1;
        v_trunc = m_ecat && mm != M_PASS;
        e_done = 1; e_ecat = m_ecat; e_dg = 8'(ndg); e_wkc = 8'(wsum);
        if (k >= 5) begin
          ci = '1; co = '1;
          for (int i = 0; i < k - 4; i++) begin ci = crc(ci, rx_q[i]); co = crc(co, ex_q[i]); end
          fr = {rx_q[k - 1], rx_q[k - 2], rx_q[k - 3], rx_q[k - 4]};
          e_ok = ~ci == fr;
          ft = e_ok ? ~co : co;
          v_bad_fcs = !e_ok;
        end else begin
          e_ok = 0; v_short = 1;
        end
        idle = 1;
        if (k >= 5) begin
          // the line after this clock's shift: stages 4..1 carry the FCS
          lv = {lv[3:0], 1'b0};
          for (int i = 4; i > 0; i--) ld[i] = ld[i - 1];
          ld[0] = e;
          ld[4] = ft[7:0]; ld[3] = ft[15:8]; ld[2] = ft[23:16]; ld[1] = ft[31:24];
        end
      end else if (idle < 99) idle++;
      if (!end_now || k < 5) begin
        lv = {lv[3:0], rx_dv};
        for (int i = 4; i > 0; i--) ld[i] = ld[i - 1];
        ld[0] = e;
      end
      // memory: the frame's write, then the host's unless it hits the same octet
      v_hcol = host_wr && f_we && f_wa == host_addr;
      v_hrd_frame = host_rd && f_we;
      if (f_we) mwr(f_wa, f_wd);
      if (host_wr && !(f_we && f_wa == host_addr)) mwr(host_addr, host_wdata);
      if (host_rd) e_hr = hr_now;
    end
  end
  function automatic bit cmd_inc(input logic [7:0] c);
    return c >= 1 && c <= 3 || c >= 7 && c <= 9 || c == 13;
  endfunction
  function automatic bit rd_cmd(input logic [7:0] c);
    return c == 1 || c == 4 || c == 7 || c == 10;
  endfunction
  function automatic bit wr_cmd(input logic [7:0] c);
    return c == 2 || c == 5 || c == 8 || c == 11;
  endfunction
  function automatic bit rw_cmd(input logic [7:0] c);
    return c == 3 || c == 6 || c == 9 || c == 12;
  endfunction
  task automatic mwr(input logic [15:0] a, input logic [7:0] v);
    if (a >= 16'h1000 && a < 16'h1400) mr[a - 16'h1000] = v;
    else if (a == 16'h0010 || a == 16'h0011) ms[a[0]] = v;
    else if (a >= 16'h0600 && a < 16'h0620) mf[a - 16'h0600] = v;
  endtask

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_dv, tx_dv == lv[4])
  `SVA_IMP(a_tx_d, tx_dv, tx_d == ld[4])
  `SVA_INV(a_done, fr_done == e_done)
  `SVA_IMP(a_done_fcs, fr_done, fr_fcs_ok == e_ok)
  `SVA_IMP(a_done_ecat, fr_done, fr_ecat == e_ecat)
  `SVA_IMP(a_done_dgrams, fr_done, fr_dgrams == e_dg)
  `SVA_IMP(a_done_wkc, fr_done, fr_wkc == e_wkc)
  `SVA_INV(a_host_rdata, host_rdata == e_hr)
  `SVA_RST(a_rst_outputs, 1'b1, !tx_dv && !fr_done && host_rdata == 8'h00)

  // ---------------- functional coverage ----------------
  `FC(cmd_nop, v_cmd_hit[0])
  `FC(cmd_aprd, v_cmd_hit[1])
  `FC(cmd_apwr, v_cmd_hit[2])
  `FC(cmd_aprw, v_cmd_hit[3])
  `FC(cmd_fprd, v_cmd_hit[4])
  `FC(cmd_fpwr, v_cmd_hit[5])
  `FC(cmd_fprw, v_cmd_hit[6])
  `FC(cmd_brd, v_cmd_hit[7])
  `FC(cmd_bwr, v_cmd_hit[8])
  `FC(cmd_brw, v_cmd_hit[9])
  `FC(cmd_lrd, v_cmd_hit[10])
  `FC(cmd_lwr, v_cmd_hit[11])
  `FC(cmd_lrw, v_cmd_hit[12])
  `FC(cmd_armw, v_cmd_hit[13])
  `FC(cmd_frmw, v_cmd_hit[14])
  `FC(ap_not_addressed, |v_cmd_miss[3:1])
  `FC(fp_not_addressed, |v_cmd_miss[6:4])
  `FC(reserved_cmd, v_other_cmd)
  `FC(adp_carry, v_adp_carry)
  `FC(wkc_carry, v_wkc_carry)
  `FC(wkc_sum_saturates, v_wsum_sat)
  `FC(zero_length_datagram, v_len0)
  `FC(logical_miss, v_lmiss)
  `FC(logical_hit, v_lpart)
  `FC(both_fmmus_hold_octet, v_fmmu_both)
  `FC(last_ram_octet, v_ram_top)
  `FC(unmapped_high_address, v_unmapped)
  `FC(bad_fcs, v_bad_fcs)
  `FC(short_frame, v_short)
  `FC(other_ethertype, v_other_type)
  `FC(other_ecat_type, v_ecat_type)
  `FC(truncated_ecat_frame, v_trunc)
  `FC(host_write_collision, v_hcol)
  `FC(host_read_during_frame_write, v_hrd_frame)
  `FC(back_to_back_5_idle, v_b2b)
  `FC(many_datagrams, fr_done && fr_dgrams >= 8'd128)
  `FC_RST(reset_in_frame, !rst_n && $past(rx_dv))
endmodule

bind ETHERCAT_top ETHERCAT_sva u_sva (.*);
