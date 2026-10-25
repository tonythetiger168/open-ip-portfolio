// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// DFI 5.0 PHY slice: a cycle-level model fed only by the pins predicts
// dfi_init_complete, dfi_lp_ctrl_ack, dfi_rddata_valid / dfi_rddata and irq
// on every clock. Timing is modelled as due times on a cycle counter: a WR
// books a write beat tphy_wrlat later, a RD a read-enable beat trddata_en
// later, and a taken read beat books its data tphy_rdlat later.
`include "cov_macros.svh"
module DFI_5_0__MC_PHY_Interface__sva #(
  parameter int T_PHY_WRLAT = 4, T_RDDATA_EN = 3, T_PHY_RDLAT = 5, INIT_CYCLES = 32
)(
  input logic        clk, rst_n,
  input logic [16:0] dfi_address,
  input logic [2:0]  dfi_bank,
  input logic        dfi_ras_n, dfi_cas_n, dfi_we_n, dfi_cs_n, dfi_cke,
  input logic        dfi_wrdata_en, dfi_rddata_en, dfi_init_start, dfi_lp_ctrl,
  input logic [31:0] dfi_wrdata,
  input logic [3:0]  dfi_wrdata_mask,
  input logic        dfi_rddata_valid, dfi_init_complete, dfi_lp_ctrl_ack, irq,
  input logic [31:0] dfi_rddata
);
  `COV_CLOCKING(clk, !rst_n)

  wire [2:0] c = {dfi_ras_n, dfi_cas_n, dfi_we_n};

  longint      n;                       // edges since reset
  // init: 0 idle, 1 running until t_init, 2 complete (held while start)
  int          ist;
  longint      t_init;
  logic        ready, start_q, m_cmp;
  // low power: 0 run, 1 requested (ack at t_lp), 2 asleep, 3 leaving (ack drops at t_lp)
  int          lst;
  longint      t_lp;
  logic        m_ack;
  logic        open_b [0:7];
  logic [1:0]  row_b  [0:7];
  logic [31:0] arr [0:255];
  // due slots
  logic        w_due [0:15], r_due [0:15], d_due [0:15];
  logic [7:0]  w_adr [0:15], r_adr [0:15];
  logic [31:0] d_dat [0:15];
  logic        m_v, m_irq;
  logic [31:0] m_d;

  logic v_act, v_rd, v_wr, v_pre1, v_preall, v_ref, v_mrs, v_ill_init, v_ill_lp, v_ill_cke,
        v_ill_act, v_ill_closed, v_ill_ref, v_w_miss, v_w_extra, v_r_miss, v_r_extra, v_mask,
        v_rw_same, v_reinit_open, v_short_start, v_lp, v_lp_short, v_b2b;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n = 0; ist = 0; t_init = 0; ready = 0; start_q = 0; m_cmp = 0;
      lst = 0; t_lp = 0; m_ack = 0; m_v = 0; m_d = 0; m_irq = 0;
      for (int b = 0; b < 8; b++) begin open_b[b] = 0; row_b[b] = 0; end
      for (int i = 0; i < 16; i++) begin w_due[i] = 0; r_due[i] = 0; d_due[i] = 0; end
    end else begin : step
      logic up, real_cmd, ok, wd, rd_due_now, rise, was_open;
      logic [7:0] a;
      int s;
      {v_act, v_rd, v_wr, v_pre1, v_preall, v_ref, v_mrs, v_ill_init, v_ill_lp, v_ill_cke,
       v_ill_act, v_ill_closed, v_ill_ref, v_w_miss, v_w_extra, v_r_miss, v_r_extra, v_mask,
       v_rw_same, v_reinit_open, v_short_start, v_lp, v_lp_short, v_b2b} = '0;
      s  = int'(n % 16);
      up = ready && !(lst == 1 || lst == 2) && dfi_cke;
      // ---- command
      real_cmd = !dfi_cs_n && c != 3'b111;
      a = {dfi_bank, row_b[dfi_bank], dfi_address[2:0]};
      ok = 0;
      was_open = 0;
      for (int b = 0; b < 8; b++) if (open_b[b]) was_open = 1;
      if (real_cmd && up) begin
        case (c)
          3'b011: if (!open_b[dfi_bank]) begin
            ok = 1; open_b[dfi_bank] = 1; row_b[dfi_bank] = dfi_address[1:0]; v_act = 1;
          end else v_ill_act = 1;
          3'b101: if (open_b[dfi_bank]) begin
            ok = 1; r_due[(s + T_RDDATA_EN) % 16] = 1; r_adr[(s + T_RDDATA_EN) % 16] = a; v_rd = 1;
          end else v_ill_closed = 1;
          3'b100: if (open_b[dfi_bank]) begin
            ok = 1; w_due[(s + T_PHY_WRLAT) % 16] = 1; w_adr[(s + T_PHY_WRLAT) % 16] = a; v_wr = 1;
          end else v_ill_closed = 1;
          3'b010: begin
            ok = 1;
            if (dfi_address[10]) begin for (int b = 0; b < 8; b++) open_b[b] = 0; v_preall = 1; end
            else begin open_b[dfi_bank] = 0; v_pre1 = 1; end
          end
          default: if (!was_open) begin ok = 1; v_ref = c == 3'b001; v_mrs = c == 3'b000; end
                   else v_ill_ref = 1;
        endcase
      end
      if (real_cmd && !up) begin
        v_ill_init = !ready; v_ill_lp = ready && (lst == 1 || lst == 2); v_ill_cke = ready && !dfi_cke;
      end
      if (real_cmd && !ok) m_irq = 1;
      // ---- beats: read (old data) before write
      rd_due_now = r_due[s];
      if (rd_due_now != dfi_rddata_en) begin
        m_irq = 1; v_r_miss = rd_due_now; v_r_extra = dfi_rddata_en;
      end
      if (rd_due_now && dfi_rddata_en) begin
        d_due[(s + T_PHY_RDLAT) % 16] = 1; d_dat[(s + T_PHY_RDLAT) % 16] = arr[r_adr[s]];
      end
      wd = w_due[s];
      if (wd != dfi_wrdata_en) begin m_irq = 1; v_w_miss = wd; v_w_extra = dfi_wrdata_en; end
      if (wd && dfi_wrdata_en) begin
        for (int i = 0; i < 4; i++)
          if (!dfi_wrdata_mask[i]) arr[w_adr[s]][8*i +: 8] = dfi_wrdata[8*i +: 8];
        v_mask = dfi_wrdata_mask != 0;
        v_rw_same = rd_due_now && dfi_rddata_en && r_adr[s] == w_adr[s];
      end
      v_b2b = v_rd && r_due[(s + T_RDDATA_EN + 15) % 16];
      r_due[s] = 0; w_due[s] = 0;
      m_v = d_due[s]; m_d = d_due[s] ? d_dat[s] : 32'd0; d_due[s] = 0;
      // ---- init handshake
      rise = dfi_init_start && !start_q;
      start_q = dfi_init_start;
      case (ist)
        0: if (rise) begin
          ist = 1; t_init = n + INIT_CYCLES; ready = 0;
          v_reinit_open = was_open;
          for (int b = 0; b < 8; b++) open_b[b] = 0;
        end
        1: begin
          if (!dfi_init_start) v_short_start = 1;
          if (n == t_init) begin ist = 2; m_cmp = 1; ready = 1; end
        end
        default: if (!dfi_init_start) begin ist = 0; m_cmp = 0; end
      endcase
      // ---- low power
      case (lst)
        0: if (dfi_lp_ctrl) begin lst = 1; t_lp = n + 2; end
        1: begin
          if (!dfi_lp_ctrl) v_lp_short = 1;
          if (n == t_lp) begin lst = 2; m_ack = 1; v_lp = 1; end
        end
        2: if (!dfi_lp_ctrl) begin lst = 3; t_lp = n + 2; end
        default: if (n == t_lp) begin lst = 0; m_ack = 0; end
      endcase
      n = n + 1;
    end
  end

  `SVA_RST(a_reset_outputs, !rst_n, !dfi_rddata_valid && dfi_rddata == 0 && !dfi_init_complete &&
           !dfi_lp_ctrl_ack && !irq)
  `SVA_INV(a_init_complete, dfi_init_complete == m_cmp)
  `SVA_INV(a_lp_ack, dfi_lp_ctrl_ack == m_ack)
  `SVA_INV(a_rddata_valid, dfi_rddata_valid == m_v)
  `SVA_INV(a_rddata, dfi_rddata == m_d)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_IMP(a_irq_sticky, irq, ##1 irq)

  `FC(activate, v_act)
  `FC(read, v_rd)
  `FC(write, v_wr)
  `FC(read_back_to_back, v_b2b)
  `FC(precharge_one, v_pre1)
  `FC(precharge_all, v_preall)
  `FC(refresh, v_ref)
  `FC(mode_register_set, v_mrs)
  `FC(write_byte_mask, v_mask)
  `FC(read_and_write_beat_same_word, v_rw_same)
  `FC(illegal_before_init, v_ill_init)
  `FC(illegal_in_low_power, v_ill_lp)
  `FC(illegal_cke_low, v_ill_cke)
  `FC(illegal_act_open_bank, v_ill_act)
  `FC(illegal_rw_closed_bank, v_ill_closed)
  `FC(illegal_ref_mrs_bank_open, v_ill_ref)
  `FC(write_beat_missing, v_w_miss)
  `FC(write_beat_unexpected, v_w_extra)
  `FC(read_beat_missing, v_r_miss)
  `FC(read_beat_unexpected, v_r_extra)
  `FC(reinit_closes_banks, v_reinit_open)
  `FC(init_start_short_pulse, v_short_start)
  `FC(low_power_entered, v_lp)
  `FC(low_power_request_withdrawn, v_lp_short)
  `FC_RST(reset_with_read_in_flight, rst_n && dfi_rddata_en ##1 !rst_n)
endmodule

bind DFI_5_0__MC_PHY_Interface__top DFI_5_0__MC_PHY_Interface__sva #(
  .T_PHY_WRLAT(T_PHY_WRLAT), .T_RDDATA_EN(T_RDDATA_EN), .T_PHY_RDLAT(T_PHY_RDLAT),
  .INIT_CYCLES(INIT_CYCLES)) u_sva (.*);
