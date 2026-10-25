// SPDX-License-Identifier: Apache-2.0
// JTAG TAP: an independent TAP/IR/DR model driven from TMS/TDI predicts the
// TAP state, the instruction, and TDO as the master samples it on each
// rising TCK edge; USER updates are matched against irq pulses in clk.
`include "cov_macros.svh"
module JTAG_sva #(parameter logic [31:0] IDCODE = 32'h1CAF_0001) (
  input logic       clk, rst_n, tck, tms, tdi, trst_n, tdo, irq,
  input logic [3:0] tap_q, ir_q
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [3:0] TLR = 0, RTI = 1, SEL_DR = 2, CAP_DR = 3, SH_DR = 4, EX1_DR = 5,
    PAUSE_DR = 6, EX2_DR = 7, UPD_DR = 8, SEL_IR = 9, CAP_IR = 10, SH_IR = 11, EX1_IR = 12,
    PAUSE_IR = 13, EX2_IR = 14, UPD_IR = 15;
  function automatic logic [3:0] nxt(input logic [3:0] s, input logic m);
    case (s)
      TLR: return m ? TLR : RTI;          RTI: return m ? SEL_DR : RTI;
      SEL_DR: return m ? SEL_IR : CAP_DR; CAP_DR: return m ? EX1_DR : SH_DR;
      SH_DR: return m ? EX1_DR : SH_DR;   EX1_DR: return m ? UPD_DR : PAUSE_DR;
      PAUSE_DR: return m ? EX2_DR : PAUSE_DR; EX2_DR: return m ? UPD_DR : SH_DR;
      UPD_DR: return m ? SEL_DR : RTI;    SEL_IR: return m ? TLR : CAP_IR;
      CAP_IR: return m ? EX1_IR : SH_IR;  SH_IR: return m ? EX1_IR : SH_IR;
      EX1_IR: return m ? UPD_IR : PAUSE_IR; PAUSE_IR: return m ? EX2_IR : PAUSE_IR;
      EX2_IR: return m ? UPD_IR : SH_IR;  default: return m ? SEL_DR : RTI;   // UPD_IR
    endcase
  endfunction

  logic [3:0]  m_st, m_ir, m_shir;
  logic [31:0] m_shdr;
  logic [7:0]  m_user;
  logic        m_tdo;
  int          n_upd, n_irq;
  wire  [5:0]  len = (m_ir == 4'b0001) ? 6'd32 : (m_ir == 4'b0010) ? 6'd8 : 6'd1;
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      m_st <= TLR; m_ir <= 4'b0001; m_shir <= 0; m_shdr <= 0; m_user <= 0;
    end else begin
      m_st <= nxt(m_st, tms);
      case (m_st)
        TLR:    m_ir <= 4'b0001;
        CAP_IR: m_shir <= 4'b0101;
        SH_IR:  m_shir <= {tdi, m_shir[3:1]};
        UPD_IR: m_ir <= m_shir;
        CAP_DR: m_shdr <= (m_ir == 4'b0001) ? IDCODE : (m_ir == 4'b0010) ? {24'h0, m_user} : 32'h0;
        SH_DR:  begin
          m_shdr <= m_shdr >> 1;
          m_shdr[len - 1] <= tdi;
        end
        UPD_DR: if (m_ir == 4'b0010) m_user <= m_shdr[7:0];
        default: ;
      endcase
    end
  end
  always_ff @(negedge tck or negedge trst_n)
    if (!trst_n) m_tdo <= 0;
    else m_tdo <= (m_st == SH_IR) ? m_shir[0] : (m_st == SH_DR) ? m_shdr[0] : 1'b0;
  // USER updates (TCK) vs irq pulses (clk); trst does not cancel an update
  always_ff @(posedge tck) if (trst_n && m_st == UPD_DR && m_ir == 4'b0010) n_upd <= n_upd + 1;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin n_irq <= 0; end
    else if (irq) n_irq <= n_irq + 1;
  initial begin n_upd = 0; n_irq = 0; end
  int n_upd_base;                         // updates already counted at the last clk reset
  always @(negedge rst_n) n_upd_base <= n_upd;
  initial n_upd_base = 0;

  `SVA_RST(a_irq_quiet_in_reset, !rst_n, !irq)
  `SVA_IMP_CK(a_tap_state, tck, trst_n, tap_q == m_st)
  `SVA_IMP_CK(a_ir_model, tck, trst_n, ir_q == m_ir)
  `SVA_IMP_CK(a_tdo_model, tck, trst_n, tdo == m_tdo)
  `SVA_INV(a_irq_matches_updates, n_irq <= n_upd - n_upd_base && n_upd - n_upd_base - n_irq <= 1)
  `SVA_NXT(a_irq_pulse, irq, !irq)

  `FC_CK(idcode_scanned, tck, m_st == SH_DR && m_ir == 4'b0001 ##1 m_st == SH_DR [*31])
  `FC_CK(user_updated, tck, m_st == UPD_DR && m_ir == 4'b0010)
  `FC_CK(bypass_unused_opcode, tck, m_st == SH_DR && !(m_ir inside {4'b0001, 4'b0010, 4'b1111}))
  `FC_CK(bypass_opcode, tck, m_st == SH_DR && m_ir == 4'b1111)
  `FC_CK(ir_capture_shifted, tck, m_st == CAP_IR ##1 m_st == SH_IR [*4])
  `FC_CK(dr_scan_paused, tck, m_st == PAUSE_DR ##1 m_st == EX2_DR ##1 m_st == SH_DR)
  `FC_CK(ir_scan_paused, tck, m_st == PAUSE_IR ##1 m_st == EX2_IR ##1 m_st == SH_IR)
  `FC_CK(tlr_by_tms_selects_idcode, tck, m_st == TLR && m_ir != 4'b0001)
  `FC(trst_mid_scan, $fell(trst_n) && $past(m_st) != TLR)
  `FC_RST(clk_reset, $fell(rst_n))
endmodule

bind JTAG_top JTAG_sva #(.IDCODE(IDCODE)) u_sva (.*);
