// SPDX-License-Identifier: Apache-2.0
// SW-DP: concurrent SVA against an independent pin-level reference model,
// plus functional coverage.
//  * Own synchroniser (the documented 3-clk response latency); every
//    packet is tracked by its position p = rising SWCLK edges since the
//    start bit. With T = TURNROUND + 1: request bits at p 1..7, ACK driven
//    after p = 7+T, 8+T, 9+T, read data bit i after p = 10+T+i, release
//    after 43+T, end at 43+2T; otherwise release after 10+T, write data bit
//    i sampled at p = 11+2T+i, end at 43+2T (10+2T without a data phase).
//  * Register reads see the values from before the clock (done, abort and
//    clear in the same clock land afterwards, done first).
// Every output is compared on every clock (SWDIO data while driven, the
// AP request fields while ap_req is high).
`include "cov_macros.svh"
module ARM_Serial_Wire_Debug_sva #(
  parameter logic [31:0] DPIDR = 32'h0010_1001
)(
  input logic        clk, rst_n, swclk, swdio_in, swdio_out, swdio_oe,
  input logic        cdbgpwrupreq, cdbgpwrupack, csyspwrupreq, csyspwrupack,
  input logic        ap_req, ap_busy, ap_write,
  input logic [7:0]  ap_sel,
  input logic [5:0]  ap_addr,
  input logic [31:0] ap_wdata,
  input logic        ap_done,
  input logic [31:0] ap_rdata,
  input logic        ap_err, ap_abort,
  input logic        lockout, line_reset, proto_err, ack_wait, ack_fault
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int LOCK = 0, RST = 1, IDLE = 2, PKT = 3;
  localparam int A_OK = 0, A_WAIT = 1, A_FAULT = 2;

  // ---------------- model state ----------------
  bit          c1, c2, c3, d1, d2;
  int          md, ones, zc, p, T, ackv;
  bit          need;
  bit          rq [0:5];
  bit          ap_, rn_, dph;
  int          a_;
  logic [32:0] rdv, wv;
  // registers
  bit          orun, sorun, serr, rok, wderr, busy, cdbg, csys;
  logic [1:0]  trn;
  logic [7:0]  apsel;
  logic [3:0]  apbank, dpbank;
  logic [31:0] rdbuf, last;
  // expected outputs
  bit          m_oe, m_out, m_req, m_wr, m_abort, m_lr, m_pe, m_aw, m_af;
  logic [7:0]  m_sel;
  logic [5:0]  m_addr;
  logic [31:0] m_wd;
  // coverage events
  bit v_pe_par, v_pe_stop, v_pe_park, v_pe_first, v_lr_in_pkt, v_lock_pkt;
  bit v_rd_id, v_rd_ctrl, v_rd_dlcr, v_rd_resv, v_rd_resend, v_rd_rdbuff, v_rd_ap, v_wr_ap;
  bit v_wr_abort, v_wr_ctrl, v_wr_dlcr, v_wr_resv, v_wr_sel, v_wr_a3;
  bit v_wait_ap, v_wait_rdbuff, v_fault_rd, v_fault_wr, v_orun_rd, v_orun_wr, v_wderr_dp, v_wderr_ap;
  bit v_abort_busy, v_abort_idle, v_clr_err, v_clr_wd, v_clr_orun, v_ap_err_rd, v_ap_err_wr;
  bit v_rst_zero_one;
  int v_trn;

  function automatic logic [31:0] ctrl_of(input bit o, so, se, ro, wd, cd, cs);
    return {csyspwrupack, cs, cdbgpwrupack, cd, 20'h0, wd, ro, se, 1'b0, 2'b00, so, o};
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c1 = 0; c2 = 0; c3 = 0; d1 = 1; d2 = 1;
      md = LOCK; ones = 0; zc = 0; p = 0; T = 1; ackv = 0; need = 0; ap_ = 0; rn_ = 0; dph = 0; a_ = 0;
      for (int i = 0; i < 6; i++) rq[i] = 0;
      rdv = 0; wv = 0;
      orun = 0; sorun = 0; serr = 0; rok = 0; wderr = 0; busy = 0; cdbg = 0; csys = 0; trn = 0;
      apsel = 0; apbank = 0; dpbank = 0; rdbuf = 0; last = 0;
      m_oe = 0; m_out = 0; m_req = 0; m_wr = 0; m_abort = 0; m_lr = 0; m_pe = 0; m_aw = 0; m_af = 0;
      m_sel = 0; m_addr = 0; m_wd = 0;
    end else begin
      bit          smp, oe0, busy0, sticky0, orun0, serr0, sorun0, wderr0, rok0, cdbg0, csys0;
      logic [1:0]  trn0;
      logic [7:0]  apsel0;
      logic [3:0]  apbank0, dpbank0;
      logic [31:0] rdbuf0, last0, d;
      {v_pe_par, v_pe_stop, v_pe_park, v_pe_first, v_lr_in_pkt, v_lock_pkt} = '0;
      {v_rd_id, v_rd_ctrl, v_rd_dlcr, v_rd_resv, v_rd_resend, v_rd_rdbuff, v_rd_ap, v_wr_ap} = '0;
      {v_wr_abort, v_wr_ctrl, v_wr_dlcr, v_wr_resv, v_wr_sel, v_wr_a3} = '0;
      {v_wait_ap, v_wait_rdbuff, v_fault_rd, v_fault_wr, v_orun_rd, v_orun_wr, v_wderr_dp, v_wderr_ap} = '0;
      {v_abort_busy, v_abort_idle, v_clr_err, v_clr_wd, v_clr_orun, v_ap_err_rd, v_ap_err_wr} = '0;
      v_rst_zero_one = 0; v_trn = -1;
      m_abort = 0; m_req = 0; m_lr = 0; m_pe = 0; m_aw = 0; m_af = 0;
      busy0 = busy; orun0 = orun; serr0 = serr; sorun0 = sorun; wderr0 = wderr; rok0 = rok;
      cdbg0 = cdbg; csys0 = csys; trn0 = trn; apsel0 = apsel; apbank0 = apbank; dpbank0 = dpbank;
      rdbuf0 = rdbuf; last0 = last;
      sticky0 = serr0 || sorun0 || wderr0;

      // ---------------- AP completion
      if (busy && ap_done) begin
        busy = 0;
        if (ap_err) begin serr = 1; if (m_wr) v_ap_err_wr = 1; else v_ap_err_rd = 1; end
        if (!m_wr) begin rdbuf = ap_rdata; rok = !ap_err; end
      end

      // ---------------- SWCLK rising edge
      if (c2 && !c3) begin
        smp = d2; oe0 = m_oe;
        if (oe0 || !smp) ones = 0; else ones++;
        if (ones == 50) begin
          if (md == PKT) v_lr_in_pkt = 1;
          md = RST; zc = 0; m_oe = 0; m_lr = 1;
        end else case (md)
          LOCK: if (smp) v_lock_pkt = 1;
          RST: if (!smp) begin
            zc++;
            if (zc == 2) begin md = IDLE; need = 1; end
          end else begin if (zc == 1) v_rst_zero_one = 1; zc = 0; end
          IDLE: if (smp) begin md = PKT; p = 0; end
          default: begin                               // PKT
            p++;
            if (p <= 6) rq[p - 1] = smp;
            else if (p == 7) begin
              ap_ = rq[0]; rn_ = rq[1]; a_ = int'(rq[2]) + 2 * int'(rq[3]);
              if ((rq[0] ^ rq[1] ^ rq[2] ^ rq[3]) != rq[4]) begin md = LOCK; m_pe = 1; v_pe_par = 1; end
              else if (rq[5]) begin md = LOCK; m_pe = 1; v_pe_stop = 1; end
              else if (!smp) begin md = LOCK; m_pe = 1; v_pe_park = 1; end
              else if (need && !(!ap_ && rn_ && a_ == 0)) begin md = LOCK; m_pe = 1; v_pe_first = 1; end
              else begin
                need = 0; T = int'(trn0) + 1; v_trn = int'(trn0);
                if (ap_ && sticky0) ackv = A_FAULT;
                else if ((ap_ || (rn_ && a_ == 3)) && busy0) ackv = A_WAIT;
                else ackv = A_OK;
              end
            end else if (p == 7 + T) begin
              m_oe = 1; m_out = ackv == A_OK;
              if (ackv == A_WAIT) begin m_aw = 1; if (ap_) v_wait_ap = 1; else v_wait_rdbuff = 1; end
              if (ackv == A_FAULT) begin m_af = 1; if (rn_) v_fault_rd = 1; else v_fault_wr = 1; end
              dph = ackv == A_OK || orun0;
              rdv = 0;
              if (ackv != A_OK) begin
                if (orun0) begin sorun = 1; if (rn_) v_orun_rd = 1; else v_orun_wr = 1; end
              end else if (rn_) begin
                if (ap_) begin
                  d = rdbuf0; last = rdbuf0; v_rd_ap = 1;
                  busy = 1; m_req = 1; m_wr = 0; m_sel = apsel0; m_addr = {apbank0, 2'(a_)};
                end else case (a_)
                  0: begin d = DPIDR; v_rd_id = 1; end
                  1: begin
                    if (dpbank0 == 0) begin d = ctrl_of(orun0, sorun0, serr0, rok0, wderr0, cdbg0, csys0); v_rd_ctrl = 1; end
                    else if (dpbank0 == 1) begin d = {22'h0, trn0, 8'h00}; v_rd_dlcr = 1; end
                    else begin d = 0; v_rd_resv = 1; end
                  end
                  2: begin d = last0; v_rd_resend = 1; end
                  default: begin d = rdbuf0; last = rdbuf0; v_rd_rdbuff = 1; end
                endcase
                rdv = {^d, d};
              end
            end else if (p == 8 + T) m_out = ackv == A_WAIT;
            else if (p == 9 + T) m_out = ackv == A_FAULT;
            else if (rn_ && dph) begin
              if (p <= 42 + T) m_out = rdv[p - 10 - T];
              else if (p == 43 + T) m_oe = 0;
              else if (p == 43 + 2 * T) md = IDLE;
            end else begin
              if (p == 10 + T) m_oe = 0;
              if (rn_ || !dph) begin if (p == 10 + 2 * T) md = IDLE; end
              else if (p >= 11 + 2 * T) begin
                wv[p - 11 - 2 * T] = smp;
                if (p == 43 + 2 * T) begin
                  md = IDLE;
                  d = wv[31:0];
                  if (ackv == A_OK) begin
                    if (^wv) begin wderr = 1; if (ap_) v_wderr_ap = 1; else v_wderr_dp = 1; end
                    else if (ap_) begin
                      busy = 1; m_req = 1; m_wr = 1; m_sel = apsel0; m_addr = {apbank0, 2'(a_)};
                      m_wd = d; v_wr_ap = 1;
                    end else case (a_)
                      0: begin
                        v_wr_abort = 1;
                        if (d[0] && busy0) begin busy = 0; m_abort = 1; v_abort_busy = 1; end
                        if (d[0] && !busy0) v_abort_idle = 1;
                        if (d[2]) begin serr = 0; v_clr_err = 1; end
                        if (d[3]) begin wderr = 0; v_clr_wd = 1; end
                        if (d[4]) begin sorun = 0; v_clr_orun = 1; end
                      end
                      1: if (dpbank0 == 0) begin orun = d[0]; cdbg = d[28]; csys = d[30]; v_wr_ctrl = 1; end
                         else if (dpbank0 == 1) begin trn = d[9:8]; v_wr_dlcr = 1; end
                         else v_wr_resv = 1;
                      2: begin apsel = d[31:24]; apbank = d[7:4]; dpbank = d[3:0]; v_wr_sel = 1; end
                      default: v_wr_a3 = 1;
                    endcase
                  end
                end
              end
            end
          end
        endcase
      end
      c3 = c2; c2 = c1; c1 = swclk; d2 = d1; d1 = swdio_in;
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_values, !rst_n, !swdio_oe && !ap_req && !ap_busy && !ap_abort && lockout && !line_reset
                                   && !proto_err && !ack_wait && !ack_fault && !cdbgpwrupreq && !csyspwrupreq)
  `SVA_INV(a_swdio_model, swdio_oe == m_oe && (!m_oe || swdio_out == m_out))
  `SVA_INV(a_ap_req_model, ap_req == m_req && ap_busy == busy && ap_abort == m_abort)
  `SVA_IMP(a_ap_fields_model, ap_req, ap_write == m_wr && ap_sel == m_sel && ap_addr == m_addr
                                      && (!m_wr || ap_wdata == m_wd))
  `SVA_INV(a_status_model, lockout == (md == LOCK) && line_reset == m_lr && proto_err == m_pe
                           && ack_wait == m_aw && ack_fault == m_af)
  `SVA_INV(a_power_model, cdbgpwrupreq == cdbg && csyspwrupreq == csys)

  // ---------------- functional coverage ----------------
  int trn_q;
  always_ff @(posedge clk) trn_q <= v_trn;
  covergroup cg_swd @(posedge clk);
    option.per_instance = 1;
    cp_turnround: coverpoint trn_q iff (rst_n && trn_q >= 0) { bins t[] = {[0:3]}; }
  endgroup
  cg_swd u_cg_swd = new;

  `FC(line_reset, line_reset)
  `FC(packet_while_locked_out, v_lock_pkt)
  `FC(reset_interrupted_by_one, v_rst_zero_one)
  `FC(request_parity_error, v_pe_par)
  `FC(stop_bit_error, v_pe_stop)
  `FC(park_bit_error, v_pe_park)
  `FC(first_packet_not_dpidr, v_pe_first)
  `FC(read_dpidr, v_rd_id)
  `FC(read_ctrl_stat, v_rd_ctrl)
  `FC(read_dlcr, v_rd_dlcr)
  `FC(read_reserved_bank, v_rd_resv)
  `FC(read_resend, v_rd_resend)
  `FC(read_rdbuff, v_rd_rdbuff)
  `FC(ap_read, v_rd_ap)
  `FC(ap_write, v_wr_ap)
  `FC(write_abort, v_wr_abort)
  `FC(write_ctrl_stat, v_wr_ctrl)
  `FC(write_dlcr, v_wr_dlcr)
  `FC(write_reserved_bank, v_wr_resv)
  `FC(write_select, v_wr_sel)
  `FC(write_a3_ignored, v_wr_a3)
  `FC(wait_ap, v_wait_ap)
  `FC(wait_rdbuff, v_wait_rdbuff)
  `FC(fault_read, v_fault_rd)
  `FC(fault_write, v_fault_wr)
  `FC(overrun_data_phase_read, v_orun_rd)
  `FC(overrun_data_phase_write, v_orun_wr)
  `FC(wdataerr_dp_write, v_wderr_dp)
  `FC(wdataerr_ap_write, v_wderr_ap)
  `FC(dapabort_busy, v_abort_busy)
  `FC(dapabort_idle, v_abort_idle)
  `FC(stkerrclr, v_clr_err)
  `FC(wderrclr, v_clr_wd)
  `FC(orunerrclr, v_clr_orun)
  `FC(ap_error_read, v_ap_err_rd)
  `FC(ap_error_write, v_ap_err_wr)
  `FC(power_up_acknowledged, cdbgpwrupreq && cdbgpwrupack && csyspwrupreq && csyspwrupack)
  `FC_RST(reset_mid_packet, rst_n && md == PKT ##1 !rst_n)
endmodule

bind ARM_Serial_Wire_Debug_top ARM_Serial_Wire_Debug_sva #(.DPIDR(DPIDR)) u_sva (.*);
