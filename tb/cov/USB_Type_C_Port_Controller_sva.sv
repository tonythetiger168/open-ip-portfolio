// SPDX-License-Identifier: Apache-2.0
// USB Type-C port controller: a reference model of the attach/detach
// debounce (counted in clk, restarting on glitch, pin swap or fault), the
// sticky/W1C registers and the readback predicts every output each cycle.
`include "cov_macros.svh"
module USB_Type_C_Port_Controller_sva (
  input logic       clk, rst_n, attached, orientation, vbus_en, reg_rd, reg_wr, irq,
  input logic [1:0] cc1, cc2,
  input logic [2:0] reg_addr,
  input logic [7:0] reg_wdata, reg_rdata
);
  `COV_CLOCKING(clk, !rst_n)

  // 0 unattached, 1 attach-wait, 2 attached
  int         st, deb, rel;
  logic       m_or, m_src, m_fault;
  logic [2:0] m_int;
  logic       ev_glitch, ev_recover;
  wire        rd1 = cc1 == 2'b01, rd2 = cc2 == 2'b01;
  wire        flt = cc1 == 2'b11 || cc2 == 2'b11;
  wire        cand = rd1 ^ rd2;
  wire        open_act = m_or ? cc2 == 2'b00 : cc1 == 2'b00;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= 0; deb <= 0; rel <= 0; m_or <= 0; m_src <= 1; m_fault <= 0; m_int <= 0;
      ev_glitch <= 0; ev_recover <= 0;
    end else begin
      automatic logic [2:0] set = {flt, st == 2 && rel == 9 && open_act,
                                   st == 1 && deb == 99 && cand && rd2 == m_or && !flt};
      ev_glitch  <= st == 1 && !cand;
      ev_recover <= st == 2 && rel > 0 && !open_act;
      case (st)
        0: begin rel <= 0; if (cand && !flt) begin st <= 1; deb <= 0; m_or <= rd2; end end
        1: if (!cand || rd2 != m_or || flt) st <= 0;
           else if (deb == 99) st <= 2;
           else deb <= deb + 1;
        default: if (open_act) begin
             if (rel == 9) begin st <= 0; rel <= 0; end else rel <= rel + 1;
           end else rel <= 0;
      endcase
      m_fault <= flt || (m_fault && !(reg_wr && reg_addr == 2 && reg_wdata[0]));
      m_int   <= set | (m_int & ~((reg_wr && reg_addr == 3) ? reg_wdata[2:0] : 3'b0));
      if (reg_wr && reg_addr == 1) m_src <= reg_wdata[0];
    end
  end
  wire [7:0] m_rd = (reg_addr == 0) ? {st == 2, m_or, 2'(st), cc2, cc1} :
                    (reg_addr == 1) ? {7'h0, m_src} : (reg_addr == 2) ? {7'h0, m_fault} :
                    (reg_addr == 3) ? {5'h0, m_int} : (reg_addr == 4) ? 8'd100 :
                    (reg_addr == 5) ? {7'h0, m_or} : (reg_addr == 6) ? {7'h0, st == 2 && m_src} : 8'hC7;

  `SVA_RST(a_reset_state, !rst_n, !attached && !vbus_en && !irq && reg_rdata == m_rd)
  `SVA_INV(a_attach_model, attached == (st == 2) && orientation == m_or)
  `SVA_INV(a_vbus_model, vbus_en == (st == 2 && m_src))
  `SVA_INV(a_irq_model, irq == (flt || m_int != 0))
  `SVA_INV(a_readback_model, reg_rdata == m_rd)

  // CC1 x CC2 line levels in each connection state, orientation x role
  // while attached, every register read and written, which interrupt
  // bits a W1C clears while set
  covergroup cg_port @(posedge clk);
    option.per_instance = 1;
    cp_cc1: coverpoint cc1 iff (rst_n) { bins open_ = {0}; bins rd = {1}; bins ra = {2}; bins flt = {3}; }
    cp_cc2: coverpoint cc2 iff (rst_n) { bins open_ = {0}; bins rd = {1}; bins ra = {2}; bins flt = {3}; }
    x_cc: cross cp_cc1, cp_cc2;
    cp_st: coverpoint st iff (rst_n) { bins unattached = {0}; bins wait_ = {1}; bins attached = {2}; }
    cp_cand: coverpoint {flt, cand} iff (rst_n)
      { bins none = {2'b00}; bins one_rd = {2'b01}; bins fault = {2'b10, 2'b11}; }
    x_st_cand: cross cp_st, cp_cand;
    cp_or: coverpoint m_or iff (rst_n && st == 2) { bins cc1 = {0}; bins cc2 = {1}; }
    cp_role: coverpoint m_src iff (rst_n && st == 2) { bins sink = {0}; bins source = {1}; }
    x_or_role: cross cp_or, cp_role;
    cp_rreg: coverpoint reg_addr iff (rst_n && reg_rd) { bins r[] = {[0:7]}; }
    cp_wreg: coverpoint reg_addr iff (rst_n && reg_wr) { bins r[] = {[0:7]}; }
    cp_w1c: coverpoint (reg_wdata[2:0] & m_int) iff (rst_n && reg_wr && reg_addr == 3 && m_int != 0)
      { bins attach = {3'b001}; bins detach = {3'b010}; bins fault = {3'b100}; bins several = {3'b011, 3'b101, 3'b110, 3'b111}; }
  endgroup
  cg_port u_cg_port = new;

  `FC(attach_cc1, st == 1 && deb == 99 && cand && !flt && !m_or)
  `FC(attach_cc2, st == 1 && deb == 99 && cand && !flt && m_or)
  `FC(debounce_glitch, ev_glitch)
  `FC(debounce_pin_swap, st == 1 && cand && rd2 != m_or)
  `FC(debounce_fault, st == 1 && cand && rd2 == m_or && flt)
  `FC(rd_on_both_pins, rd1 && rd2)
  `FC(ra_only, (cc1 == 2'b10 || cc2 == 2'b10) && !rd1 && !rd2)
  `FC(detach_glitch_recovered, ev_recover)
  `FC(event_during_w1c, reg_wr && reg_addr == 3 && (flt || (st == 1 && deb == 99 && cand && rd2 == m_or)))
  `FC(detach, st == 2 && rel == 9 && open_act)
  `FC(sink_role_attached, st == 2 && !m_src)
  `FC(w1c_with_zero, reg_wr && reg_addr == 2 && !reg_wdata[0] && m_fault)
  `FC(write_read_only, reg_wr && (reg_addr == 0 || reg_addr > 3))
  `FC_RST(reset_while_attached, rst_n && st == 2 ##1 !rst_n)
endmodule

bind USB_Type_C_Port_Controller_top USB_Type_C_Port_Controller_sva u_sva (.*);
