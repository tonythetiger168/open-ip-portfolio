// SPDX-License-Identifier: Apache-2.0
// I3C slave: a bus-level model samples SCL / SDA through its own
// synchronizer, detects START / STOP and clock edges, and walks the slave's
// side of every transfer: address match and ACK, register pointer and data
// writes (shadow register file), register / PID reads, broadcast CCCs
// (ENTDAA with its 64-bit PID / BCR / DCR answer, arbitration and the
// dynamic-address parity, RSTDAA, GETPID), and the IBI request /
// arbitration / payload. It predicts the SDA drivers (open-drain pull,
// push-pull enable and value), dyn_addr / dyn_addr_valid, irq and the
// register file on every clock.
`include "cov_macros.svh"
module MIPI_I3C_sva #(
  parameter logic [6:0]  STATIC_ADDR = 7'h3C,
  parameter logic [47:0] PID = 48'h0, parameter logic [7:0] BCR = 8'h0, DCR = 8'h0
)(
  input logic       clk, rst_n, scl, ibi_req, od_low, pp_en, pp_val, dyn_addr_valid, irq,
  input wire        sda,
  input logic [7:0] ibi_data,
  input logic [6:0] dyn_addr,
  input logic [7:0] mem [0:15]
);
  `COV_CLOCKING(clk, !rst_n)

  localparam int IDLE = 0, ADDR = 1, AACK = 2, RX = 3, RACK = 4, TX = 5, TACK = 6, DTX = 7, DRX = 8,
                 DACK = 9, IARB = 10, IACK = 11, ITX = 12, ITACK = 13, WSTOP = 14;

  logic [2:0] c, d;
  wire  rise = c[2:1] == 2'b01, fall = c[2:1] == 2'b10;
  wire  b    = d[1];
  wire  st   = c[1] && d[2:1] == 2'b10 && !m_od && !m_pp;
  wire  sp   = c[1] && d[2:1] == 2'b01 && !m_od && !m_pp;

  int         ph, n, k;
  logic [7:0] by;               // bits shifted in, MSB first
  logic [7:0] tb_;              // byte being sent
  logic [63:0] daa;
  logic       ack, aph, mack, rnw, bc, bcm, first, pidm, gp, dccc, dp, pull, ip, err;
  logic [3:0] ptr, pc;
  logic [6:0] da;
  logic       dav, m_od, m_pp, m_pv;
  logic [7:0] sh [0:15];

  wire [7:0] nb    = {by[6:0], b};
  wire       match = nb[7:1] == STATIC_ADDR || (dav && nb[7:1] == da);
  wire       b7e   = nb[7:1] == 7'h7E;
  wire       aok   = (b7e && !nb[0]) || (b7e && nb[0] && dp) || match;
  wire [7:0] arb   = {da, 1'b1};
  function automatic logic [7:0] pidb(input int i);
    return i > 5 ? PID[7:0] : PID[47 - 8 * i -: 8];
  endfunction
  wire [7:0] cur = pidm ? pidb(int'(pc)) : sh[ptr];
  wire [7:0] nxt = pidm ? pidb(int'(pc) + 1) : sh[4'(ptr + 1)];

  // coverage strobes
  logic v_i2cw, v_i2cr, v_daa, v_daalost, v_daapar, v_daadone, v_rst, v_gp, v_ccc_bad, v_ptr_bad,
        v_7er_err, v_7er_quiet, v_ibi, v_ibilost, v_ibinack, v_nack_addr, v_rdmore, v_dynw;
  // registered copies for the covergroup: address kind, CCC, written and
  // read register bytes with their pointer
  logic       c_av, c_cv, c_wv, c_rv;
  logic [2:0] c_ak;
  logic [1:0] c_ccc;
  logic [3:0] c_wp, c_rp;
  logic [7:0] c_wd, c_rd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c <= '1; d <= '1; ph <= IDLE; n <= 0; k <= 0; by <= 0; tb_ <= 0; daa <= 0;
      {ack, aph, mack, rnw, bc, bcm, first, pidm, gp, dccc, dp, pull, ip, err} <= '0;
      ptr <= 0; pc <= 0; da <= 0; dav <= 0; m_od <= 0; m_pp <= 0; m_pv <= 0;
      for (int i = 0; i < 16; i++) sh[i] <= 0;
      {v_i2cw, v_i2cr, v_daa, v_daalost, v_daapar, v_daadone, v_rst, v_gp, v_ccc_bad, v_ptr_bad,
       v_7er_err, v_7er_quiet, v_ibi, v_ibilost, v_ibinack, v_nack_addr, v_rdmore, v_dynw} <= '0;
      {c_av, c_cv, c_wv, c_rv} <= '0; c_ak <= 0; c_ccc <= 0; c_wp <= 0; c_rp <= 0; c_wd <= 0; c_rd <= 0;
    end else begin
      {c_av, c_cv, c_wv, c_rv} <= '0;
      {v_i2cw, v_i2cr, v_daa, v_daalost, v_daapar, v_daadone, v_rst, v_gp, v_ccc_bad, v_ptr_bad,
       v_7er_err, v_7er_quiet, v_ibi, v_ibilost, v_ibinack, v_nack_addr, v_rdmore, v_dynw} <= '0;
      c <= {c[1:0], scl}; d <= {d[1:0], sda};
      if (ibi_req) ip <= 1;
      if (st) begin
        ph <= ADDR; n <= 0; aph <= 0; m_od <= 0; m_pp <= 0; bcm <= 0; err <= 0;
      end else if (sp) begin
        ph <= IDLE; m_od <= 0; m_pp <= 0; aph <= 0; bcm <= 0; first <= 0; pidm <= 0; gp <= 0;
        dccc <= 0; dp <= 0;
      end else case (ph)
        IDLE:
          if (ip && !pull && dav) begin m_od <= 1; pull <= 1; end
          else if (pull && fall) begin m_od <= ~arb[7]; pull <= 0; n <= 0; ph <= IARB; end
        ADDR:
          if (rise) begin
            by <= nb; n <= n + 1;
            if (n == 7) begin
              n <= 0; ack <= aok; rnw <= nb[0]; bc <= b7e; ph <= AACK;
              c_av <= 1;
              c_ak <= b7e ? (!nb[0] ? 0 : (dp ? 1 : 2)) : (nb[7:1] == STATIC_ADDR ? 3'(3 + nb[0]) :
                      (dav && nb[7:1] == da ? 3'(5 + nb[0]) : 7));
              if (!aok && b7e && nb[0]) begin
                if (!dccc) begin err <= 1; v_7er_err <= 1; end else v_7er_quiet <= 1;
              end
              v_nack_addr <= !aok && !b7e;
              pidm <= gp && match && nb[0]; pc <= 0;
              v_gp <= gp && match && nb[0];
              v_dynw <= dav && nb[7:1] == da && !nb[0];
            end
          end
        AACK:
          if (fall) begin
            if (!aph) begin m_od <= ack; aph <= 1; end
            else begin
              m_od <= 0; aph <= 0; n <= 0;
              if (!ack) ph <= WSTOP;
              else if (bc && !rnw) begin bcm <= 1; ph <= RX; end
              else if (bc) begin
                k <= 0; daa <= {PID, BCR, DCR}; m_od <= ~PID[47]; ph <= DTX; v_daa <= 1;
              end else if (!rnw) begin bcm <= 0; first <= 1; ph <= RX; end
              else begin
                tb_ <= cur; m_pp <= 1; m_pv <= cur[7]; ph <= TX; v_i2cr <= 1;
                c_rv <= !pidm; c_rp <= ptr; c_rd <= cur;
              end
            end
          end
        RX:
          if (rise) begin
            by <= nb; n <= n + 1;
            if (n == 7) begin
              n <= 0; ph <= RACK;
              if (bcm) begin
                bcm <= 0;
                c_cv <= 1; c_ccc <= nb == 8'h07 ? 0 : (nb == 8'h06 ? 1 : (nb == 8'h8C ? 2 : 3));
                if (nb == 8'h07) begin ack <= 1; dccc <= 1; dp <= !dav; end
                else if (nb == 8'h06) begin ack <= 1; dav <= 0; v_rst <= 1; end
                else if (nb == 8'h8C) begin ack <= 1; gp <= 1; end
                else begin ack <= 0; err <= 1; v_ccc_bad <= 1; end
              end else if (first) begin
                if (nb[7:4] != 0) begin ack <= 0; err <= 1; v_ptr_bad <= 1; end
                else begin ack <= 1; ptr <= nb[3:0]; first <= 0; end
              end else begin
                ack <= 1; sh[ptr] <= nb; ptr <= ptr + 1; v_i2cw <= 1;
                c_wv <= 1; c_wp <= ptr; c_wd <= nb;
              end
            end
          end
        RACK:
          if (fall) begin
            if (!aph) begin m_od <= ack; aph <= 1; end
            else begin m_od <= 0; aph <= 0; n <= 0; ph <= ack ? RX : WSTOP; end
          end
        TX:
          if (fall) begin
            if (n == 7) begin m_pp <= 0; n <= 0; ph <= TACK; end
            else begin n <= n + 1; m_pv <= tb_[6 - n]; end
          end
        TACK: begin
          if (rise) mack <= !b;
          if (fall) begin
            if (mack) begin
              tb_ <= nxt; m_pp <= 1; m_pv <= nxt[7]; n <= 0; ptr <= ptr + 1; pc <= pc + 1; ph <= TX;
              c_rv <= !pidm; c_rp <= ptr + 1; c_rd <= nxt;
              v_rdmore <= 1;
            end else ph <= WSTOP;
          end
        end
        DTX:
          if (rise && !m_od && !b) begin ph <= WSTOP; v_daalost <= 1; end
          else if (fall) begin
            if (k == 63) begin m_od <= 0; n <= 0; ph <= DRX; end
            else begin k <= k + 1; m_od <= ~daa[62 - k]; end
          end
        DRX:
          if (rise) begin
            by <= nb; n <= n + 1;
            if (n == 7) begin
              n <= 0; ph <= DACK;
              if (^nb) begin da <= nb[7:1]; dav <= 1; dp <= 0; ack <= 1; v_daadone <= 1; end
              else begin ack <= 0; err <= 1; v_daapar <= 1; end
            end
          end
        DACK:
          if (fall) begin
            if (!aph) begin m_od <= ack; aph <= 1; end
            else begin m_od <= 0; aph <= 0; ph <= WSTOP; end
          end
        IARB: begin
          if (rise && arb[7 - n] && !b) begin m_od <= 0; ip <= 0; err <= 1; ph <= WSTOP; v_ibilost <= 1; end
          if (fall) begin
            if (n == 7) begin m_od <= 0; n <= 0; ph <= IACK; end
            else begin n <= n + 1; m_od <= ~arb[6 - n]; end
          end
        end
        IACK: begin
          if (rise) mack <= !b;
          if (fall) begin
            if (mack) begin tb_ <= ibi_data; m_pp <= 1; m_pv <= ibi_data[7]; n <= 0; ph <= ITX; end
            else begin ph <= WSTOP; v_ibinack <= 1; end
          end
        end
        ITX:
          if (fall) begin
            if (n == 7) begin m_pp <= 0; n <= 0; ph <= ITACK; end
            else begin n <= n + 1; m_pv <= tb_[6 - n]; end
          end
        ITACK: if (fall) begin ip <= 0; ph <= WSTOP; v_ibi <= 1; end
        default: begin m_od <= 0; m_pp <= 0; end
      endcase
    end
  end

  logic rf_ok;
  always_comb begin
    rf_ok = 1;
    for (int i = 0; i < 16; i++) if (mem[i] != sh[i]) rf_ok = 0;
  end

  `SVA_RST(a_reset_state, !rst_n, !od_low && !pp_en && !irq && !dyn_addr_valid)
  `SVA_INV(a_open_drain, od_low == m_od)
  `SVA_INV(a_push_pull, pp_en == m_pp && (!pp_en || pp_val == m_pv))
  `SVA_INV(a_dynamic_address, dyn_addr_valid == dav && (!dav || dyn_addr == da))
  `SVA_INV(a_irq, irq == err)
  `SVA_INV(a_register_file, rf_ok)
  `SVA_INV(a_never_both_drivers, !(od_low && pp_en))

  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : (v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA ? 2 : 3));
  endfunction
  covergroup cg_bus @(negedge clk);
    option.per_instance = 1;
    cp_addr: coverpoint c_ak iff (rst_n && c_av)
      { bins bcast_w = {0}; bins entdaa_r = {1}; bins bcast_r_nack = {2}; bins static_w = {3};
        bins static_r = {4}; bins dyn_w = {5}; bins dyn_r = {6}; bins other_nack = {7}; }
    cp_ccc: coverpoint c_ccc iff (rst_n && c_cv)
      { bins entdaa = {0}; bins rstdaa = {1}; bins getpid = {2}; bins unknown = {3}; }
    cp_wptr: coverpoint c_wp iff (rst_n && c_wv);
    cp_rptr: coverpoint c_rp iff (rst_n && c_rv);
    cp_wdata: coverpoint dcls(c_wd) iff (rst_n && c_wv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(c_rd) iff (rst_n && c_rv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_bus u_cg_bus = new;

  `FC(i2c_register_write, v_i2cw)
  `FC(register_read, v_i2cr)
  `FC(read_continues, v_rdmore)
  `FC(write_to_dynamic_address, v_dynw)
  `FC(address_nack, v_nack_addr)
  `FC(pointer_out_of_range, v_ptr_bad)
  `FC(entdaa_answer, v_daa)
  `FC(entdaa_arbitration_lost, v_daalost)
  `FC(entdaa_parity_error, v_daapar)
  `FC(entdaa_assigned, v_daadone)
  `FC(entdaa_7e_read_nothing_left, v_7er_quiet)
  `FC(read_7e_outside_entdaa, v_7er_err)
  `FC(rstdaa, v_rst)
  `FC(getpid_read, v_gp)
  `FC(unknown_ccc, v_ccc_bad)
  `FC(ibi_delivered, v_ibi)
  `FC(ibi_arbitration_lost, v_ibilost)
  `FC(ibi_nacked, v_ibinack)
  `FC(ibi_held_without_address, ip && !dav && ph == IDLE)
  `FC_RST(reset_during_transfer, rst_n && ph != IDLE ##1 !rst_n)
endmodule

bind MIPI_I3C_top MIPI_I3C_sva #(.STATIC_ADDR(STATIC_ADDR), .PID(PID), .BCR(BCR), .DCR(DCR)) u_sva (.*);
