// SPDX-License-Identifier: Apache-2.0
// QSPI_XIP (quad-SPI NOR flash host with execute-in-place): concurrent SVA
// against an independent decoder of the flash pins, + functional coverage.
// The decoder watches CSN / SCLK / IO (SPI mode 0: every bit is taken at an
// SCLK rise) and splits each chip-select frame into command, address,
// dummy, write and read phases from the job's own parameters: XIP reads are
// 0x6B (QUAD: data on IO3..0, a nibble per clock) or 0x0B (data on IO1) with
// a 24-bit address and 8 dummy clocks; command-port jobs are PC_CMD, the
// optional PC_ADDR, PC_NWR bytes of PC_WDATA (byte 0 first) and PC_NRD
// bytes in. From the decoded frames it checks the command, the address, the
// written bytes, the XIP read data of every R beat (the word holding the
// beat's address, little-endian), PC_RDATA, the SCLK half period (at least
// DIV + 1 clocks), mode 0 (CSN only moves with SCLK low), IO2 / IO3 high
// outside the quad phases, the AXI write path (SLVERR) and XIP_CMDS /
// XIP_BEATS.
`include "cov_macros.svh"
module QSPI_XIP_sva (
  input logic        clk, rst_n, sclk, csn, quad, pc_has_addr, pc_start, pc_busy, pc_done, pc_job,
  input logic [3:0]  io,
  input logic [7:0]  div, pc_cmd,
  input logic [23:0] pc_addr,
  input logic [2:0]  pc_nwr, pc_nrd,
  input logic [31:0] pc_wdata, pc_rdata,
  input logic [15:0] xip_cmds, xip_beats,
  input logic [3:0]  s_awid, s_bid, s_arid, s_rid,
  input logic        s_awvalid, s_awready, s_wvalid, s_wready, s_wlast, s_bvalid, s_bready,
  input logic [1:0]  s_bresp, s_rresp, s_arburst,
  input logic [31:0] s_araddr, s_rdata,
  input logic [7:0]  s_arlen,
  input logic [2:0]  s_arsize,
  input logic        s_arvalid, s_arready, s_rvalid, s_rready, s_rlast,
  input logic        s_open, w_last_v,         // the XIP stream is open; a word is at hand
  input logic [21:0] s_next, w_last_a
);
  `COV_CLOCKING(clk, !rst_n)
  // ---------------------------------------------------------------- decoder
  logic        sclk_q, csn_q;
  logic [3:0]  io_q;
  wire         rise = sclk && !sclk_q && !csn;
  // frame parameters, fixed at CS fall
  logic        f_pc, f_q, f_ha;
  logic [2:0]  f_nwr, f_nrd;
  logic [7:0]  f_cmd_exp;
  logic [23:0] f_addr_exp;
  logic [31:0] f_wdata;
  // decoded so far
  int          k;                    // SCLK rises in this frame
  logic [7:0]  d_cmd;
  logic [23:0] d_addr;
  logic [7:0]  d_byte;
  int          d_bits, d_n;          // bits of the byte being read; bytes read
  logic [31:0] d_wr;
  logic [31:0] d_pc;
  logic [31:0] w_map [logic [21:0]];  // XIP: words read in this frame
  logic [31:0] d_word;
  logic        f_cmd_ok, f_addr_ok, f_wr_ok;
  int          n_cmd_end, n_addr_end, n_dmy_end, n_wr_end;
  logic [15:0] m_cmds;

  // job parameters at CS fall (the XIP word address is the next one asked)
  logic [31:0] a_q;                  // address of the current XIP beat
  wire  [21:0] x_wa = a_q[23:2];
  // the beat address an XIP R beat is for (AXI4 A3.4.1)
  logic [31:0] b_start, b_a;
  logic [7:0]  b_len, b_n;
  logic [2:0]  b_sz;
  logic [1:0]  b_bt;
  function automatic logic [31:0] beat_addr(input logic [31:0] s, input logic [2:0] sz,
                                            input logic [1:0] bt, input logic [7:0] len, input logic [7:0] n);
    logic [32:0] nb, al, ws, lo, a;
    nb = 33'd1 << sz; al = {1'b0, s} & ~(nb - 1);
    if (bt == 0 || n == 0) return s;
    a = al + 33'(n) * nb;
    if (bt == 2) begin ws = nb * (33'(len) + 1); lo = {1'b0, s} & ~(ws - 1); if (a >= lo + ws) a = a - ws; end
    return a[31:0];
  endfunction
  always_comb a_q = beat_addr(b_start, b_sz, b_bt, b_len, b_n);
  logic [7:0]  m_hc;                 // clocks since SCLK last moved

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_q <= 0; csn_q <= 1; io_q <= 0; f_pc <= 0; f_q <= 0; f_ha <= 0; f_nwr <= 0; f_nrd <= 0;
      f_cmd_exp <= 0; f_addr_exp <= 0; f_wdata <= 0; k <= 0; d_cmd <= 0; d_addr <= 0; d_byte <= 0;
      d_bits <= 0; d_n <= 0; d_wr <= 0; d_pc <= 0; w_map.delete(); m_cmds <= 0; m_hc <= 0;
      b_start <= 0; b_len <= 0; b_n <= 0; b_sz <= 0; b_bt <= 0;
      n_cmd_end <= 8; n_addr_end <= 8; n_dmy_end <= 8; n_wr_end <= 8;
    end else begin
      sclk_q <= sclk; csn_q <= csn; io_q <= io;
      m_hc <= (sclk != sclk_q) ? 8'd0 : (m_hc == 8'hFF ? m_hc : m_hc + 1);
      if (s_arvalid && s_arready) begin
        b_start <= s_araddr; b_len <= s_arlen; b_sz <= s_arsize; b_bt <= s_arburst; b_n <= 0;
      end
      if (s_rvalid && s_rready) b_n <= b_n + 1;
      // CS fall: a new frame
      if (!csn && csn_q) begin
        int na;
        f_pc <= pc_job; k <= 0; d_bits <= 0; d_n <= 0; d_pc <= 0; d_wr <= 0; w_map.delete();
        if (pc_job) begin
          f_cmd_exp <= pc_cmd; f_ha <= pc_has_addr; f_addr_exp <= pc_addr; f_nwr <= pc_nwr;
          f_nrd <= pc_nrd > 4 ? 3'd4 : pc_nrd; f_wdata <= pc_wdata; f_q <= 0;
          na = pc_has_addr ? 24 : 0;
          n_cmd_end <= 8; n_addr_end <= 8 + na; n_dmy_end <= 8 + na; n_wr_end <= 8 + na + 8 * pc_nwr;
        end else begin
          f_cmd_exp <= quad ? 8'h6B : 8'h0B; f_ha <= 1; f_addr_exp <= {x_wa, 2'b00}; f_nwr <= 0; f_nrd <= 0;
          f_q <= quad; m_cmds <= m_cmds + 1;
          n_cmd_end <= 8; n_addr_end <= 32; n_dmy_end <= 40; n_wr_end <= 40;
        end
      end
      // SCLK rises (the bit is the IO value at the rising clock)
      if (sclk && !sclk_q && !csn) begin
        k <= k + 1;
        if (k < n_cmd_end) d_cmd <= {d_cmd[6:0], io_q[0]};
        else if (k < n_addr_end) d_addr <= {d_addr[22:0], io_q[0]};
        else if (k < n_dmy_end) ;
        else if (k < n_wr_end) d_wr <= {d_wr[30:0], io_q[0]};
        else begin
          logic [7:0] b;
          logic done_b;
          if (f_q) begin b = {d_byte[3:0], io_q}; done_b = d_bits == 1; end
          else begin b = {d_byte[6:0], io_q[1]}; done_b = d_bits == 7; end
          d_byte <= b;
          if (done_b) begin
            d_bits <= 0; d_n <= d_n + 1;
            if (f_pc) begin if (d_n < 4) d_pc[8 * d_n +: 8] <= b; end
            else begin
              logic [21:0] wa;
              wa = f_addr_exp[23:2] + 22'(d_n / 4);
              d_word[8 * (d_n % 4) +: 8] = b;
              if (d_n % 4 == 3) w_map[wa] = d_word;
            end
          end else d_bits <= d_bits + 1;
        end
      end
    end
  end
  logic [15:0] m_beats;
  always_ff @(posedge clk or negedge rst_n) if (!rst_n) m_beats <= 0; else if (s_rvalid && s_rready) m_beats <= m_beats + 1;

  wire in_quad = f_q && !csn && k >= n_addr_end;      // dummy and data clocks of a quad read
  `SVA_RST(a_reset_idle, !rst_n, csn && !sclk && !pc_busy && !s_rvalid && !s_bvalid && xip_cmds == 0 && xip_beats == 0)
  `SVA_IMP(a_cmd, rise && k == n_cmd_end, d_cmd == f_cmd_exp)
  `SVA_IMP(a_addr, rise && k == n_addr_end && n_addr_end != n_cmd_end, d_addr == f_addr_exp)
  `SVA_IMP(a_wdata, rise && k == n_wr_end && n_wr_end != n_dmy_end,
           d_wr == (f_nwr == 1 ? 32'(f_wdata[7:0]) : f_nwr == 2 ? 32'({f_wdata[7:0], f_wdata[15:8]})
                  : f_nwr == 3 ? 32'({f_wdata[7:0], f_wdata[15:8], f_wdata[23:16]})
                  : {f_wdata[7:0], f_wdata[15:8], f_wdata[23:16], f_wdata[31:24]}))
  `SVA_IMP(a_pc_len, $rose(csn) && f_pc, k == n_wr_end + 8 * f_nrd)
  `SVA_IMP(a_pc_rdata, pc_done, pc_rdata == d_pc)
  `SVA_IMP(a_xip_rdata, s_rvalid, w_map.exists(a_q[23:2]) && s_rdata == w_map[a_q[23:2]] && s_rresp == 2'b00
                                  && s_rlast == (b_n == b_len))
  `SVA_IMP(a_half_period, sclk != sclk_q, m_hc >= div)
  `SVA_INV(a_mode0, (csn != csn_q) -> !sclk && !sclk_q)
  `SVA_INV(a_wp_hold_high, !in_quad -> io[3:2] == 2'b11)
  `SVA_INV(a_counters, xip_cmds == m_cmds && xip_beats == m_beats)
  `SVA_INV(a_pc_busy, pc_busy -> !(s_arready))
  `SVA_IMP(a_axi_write, s_bvalid, s_bresp == 2'b10)

  covergroup cg_qspi @(posedge clk);
    option.per_instance = 1;
    cp_xip_mode: coverpoint quad iff (rst_n && !csn && csn_q && !pc_job);
    cp_pc: coverpoint {pc_has_addr, pc_nwr != 0, pc_nrd != 0} iff (rst_n && pc_start && !pc_busy);
    cp_nwr: coverpoint pc_nwr iff (rst_n && pc_start && !pc_busy) { bins n[] = {[0:4]}; }
    cp_nrd: coverpoint pc_nrd iff (rst_n && pc_start && !pc_busy) { bins n[] = {[0:4]}; bins clamp = {[5:7]}; }
    cp_burst: coverpoint {s_arburst, s_arsize[1:0]} iff (rst_n && s_arvalid && s_arready && s_arsize <= 2)
      { bins fixed[] = {0, 1, 2}; bins incr[] = {4, 5, 6}; bins wrap[] = {8, 9, 10}; }
    cp_next: coverpoint u_xip_path iff (rst_n && s_arvalid && s_arready)
      { bins word_at_hand = {0}; bins continue_ = {1}; bins close_reopen = {2}; bins open_ = {3}; }
    cp_div: coverpoint div iff (rst_n && !csn && csn_q) { bins zero = {0}; bins small_ = {[1:3]}; bins big = {[4:255]}; }
  endgroup
  cg_qspi u_cg_qspi = new;
  wire [1:0] u_xip_path = (w_last_v && w_last_a == s_araddr[23:2]) ? 2'd0 : (s_open && s_next == s_araddr[23:2]) ? 2'd1
                        : s_open ? 2'd2 : 2'd3;

  `FC(sclk_held_by_rready, s_rvalid && !s_rready && !csn)
  `FC(cmd_waits_for_xip, pc_busy && s_rvalid)
  `FC(xip_waits_for_cmd, s_arvalid && !s_arready && pc_busy)
  `FC(cmd_closes_stream, pc_busy && s_open && !s_rvalid && !s_arvalid)
  `FC(same_word_beats, s_rvalid && s_rready && !s_rlast ##1 s_rvalid)
  `FC(write_slverr, s_bvalid && s_bready)
  `FC(write_beats, s_wvalid && s_wready && !s_wlast)
  `FC_RST(reset_mid_frame, rst_n && !csn ##1 !rst_n)
endmodule

bind QSPI_XIP_top QSPI_XIP_sva u_sva (.*);
