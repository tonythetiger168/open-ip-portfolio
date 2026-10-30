// SPDX-License-Identifier: Apache-2.0
// xSPI 8D-8D-8D NOR target: concurrent SVA against an edge-counting model
// of the device (shadow array, page buffer, WEL / WIP with the exact busy
// time, dummy setting, RESET ENABLE, error codes) + functional coverage.
`include "cov_macros.svh"
module xSPI_sva #(parameter int MEM_AW = 9, PAGE_AW = 5, SECT_AW = 7, parameter logic [4:0] DUMMY = 5'd8) (
  input logic       clk, rst_n, ck, csn,
  input logic [7:0] dq_i, dq_o,
  input logic [1:0] sr,
  input logic       dq_oe, dqs_o, dqs_oe,
  input logic [4:0] dummy,
  input logic [2:0] err_code,
  input logic       irq_cmd, irq_done, irq_err
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int MEM = 1 << MEM_AW, PAGE = 1 << PAGE_AW, SECT = 1 << SECT_AW;

  // ---------------- reference model ----------------
  logic [7:0] shadow [0:MEM-1];
  initial for (int i = 0; i < MEM; i++) shadow[i] = '0;
  logic [7:0] m_pb [0:PAGE-1];
  logic [PAGE-1:0] m_pv;
  logic ck_q, cs_q;
  int   n;                                 // edges in this frame (saturates)
  logic [7:0] c;                           // the command
  logic hok, bad;                          // header accepted / frame already in error
  logic m_wel, m_wip, m_rsten, m_got;
  logic [4:0] m_dummy, m_crv;
  logic [2:0] m_err;
  logic [MEM_AW-1:0] m_a, m_bp;            // address of the next byte; busy pointer
  logic m_bpp;                             // busy with a program (else an erase)
  int   m_bl, m_rn, m_wn;                  // busy clocks left, read bytes sent, write bytes taken
  logic m_icmd, m_idone, m_ierr, m_dq_oe, m_dqs_oe, m_dqs;
  logic [7:0] m_dq;

  wire e   = !csn && ck != ck_q;
  wire fin = csn && !cs_q;
  wire is_rd   = c == 8'h05 || c == 8'h9F || c == 8'hEE || c == 8'h85;
  wire is_wr   = c == 8'h12 || c == 8'h81;
  wire has_adr = is_rd || is_wr || c == 8'h21;
  function automatic logic [7:0] rdat(input logic [7:0] cm, input int j, input logic [MEM_AW-1:0] a,
                                      input logic [7:0] s, input logic [4:0] d);
    case (cm)
      8'h05: return s;
      8'h85: return {3'b000, d};
      8'h9F: return j % 4 == 0 ? 8'h4F : j % 4 == 1 ? 8'h58 : j % 4 == 2 ? 8'(MEM_AW) : 8'h00;
      default: return shadow[a];
    endcase
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ck_q <= 0; cs_q <= 1; n <= 0; c <= 0; hok <= 0; bad <= 0; m_wel <= 0; m_wip <= 0; m_rsten <= 0;
      m_got <= 0; m_dummy <= DUMMY; m_crv <= 0; m_err <= 0; m_a <= 0; m_bl <= 0; m_rn <= 0; m_wn <= 0; m_bp <= 0; m_bpp <= 0;
      m_icmd <= 0; m_idone <= 0; m_ierr <= 0; m_dq_oe <= 0; m_dqs_oe <= 0; m_dqs <= 0; m_dq <= 0; m_pv <= 0;
    end else begin
      ck_q <= ck; cs_q <= csn;
      m_icmd <= 0; m_idone <= 0; m_ierr <= 0;
      if (m_wip) begin                     // one array byte per busy clock
        if (!m_bpp) shadow[m_bp] <= 8'hFF;
        else if (m_pv[m_bp[PAGE_AW-1:0]]) shadow[m_bp] <= shadow[m_bp] & m_pb[m_bp[PAGE_AW-1:0]];
        m_bp <= m_bp + 1;
        m_bl <= m_bl - 1;
        if (m_bl == 1) begin m_wip <= 0; m_wel <= 0; m_idone <= 1; end
      end
      if (e) begin
        if (n < 1 << 20) n <= n + 1;
        if (n == 0) c <= dq_i;
        else if (n == 1) begin
          bad <= 1; m_ierr <= 1;
          if (dq_i != ~c) m_err <= 1;
          else if (!(is_rd || is_wr || c == 8'h21 || c == 8'h06 || c == 8'h04 || c == 8'h60 || c == 8'h66 || c == 8'h99)) m_err <= 2;
          else if (m_wip && c != 8'h05) m_err <= 3;
          else if ((is_wr || c == 8'h21 || c == 8'h60) && !m_wel) m_err <= 4;
          else if (c == 8'h99 && !m_rsten) m_err <= 7;
          else begin bad <= 0; m_ierr <= 0; hok <= 1; m_got <= 0; m_rn <= 0; m_wn <= 0; if (c == 8'h12) m_pv <= 0; end
        end else if (hok && !bad) begin
          if ((!has_adr && n >= 2) || (c == 8'h21 && n >= 6)) begin bad <= 1; m_ierr <= 1; m_err <= 5; end
          if (n == 4) m_a <= MEM_AW'({dq_i, 8'h00});
          if (n == 5) begin m_a[7:0] <= {dq_i[7:1], 1'b0}; if (is_rd) m_dqs_oe <= 1; end
          if (is_rd && n == 5 + 2 * m_dummy) m_dq_oe <= 1;
          if (is_rd && n >= 6 + 2 * m_dummy) begin
            m_dq <= rdat(c, m_rn, m_a, {6'b0, m_wel, m_wip}, m_dummy); m_dqs <= !m_dqs; m_a <= m_a + 1; m_rn <= m_rn + 1;
          end
          if (is_wr && n >= 6) begin
            m_got <= 1; m_wn <= m_wn + 1;
            if (c == 8'h81 && !m_got) m_crv <= dq_i[4:0];
            if (c == 8'h12) begin
              m_pb[m_a[PAGE_AW-1:0]] <= dq_i; m_pv[m_a[PAGE_AW-1:0]] <= 1;
              m_a[PAGE_AW-1:0] <= m_a[PAGE_AW-1:0] + 1;
            end
          end
        end
      end
      if (fin) begin
        n <= 0; hok <= 0; bad <= 0; m_dq_oe <= 0; m_dqs_oe <= 0; m_dqs <= 0;
        if (n != 0 && !bad) begin
          if (n % 2 || (has_adr && n < 6) || (is_wr && !m_got)) begin m_ierr <= 1; m_err <= 5; end
          else if (c == 8'h81 && m_crv < 4) begin m_ierr <= 1; m_err <= 6; end
          else begin
            m_icmd <= 1; m_rsten <= c == 8'h66;
            case (c)
              8'h06: m_wel <= 1;
              8'h04: m_wel <= 0;
              8'h81: begin m_dummy <= m_crv; m_wel <= 0; end
              8'h99: begin m_dummy <= DUMMY; m_wel <= 0; end
              8'h12: begin m_wip <= 1; m_bl <= PAGE; m_bpp <= 1; m_bp <= {m_a[MEM_AW-1:PAGE_AW], PAGE_AW'(0)}; end
              8'h21: begin m_wip <= 1; m_bl <= SECT; m_bpp <= 0; m_bp <= {m_a[MEM_AW-1:SECT_AW], SECT_AW'(0)}; end
              8'h60: begin m_wip <= 1; m_bl <= MEM;  m_bpp <= 0; m_bp <= '0; end
              default: ;
            endcase
          end
        end
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_sr, sr == {m_wel, m_wip})
  `SVA_INV(a_dummy, dummy == m_dummy && err_code == m_err)
  `SVA_INV(a_irq, irq_cmd == m_icmd && irq_err == m_ierr && irq_done == m_idone)
  `SVA_INV(a_drivers, dq_oe == m_dq_oe && dqs_oe == m_dqs_oe)
  `SVA_IMP(a_dqs, dqs_oe, dqs_o == m_dqs)
  `SVA_IMP(a_read_data, dq_oe && m_rn != 0, dq_o == m_dq)
  `SVA_IMP(a_quiet_cs_high, csn && cs_q, !dq_oe && !dqs_oe)
  `SVA_INV(a_no_x, !$isunknown({dq_oe, dqs_oe, dqs_o, sr, dummy, err_code, irq_cmd, irq_done, irq_err}))
  `SVA_RST(a_rst, 1'b1, !dq_oe && !dqs_oe && !dqs_o && sr == 2'b00 && dummy == DUMMY && err_code == 0 &&
           !irq_cmd && !irq_done && !irq_err)

  // ---------------- functional coverage ----------------
  // classes computed at the clock edge, sampled half a clock later (-1: none)
  int k_acc, k_err, k_rd, k_pp, k_dm, k_busy;
  always @(posedge clk) begin
    k_acc = -1; k_err = -1; k_rd = -1; k_pp = -1; k_dm = -1; k_busy = -1;
    if (rst_n && fin && n != 0 && !bad && !(n % 2 || (has_adr && n < 6) || (is_wr && !m_got)) &&
        !(c == 8'h81 && m_crv < 4)) begin
      case (c)
        8'h06: k_acc = 0; 8'h04: k_acc = 1; 8'h05: k_acc = 2; 8'h9F: k_acc = 3; 8'hEE: k_acc = 4;
        8'h12: k_acc = 5; 8'h21: k_acc = 6; 8'h60: k_acc = 7; 8'h81: k_acc = 8; 8'h85: k_acc = 9;
        8'h66: k_acc = 10; default: k_acc = 11;
      endcase
      // read kind x length: none, 2, 4..8, 10..64, more (reads end on a whole CK cycle)
      if (is_rd) k_rd = 5 * (c == 8'h05 ? 0 : c == 8'h9F ? 1 : c == 8'hEE ? 2 : 3) +
                        (m_rn == 0 ? 0 : m_rn == 2 ? 1 : m_rn <= 8 ? 2 : m_rn <= 64 ? 3 : 4);
      if (c == 8'h12) k_pp = m_wn == 2 ? 0 : m_wn < PAGE ? 1 : m_wn == PAGE ? 2 : 3;
      if (c == 8'hEE) k_dm = m_dummy == 4 ? 0 : m_dummy < 8 ? 1 : m_dummy == 8 ? 2 : m_dummy < 16 ? 3 : m_dummy < 31 ? 4 : 5;
    end
    if (rst_n && irq_err) k_err = err_code;
    if (rst_n && e && n == 1 && m_wip) k_busy = c == 8'h05;
  end
  covergroup cg_xspi @(negedge clk);
    option.per_instance = 1;
    cp_cmd: coverpoint k_acc
      { bins wren = {0}; bins wrdi = {1}; bins rdsr = {2}; bins rdid = {3}; bins read = {4}; bins pp = {5};
        bins se = {6}; bins ce = {7}; bins wrcr = {8}; bins rdcr = {9}; bins rsten = {10}; bins rst = {11}; }
    cp_err: coverpoint k_err
      { bins ext = {1}; bins unknown = {2}; bins busy = {3}; bins no_wel = {4}; bins frame = {5}; bins cfg = {6}; bins rst = {7}; }
    cp_read: coverpoint k_rd { bins kind_len[] = {[0:19]}; }
    cp_pp_len: coverpoint k_pp { bins two = {0}; bins part = {1}; bins page = {2}; bins wrap = {3}; }
    cp_dummy: coverpoint k_dm { bins min = {0}; bins low = {1}; bins dflt = {2}; bins mid = {3}; bins high = {4}; bins max = {5}; }
    cp_busy: coverpoint k_busy { bins other = {0}; bins rdsr = {1}; }
  endgroup
  cg_xspi u_cg_xspi = new;

  `FC(read_wraps_array, e && hok && !bad && c == 8'hEE && n >= 6 + 2 * m_dummy && m_a == MEM_AW'(MEM - 1))
  `FC(pp_wraps_page, e && hok && !bad && c == 8'h12 && m_wn == PAGE)
  `FC(nor_program_keeps_zeros, e && hok && !bad && c == 8'h12 && n >= 6 && (shadow[m_a] & dq_i) != dq_i)
  `FC(rdsr_sees_wip_fall, irq_done && dqs_oe)
  `FC(rst_after_rsten, fin && hok && !bad && c == 8'h99 && n == 2)
  `FC(read_cut_in_latency, fin && hok && !bad && is_rd && n >= 6 && n < 6 + 2 * m_dummy && n % 2 == 0)
  `FC(odd_end, fin && hok && !bad && n % 2 == 1)
  `FC_RST(reset_in_frame, rst_n && !csn && n > 1 ##1 !rst_n)
  `FC_RST(reset_in_busy, rst_n && m_wip ##1 !rst_n)
endmodule

bind xSPI_top xSPI_sva #(.MEM_AW(MEM_AW), .PAGE_AW(PAGE_AW), .SECT_AW(SECT_AW), .DUMMY(DUMMY)) u_sva (.*);
