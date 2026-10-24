// SPDX-License-Identifier: Apache-2.0
// MIPI CSI-2 RX: a pin-level model decodes rx_bit/rx_valid (sync hunt,
// header, brute-force single-error correction by trial flips, payload,
// CRC-16) and predicts every status output and the readable line.
`include "cov_macros.svh"
module CSI_2_sva #(parameter int LINE_BYTES = 512) (
  input logic        clk, rst_n, rx_bit, rx_valid, irq, frame_active,
  input logic [15:0] frame_cnt, line_cnt, last_wc, lb_len,
  input logic [7:0]  last_dt, lb_rdata,
  input logic [3:0]  err_flags,
  input logic [$clog2(LINE_BYTES)-1:0] lb_addr
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int LB = LINE_BYTES;

  function automatic logic [5:0] ecc(input logic [23:0] d);
    logic [23:0] m [0:5];
    m = '{24'hF12CB7, 24'hF2555B, 24'h749A6D, 24'hB8E38E, 24'hDF03F0, 24'hEFFC00};
    for (int p = 0; p < 6; p++) ecc[p] = ^(d & m[p]);
  endfunction
  function automatic logic [15:0] crc(input logic [15:0] c, input logic [7:0] d);
    for (int k = 0; k < 8; k++) c = ((c ^ 16'(d >> k)) & 1) != 0 ? (c >> 1) ^ 16'h8408 : c >> 1;
    return c;
  endfunction

  localparam int H = 0, P = 1, N = 2, E = 3;      // hunt, packet, next, eot
  int   ph, nbit, nbyte, wc, plen;
  logic [7:0]  win;
  logic [7:0]  b [0:3];
  logic [15:0] c, c_lo;
  logic        lng;
  logic [7:0]  ln_new [0:LB-1], ln [0:LB-1];
  // model outputs
  logic        m_irq, m_act;
  logic [15:0] m_fc, m_lc, m_wc, m_len;
  logic [7:0]  m_dt;
  logic [3:0]  m_err;
  // coverage strobes
  logic f_fix, f_eccbit, f_drop, f_crc, f_ab_hdr, f_ab_pay, f_ab_crc, f_multi, f_junk, f_long_lb, f_wc0;
  logic f_odd_sync;

  wire [7:0]  nb    = {rx_bit, win[7:1]};
  wire        bdone = ph != H && nbit == 7;
  logic [23:0] hfix;
  logic        hok, hcorr;
  always_comb begin
    logic [23:0] h;
    h = {b[2], b[1], b[0]};
    hfix = h; hok = 0; hcorr = 0;
    if (ecc(h) == nb[5:0]) hok = 1;
    else begin
      for (int i = 0; i < 24; i++) if (ecc(h ^ (24'h1 << i)) == nb[5:0]) begin hfix = h ^ (24'h1 << i); hok = 1; hcorr = 1; end
      for (int j = 0; j < 6; j++) if ((ecc(h) ^ (6'h1 << j)) == nb[5:0]) begin hok = 1; hcorr = 1; end
    end
  end

  int lead;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= H; nbit <= 0; nbyte <= 0; wc <= 0; plen <= 0; win <= 0; c <= 16'hFFFF; c_lo <= 0; lng <= 0;
      m_irq <= 0; m_act <= 0; m_fc <= 0; m_lc <= 0; m_wc <= 0; m_len <= 0; m_dt <= 0; m_err <= 0; lead <= 0;
      {f_fix, f_eccbit, f_drop, f_crc, f_ab_hdr, f_ab_pay, f_ab_crc, f_multi, f_junk, f_long_lb, f_wc0, f_odd_sync} <= '0;
    end else begin
      {f_fix, f_eccbit, f_drop, f_crc, f_ab_hdr, f_ab_pay, f_ab_crc, f_multi, f_junk, f_long_lb, f_wc0, f_odd_sync} <= '0;
      if (!rx_valid) begin
        if (ph == P) begin
          m_err[2] <= 1;
          f_ab_hdr <= nbyte < 4; f_ab_pay <= nbyte >= 4 && lng && nbyte < 4 + wc;
          f_ab_crc <= nbyte >= 4 && lng && nbyte >= 4 + wc;
        end
        ph <= H; nbit <= 0; lead <= 0;
      end else begin
        win <= nb;
        if (ph == H) begin
          lead <= lead + 1;
          if (nb == 8'hB8) begin ph <= P; nbit <= 0; nbyte <= 0; f_odd_sync <= (lead + 1) % 8 != 0; end
        end else begin
          nbit <= nbit + 1;
          if (nbit == 7) begin
            nbit <= 0;
            if (ph == N) begin
              if (nb == 8'hB8) begin ph <= P; nbyte <= 0; f_multi <= 1; end
              else begin ph <= E; f_junk <= 1; end
            end else if (ph == P) begin
              nbyte <= nbyte + 1;
              if (nbyte < 3) b[nbyte] <= nb;
              else if (nbyte == 3) begin
                if (!hok) begin ph <= N; m_irq <= 1; m_err[1] <= 1; f_drop <= 1; end
                else begin
                  f_fix <= hcorr && hfix != {b[2], b[1], b[0]};
                  f_eccbit <= hcorr && hfix == {b[2], b[1], b[0]};
                  m_dt <= hfix[7:0]; m_wc <= hfix[23:8];
                  if (hfix[5:0] < 6'h10) begin
                    ph <= N; m_irq <= 0; lng <= 0;
                    if (hfix[5:0] == 6'h00) begin
                      m_act <= 1; m_fc <= m_fc + 1; m_lc <= 0; m_err <= {hcorr, 3'b0};
                    end else begin
                      if (hfix[5:0] == 6'h01) m_act <= 0;
                      if (hcorr) m_err[3] <= 1;
                    end
                  end else begin
                    if (hcorr) m_err[3] <= 1;
                    lng <= 1; wc <= int'(hfix[23:8]); c <= 16'hFFFF;
                    f_wc0 <= hfix[23:8] == 0; f_long_lb <= hfix[23:8] > LB;
                  end
                end
              end else if (nbyte < 4 + wc) begin
                c <= crc(c, nb);
                if (nbyte - 4 < LB) ln_new[nbyte - 4] <= nb;
              end else if (nbyte == 4 + wc) c_lo <= {8'h00, nb};
              else begin
                ph <= N;
                if ({nb, c_lo[7:0]} == c) begin
                  m_irq <= 0; m_lc <= m_lc + 1; m_len <= 16'(wc > LB ? LB : wc); ln <= ln_new;
                end else begin m_irq <= 1; m_err[0] <= 1; f_crc <= 1; end
              end
            end
          end
        end
      end
    end
  end

  `SVA_RST(a_reset_clear, !rst_n, !irq && !frame_active && frame_cnt == 0 && line_cnt == 0 && err_flags == 0 && lb_len == 0)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_frame, frame_active == m_act && frame_cnt == m_fc)
  `SVA_INV(a_line_cnt, line_cnt == m_lc)
  `SVA_INV(a_last_hdr, last_dt == m_dt && last_wc == m_wc)
  `SVA_INV(a_err_flags, err_flags == m_err)
  `SVA_INV(a_lb_len, lb_len == m_len)
  `SVA_IMP(a_line_data, 16'(lb_addr) < lb_len, lb_rdata == ln[lb_addr])

  `FC(header_bit_corrected, f_fix)
  `FC(ecc_byte_bit_corrected, f_eccbit)
  `FC(header_dropped, f_drop)
  `FC(crc_error, f_crc)
  `FC(abort_in_header, f_ab_hdr)
  `FC(abort_in_payload, f_ab_pay)
  `FC(abort_in_crc, f_ab_crc)
  `FC(second_packet_in_burst, f_multi)
  `FC(eot_trailer_ignored, f_junk)
  `FC(long_past_line_buffer, f_long_lb)
  `FC(long_wc0, f_wc0)
  `FC(sync_at_odd_offset, f_odd_sync)
  `FC(line_cnt_wrap, $past(line_cnt) == 16'hFFFF && line_cnt == 16'h0000)
  `FC(frame_cnt_wrap, $past(frame_cnt) == 16'hFFFF && frame_cnt == 16'h0000)
  `FC(fs_while_active, frame_active && frame_cnt != $past(frame_cnt))
  `FC_RST(reset_in_packet, rst_n && ph == P ##1 !rst_n)

  covergroup cg_hdr @(posedge clk iff (rst_n && ph == P && nbit == 7 && nbyte == 3 && hok));
    coverpoint hfix[5:0] { bins fs = {0}; bins fe = {1}; bins ls = {2}; bins le = {3};
                           bins gen = {[8:15]}; bins rsvd_short = {[4:7]}; bins lng = {[16:63]}; }
    cp_vc: coverpoint hfix[7:6];
    cp_kind: coverpoint hfix[5:0] { bins fs = {0}; bins fe = {1}; bins ls_le = {[2:3]}; bins short_ = {[4:15]}; bins lng = {[16:63]}; }
    x_vc_kind: cross cp_vc, cp_kind;
    cp_corr: coverpoint {hcorr, hfix != {b[2], b[1], b[0]}} { bins clean = {2'b00}; bins ecc_bit = {2'b10}; bins data_bit = {2'b11}; }
    cp_wc: coverpoint hfix[23:8] iff (hfix[5:0] >= 6'h10) { bins zero = {0}; bins one = {1}; bins few = {[2:15]};
                                                             bins mid = {[16:LB-1]}; bins full = {LB}; bins over = {[LB+1:16'hFFFF]}; }
  endgroup
  cg_hdr u_cg = new();
  // long-packet payload: every byte value, first / middle / last position,
  // CRC verdict per length class
  covergroup cg_pay @(posedge clk iff (rst_n && rx_valid && bdone && ph == P && lng && nbyte >= 4 && nbyte < 4 + wc));
    cp_byte: coverpoint nb { bins v[] = {[0:255]}; }
    cp_pos: coverpoint (nbyte == 4 ? 0 : nbyte == 3 + wc ? 2 : 1) { bins first = {0}; bins middle = {1}; bins last = {2}; }
  endgroup
  cg_pay u_cg_pay = new();
  covergroup cg_crc @(posedge clk iff (rst_n && rx_valid && bdone && ph == P && lng && nbyte == 5 + wc));
    cp_ok: coverpoint {nb, c_lo[7:0]} == c { bins bad = {0}; bins good = {1}; }
    cp_len: coverpoint (wc == 0 ? 0 : wc <= 16 ? 1 : wc <= LB ? 2 : 3) { bins zero = {0}; bins short_ = {1}; bins mid = {2}; bins over = {3}; }
    x_crc: cross cp_ok, cp_len;
  endgroup
  cg_crc u_cg_crc = new();
endmodule

bind CSI_2_top CSI_2_sva #(.LINE_BYTES(LINE_BYTES)) u_sva (.*);
