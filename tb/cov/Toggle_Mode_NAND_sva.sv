// SPDX-License-Identifier: Apache-2.0
// Toggle-mode NAND target: a pin-level model samples ce_n / cle / ale /
// we_n / re_n / dq / dqs through its own synchronizers, decodes the command
// and address cycles, runs the busy timer for read / program / erase /
// reset, keeps a shadow of the array and of the page buffer, and predicts
// rb_n, irq, the dq / dqs drivers (enable and value) and the array.
`include "cov_macros.svh"
module Toggle_Mode_NAND_sva #(
  parameter int T_R = 25, T_PROG = 200, T_ERASE = 1000, T_RST = 5
)(
  input logic       clk, rst_n, ce_n, cle, ale, we_n, re_n, rb_n, irq, drive_en,
  input wire  [7:0] dq,
  input wire        dqs,
  input logic [7:0] mem [0:1023]
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [39:0] ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};
  localparam int M_CMD = 0, M_RID = 1, M_ADDR = 2, M_W30 = 3, M_DIN = 4, M_EADDR = 5, M_WD0 = 6;
  localparam int O_NONE = 0, O_ID = 1, O_STAT = 2, O_DATA = 3;
  localparam int P_RD = 0, P_PROG = 1, P_ERASE = 2, P_RST = 3;

  logic [2:0] w, r, s;
  logic [1:0] c, l, a;
  logic [7:0] d0, d1;
  int         md, om, op, cnt, na, ptr, col, pg;
  logic       bsy, rd, fl, st, av, m_irq;
  logic [7:0] sh [0:1023];
  logic [7:0] pb [0:63];

  wire on    = !c[1];
  wire wr    = w[2:1] == 2'b01 && on;
  wire lc    = wr && l[1];
  wire la    = wr && !l[1] && a[1];
  wire idle  = md == M_CMD || (md == M_ADDR && na == 0 && av);
  wire drv   = om != O_NONE && st && on && !cle && !ale;
  wire [7:0] stat = {1'b1, !bsy, !bsy, 4'b0000, fl};
  wire [7:0] ob   = om == O_ID ? ID[39 - 8 * (ptr % 5) -: 8] : om == O_STAT ? stat : pb[ptr];
  wire prot  = pg / 4 == 3;

  // coverage strobes
  logic vid, vrd, vpg, ver, vpf, vef, vbs, vret, vunk, vseq, vadr, vwb, vrp, vre, vrr, vwrap, vbrk;
  // registered copies for the covergroup: completed operation and page,
  // start column, data-in / data-out / status bytes
  logic       c_ov, c_cv, c_crd, c_wv, c_rv, c_sv;
  int         c_op, c_pg, c_col;
  logic [7:0] c_wd, c_rd;
  logic [1:0] c_st;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w <= '1; r <= '1; s <= '0; c <= '1; l <= '0; a <= '0; d0 <= 0; d1 <= 0;
      md <= M_CMD; om <= O_NONE; op <= P_RST; cnt <= 0; na <= 0; ptr <= 0; col <= 0; pg <= 0;
      bsy <= 0; rd <= 0; fl <= 0; st <= 0; av <= 0; m_irq <= 0;
      for (int i = 0; i < 1024; i++) sh[i] <= 8'hFF;
      for (int i = 0; i < 64; i++) pb[i] <= 8'hFF;
      {vid, vrd, vpg, ver, vpf, vef, vbs, vret, vunk, vseq, vadr, vwb, vrp, vre, vrr, vwrap, vbrk} <= '0;
      {c_ov, c_cv, c_crd, c_wv, c_rv, c_sv} <= '0; c_op <= 0; c_pg <= 0; c_col <= 0; c_wd <= 0; c_rd <= 0; c_st <= 0;
    end else begin
      {c_ov, c_cv, c_wv, c_rv, c_sv} <= '0;
      {vid, vrd, vpg, ver, vpf, vef, vbs, vret, vunk, vseq, vadr, vwb, vrp, vre, vrr, vwrap, vbrk} <= '0;
      w <= {w[1:0], we_n}; r <= {r[1:0], re_n}; s <= {s[1:0], dqs};
      c <= {c[0], ce_n}; l <= {l[0], cle}; a <= {a[0], ale}; d0 <= dq; d1 <= d0;

      if (r[2] != r[1] && on && om != O_NONE) begin
        if (!st) st <= !r[1];
        else if (om == O_ID) ptr <= (ptr + 1) % 5;
        else if (om == O_DATA) begin ptr <= (ptr + 1) % 64; vwrap <= ptr == 63; c_rv <= 1; c_rd <= pb[ptr]; end
        if (st && om == O_STAT) begin c_sv <= 1; c_st <= {bsy, fl}; end
      end
      if (s[2] != s[1] && on && md == M_DIN && !drv) begin pb[ptr] <= d1; ptr <= (ptr + 1) % 64; c_wv <= 1; c_wd <= d1; end

      if (bsy) begin
        if (cnt > 0) cnt <= cnt - 1;
        else begin
          bsy <= 0;
          c_ov <= op != P_RST; c_op <= op; c_pg <= op == P_ERASE ? pg / 4 : pg;
          if (op == P_RD) begin
            av <= 1;
            if (om != O_STAT) begin om <= O_DATA; ptr <= col; st <= 0; end
          end else if (op == P_PROG) begin
            if (prot) begin fl <= 1; vpf <= 1; end
            else begin for (int i = 0; i < 64; i++) sh[pg * 64 + i] <= sh[pg * 64 + i] & pb[i]; vpg <= 1; end
          end else if (op == P_ERASE) begin
            if (prot) begin fl <= 1; vef <= 1; end
            else begin for (int i = 0; i < 256; i++) sh[(pg / 4) * 256 + i] <= 8'hFF; ver <= 1; end
          end
        end
      end

      if (lc) begin
        if (d1 == 8'hFF) begin
          md <= M_CMD; om <= O_NONE; bsy <= 1; op <= P_RST; cnt <= T_RST - 1; av <= 0; m_irq <= 0; fl <= 0;
          vrp <= bsy && op == P_PROG; vre <= bsy && op == P_ERASE; vrr <= bsy && op == P_RD;
        end else if (d1 == 8'h70) begin
          if (!idle) begin m_irq <= 1; vbrk <= 1; end
          md <= M_CMD; om <= O_STAT; st <= 0; vbs <= bsy;
        end else if (bsy) begin
          m_irq <= 1; vwb <= 1;
        end else begin
          om <= O_NONE; md <= M_CMD;
          if (d1 != 8'h00) av <= 0;
          if (idle) begin
            case (d1)
              8'h90: md <= M_RID;
              8'h00: begin
                md <= M_ADDR; rd <= 1; na <= 0;
                if (av) begin om <= O_DATA; ptr <= col; st <= 0; vret <= 1; end
              end
              8'h80: begin md <= M_ADDR; rd <= 0; na <= 0; fl <= 0; for (int i = 0; i < 64; i++) pb[i] <= 8'hFF; end
              8'h60: begin md <= M_EADDR; na <= 0; fl <= 0; end
              default: begin m_irq <= 1; vunk <= 1; end
            endcase
          end else if (md == M_W30 && d1 == 8'h30) begin
            bsy <= 1; op <= P_RD; cnt <= T_R - 1; fl <= 0; vrd <= 1;
            for (int i = 0; i < 64; i++) pb[i] <= sh[pg * 64 + i];
          end else if (md == M_DIN && d1 == 8'h10) begin
            bsy <= 1; op <= P_PROG; cnt <= T_PROG - 1;
          end else if (md == M_WD0 && d1 == 8'hD0) begin
            bsy <= 1; op <= P_ERASE; cnt <= T_ERASE - 1;
          end else begin m_irq <= 1; vseq <= 1; end
        end
      end else if (la) begin
        if (md == M_RID) begin md <= M_CMD; om <= O_ID; ptr <= 0; st <= 0; vid <= 1; end
        else if (md == M_ADDR) begin
          om <= O_NONE; av <= 0;
          if (na == 0) col <= d1 % 64;
          if (na == 2) pg <= d1 % 16;
          na <= na + 1;
          if (na == 4) begin md <= rd ? M_W30 : M_DIN; ptr <= col; c_cv <= 1; c_crd <= rd; c_col <= col; end
        end else if (md == M_EADDR) begin
          if (na == 0) pg <= d1 % 16;
          na <= na + 1;
          if (na == 2) md <= M_WD0;
        end else begin m_irq <= 1; vadr <= 1; end
      end
    end
  end

  logic mem_ok;
  always_comb begin
    mem_ok = 1;
    for (int i = 0; i < 1024; i++) if (mem[i] != sh[i]) mem_ok = 0;
  end

  `SVA_RST(a_reset_state, !rst_n, rb_n && !irq && !drive_en)
  `SVA_INV(a_rb_n, rb_n == !bsy)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_drive_enable, drive_en == drv)
  `SVA_IMP(a_dq_value, drv, dq == ob)
  `SVA_IMP(a_dqs_echo, drv, dqs == r[1])
  `SVA_INV(a_array, mem_ok)

  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : (v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA ? 2 : 3));
  endfunction
  covergroup cg_nand @(negedge clk);
    option.per_instance = 1;
    cp_opg: coverpoint c_op * 16 + c_pg iff (rst_n && c_ov)
      { bins read_page[] = {[0:15]}; bins prog_page[] = {[16:31]}; bins erase_block[] = {[32:35]}; }
    cp_col: coverpoint int'(c_crd) * 4 + (c_col == 0 ? 0 : (c_col == 63 ? 2 : 1)) iff (rst_n && c_cv)
      { bins prog_first = {0}; bins prog_mid = {1}; bins prog_last = {2};
        bins read_first = {4}; bins read_mid = {5}; bins read_last = {6}; }
    cp_din: coverpoint dcls(c_wd) iff (rst_n && c_wv) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_dout: coverpoint dcls(c_rd) iff (rst_n && c_rv) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_status: coverpoint c_st iff (rst_n && c_sv) { bins ready_ok = {2'b00}; bins ready_fail = {2'b01}; bins busy = {2'b10}; }
  endgroup
  cg_nand u_cg_nand = new;

  `FC(read_id, vid)
  `FC(read_id_wraps, drv && om == O_ID && ptr == 4 ##[1:20] drv && om == O_ID && ptr == 0)
  `FC(page_read, vrd)
  `FC(read_data_wraps_page, vwrap)
  `FC(page_program, vpg)
  `FC(block_erase, ver)
  `FC(program_protected_fail, vpf)
  `FC(erase_protected_fail, vef)
  `FC(status_while_busy, vbs)
  `FC(status_breaks_sequence, vbrk)
  `FC(return_to_data_00h, vret)
  `FC(unknown_command, vunk)
  `FC(command_out_of_sequence, vseq)
  `FC(address_out_of_place, vadr)
  `FC(command_while_busy, vwb)
  `FC(reset_during_program, vrp)
  `FC(reset_during_erase, vre)
  `FC(reset_during_read, vrr)
  `FC(data_in_full_page, md == M_DIN && ptr == 63 ##1 md == M_DIN && ptr == 0)
  `FC(output_released_by_cle, drv ##1 !drv && cle)
  `FC(output_released_by_ale, drv ##1 !drv && ale)
  `FC_RST(reset_while_busy, rst_n && bsy ##1 !rst_n)
endmodule

bind Toggle_Mode_NAND_top Toggle_Mode_NAND_sva #(.T_R(T_R), .T_PROG(T_PROG), .T_ERASE(T_ERASE), .T_RST(T_RST)) u_sva (.*);
