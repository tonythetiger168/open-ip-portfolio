// SPDX-License-Identifier: Apache-2.0
// SMBus / PMBus target: concurrent SVA against an independent model that
// decodes the (filtered) bus byte by byte and predicts every ACK, every
// bit the target sends, the register writes taken at STOP, STATUS_CML,
// SMBALERT# and the ARA; plus the bus-timing rules (spike filter, SDA
// hold, stretch length, timeout) and functional coverage.
`include "cov_macros.svh"
module SMBus_sva #(parameter logic [6:0] ADDR = 7'h5A,
                   parameter int FILT = 3, HOLD = 4, STRETCH = 8, TIMEOUT = 2500000) (
  input logic clk, rst_n,
  input logic scl, sda, scl_o, sda_o, smbalert_n,
  input logic scl_f, sda_f,
  input logic [7:0] operation, on_off_config,
  input logic [15:0] vout_command, read_vout,
  input logic vout_ov, irq_cml, irq_upd, irq_to
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- spike filter model ----------------
  logic [1:0] y_scl, y_sda;
  logic       f_scl, f_sda;
  int         c_scl, c_sda;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      y_scl <= 2'b11; y_sda <= 2'b11; f_scl <= 1; f_sda <= 1; c_scl <= 0; c_sda <= 0;
    end else begin
      y_scl <= {y_scl[0], scl}; y_sda <= {y_sda[0], sda};
      if (y_scl[1] == f_scl) c_scl <= 0; else if (c_scl == FILT - 1) begin f_scl <= y_scl[1]; c_scl <= 0; end else c_scl <= c_scl + 1;
      if (y_sda[1] == f_sda) c_sda <= 0; else if (c_sda == FILT - 1) begin f_sda <= y_sda[1]; c_sda <= 0; end else c_sda <= c_sda + 1;
    end
  `SVA_INV(a_filter, scl_f == f_scl && sda_f == f_sda)

  // ---------------- bus events ----------------
  logic p_scl, p_sda;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin p_scl <= 1; p_sda <= 1; end else begin p_scl <= f_scl; p_sda <= f_sda; end
  wire e_start = f_scl && p_scl && p_sda && !f_sda;
  wire e_stop  = f_scl && p_scl && !p_sda && f_sda;
  wire e_rise  = f_scl && !p_scl;
  wire e_fall  = !f_scl && p_scl;

  // ---------------- PMBus model ----------------
  function automatic int wl(input logic [7:0] c);
    case (c) 8'h01, 8'h02, 8'h10: return 1; 8'h03: return 0; 8'h21: return 2; default: return -1; endcase
  endfunction
  function automatic int rl(input logic [7:0] c);
    case (c)
      8'h01, 8'h02, 8'h10, 8'h19, 8'h20, 8'h78, 8'h7E, 8'h98: return 1;
      8'h21, 8'h79, 8'h8B: return 2;
      8'h99: return 5;
      default: return -1;
    endcase
  endfunction
  function automatic logic [7:0] c8(input logic [7:0] c, input logic [7:0] b);
    logic [7:0] x;
    x = c ^ b;
    for (int k = 0; k < 8; k++) x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
    return x;
  endfunction
  logic [7:0]  m_op, m_oo, m_wp, m_cml, cmd, sh, crc, w0, w1, txb;
  logic [15:0] m_vout, snap;
  logic        m_ov, m_aack, act, rep, drop, tx, ara, lost, ack_e, mack, rd_go;
  int          bitc, nb, nw, ntx, tl;
  wire alert = (m_cml != 0 || m_ov) && !m_aack;
  function automatic bit prot(input logic [7:0] c);
    if (m_wp == 8'h80) return c != 8'h10 && c != 8'h03;
    if (m_wp == 8'h40) return c != 8'h10 && c != 8'h03 && c != 8'h01;
    return 0;
  endfunction
  function automatic logic [15:0] word(input logic [7:0] c);
    logic [7:0] sb;
    sb = {1'b0, !m_op[7], m_ov, 3'b000, m_cml != 0, 1'b0};
    case (c)
      8'h01: return m_op; 8'h02: return m_oo; 8'h10: return m_wp; 8'h19: return 16'h00B0;
      8'h20: return 16'h0017; 8'h21: return m_vout; 8'h78: return sb; 8'h79: return {m_ov, 7'h0, sb};
      8'h7E: return m_cml; 8'h8B: return read_vout; default: return 16'h0033;
    endcase
  endfunction
  function automatic logic [7:0] rbyte(input int i);
    if (cmd == 8'h99) case (i) 0: return 8'd4; 1: return "O"; 2: return "I"; 3: return "P"; default: return "F"; endcase
    return i == 0 ? snap[7:0] : snap[15:8];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_op <= 8'h80; m_oo <= 8'h1E; m_wp <= 0; m_cml <= 0; m_vout <= 0; m_ov <= 0; m_aack <= 0;
      act <= 0; rep <= 0; drop <= 0; tx <= 0; ara <= 0; lost <= 0; ack_e <= 0; mack <= 0; rd_go <= 0;
      bitc <= 0; nb <= 0; nw <= 0; ntx <= 0; tl <= 0; cmd <= 0; sh <= 0; crc <= 0; w0 <= 0; w1 <= 0;
      txb <= 0; snap <= 0;
    end else begin : step
      logic [7:0] cs, s, b;
      bit a;
      cs = 0;
      if (vout_ov && !m_ov) begin m_ov <= 1; m_aack <= 0; end
      if (!act || f_scl) tl <= 0; else tl <= tl + 1;
      if (act && tl == TIMEOUT) begin act <= 0; tx <= 0; cs[1] = 1; tl <= 0; end
      else if (e_start) begin
        if (!act) begin rep <= 0; drop <= 0; nb <= 0; nw <= 0; crc <= 0; rd_go <= 0; end else rep <= 1;
        act <= 1; bitc <= 0; tx <= 0; ara <= 0;
      end else if (e_stop) begin
        if (act && !rep && !drop && nb >= 2 && wl(cmd) >= 0) begin
          if (nw == wl(cmd) || nw == wl(cmd) + 1)
            case (cmd)
              8'h01: m_op <= w0; 8'h02: m_oo <= w0; 8'h10: m_wp <= w0;
              8'h03: begin m_cml <= 0; m_ov <= vout_ov; m_aack <= 0; end
              default: m_vout <= {w1, w0};
            endcase
          else if (nw < wl(cmd)) cs[6] = 1;
        end
        act <= 0; tx <= 0;
      end else if (act && e_rise) begin
        if (bitc < 8) begin
          bitc <= bitc + 1;
          if (tx) begin
            if (txb[7 - bitc] && !f_sda) begin tx <= 0; drop <= 1; lost <= 1; end   // arbitration lost
            else if (bitc == 7 && ara) m_aack <= 1;
          end else begin
            s = {sh[6:0], f_sda}; sh <= s;
            if (bitc == 7) begin                      // byte received: decide the ACK
              a = 0;
              if (drop) a = 0;
              else if (nb == 0) begin
                if (s == 8'h19) begin a = alert; ara <= a; end
                else a = s == {ADDR, 1'b0};
                crc <= c8(0, s);
                if (!a) drop <= 1;
              end else if (!rep && nb == 1) begin
                a = wl(s) >= 0 || rl(s) >= 0; cmd <= s; crc <= c8(crc, s);
                if (!a) begin cs[7] = 1; drop <= 1; end
              end else if (!rep) begin
                if (wl(cmd) < 0 || nw > wl(cmd) || (nw == 0 && prot(cmd)) ||
                    (nw == 0 && cmd == 8'h10 && !(s == 8'h80 || s == 8'h40 || s == 8'h20 || s == 8'h00))) begin
                  cs[6] = 1; drop <= 1;
                end else if (nw < wl(cmd)) begin
                  a = 1; crc <= c8(crc, s); if (nw == 0) w0 <= s; else w1 <= s;
                end else if (s == crc) a = 1;
                else begin cs[5] = 1; drop <= 1; end
                nw <= nw + 1;
              end else begin
                a = s == {ADDR, 1'b1} && nb == 2 && rl(cmd) >= 0;
                if (s == {ADDR, 1'b1} && nb == 2 && rl(cmd) < 0) cs[7] = 1;
                if (a) begin crc <= c8(crc, s); snap <= word(cmd); end else drop <= 1;
              end
              ack_e <= a;
              nb <= nb + 1;
            end
          end
        end else begin                                // the ACK bit
          bitc <= 0;
          if (tx) begin
            if (!f_sda) begin                         // the host wants another byte
              b = ara ? (ntx == 1 ? crc : 8'hFF)
                      : (ntx == rl(cmd)) ? crc : (ntx > rl(cmd)) ? 8'hFF : rbyte(ntx);
              if (!ara && ntx < rl(cmd)) crc <= c8(crc, b);
              txb <= b; ntx <= ntx + 1;
            end else begin tx <= 0; drop <= 1; end
          end else if (ara && nb == 1 && ack_e) begin
            tx <= 1; ntx <= 1; txb <= {ADDR, 1'b0}; crc <= c8(crc, {ADDR, 1'b0});
          end else if (rep && nb == 3 && !drop) begin
            tx <= 1; ntx <= 1; txb <= rbyte(0); crc <= c8(crc, rbyte(0)); rd_go <= 1;
          end
        end
      end
      if (cs != 0) begin m_cml <= m_cml | cs; m_aack <= 0; end
    end
  end

  // ---------------- assertions ----------------
  // the target's ACK / NACK, and every bit it sends, as seen at SCL rising
  `SVA_IMP(a_ack, act && e_rise && bitc == 8 && !tx && nb >= 1, sda_o == !ack_e)
  `SVA_IMP(a_tx_bit, act && e_rise && bitc < 8 && tx, sda_o == txb[7 - bitc])
  `SVA_IMP(a_release, act && e_rise && bitc < 8 && !tx, sda_o)
  `SVA_INV(a_regs, operation == m_op && on_off_config == m_oo && vout_command == m_vout)
  `SVA_IMP(a_alert, e_rise || !act, smbalert_n == !alert)
  // SDA from the target moves only while SCL is low, HOLD clocks or more after it fell
  int t_fall;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) t_fall <= 0; else if (e_fall) t_fall <= 0; else t_fall <= t_fall + 1;
  logic to_q;                          // the target released the bus on a timeout
  always_ff @(posedge clk) to_q <= act && tl == TIMEOUT;
  `SVA_IMP(a_sda_hold, $changed(sda_o) && $past(act) && !$past(e_start) && !$past(e_stop) && !to_q,
           !f_scl && t_fall >= HOLD)
  // a stretch lasts STRETCH clocks and starts with SCL already low
  int st;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) st <= 0; else if (!scl_o) st <= st + 1; else st <= 0;
  `SVA_IMP(a_stretch_len, !scl_o, st < STRETCH)
  `SVA_NXT(a_stretch_end, !scl_o && st == STRETCH - 1, scl_o)
  `SVA_IMP(a_stretch_start, $fell(scl_o), !f_scl)
  // a stretch follows every ACKed address byte, and nothing else
  logic m_st, m_sd;                     // armed at the ACK bit, due from the next SCL fall
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_st <= 0; m_sd <= 0; end
    else if (!scl_o || e_start || e_stop || !act) begin m_st <= 0; m_sd <= 0; end
    else if (act && e_rise && bitc == 8 && !tx && ack_e && (nb == 1 || (rep && nb == 3))) m_st <= 1;
    else if (m_st && e_fall) m_sd <= 1;
  `SVA_IMP(a_stretch_when, $fell(scl_o), m_sd)
  `SVA_IMP(a_stretch_due, m_sd, t_fall <= HOLD + 1)
  `SVA_NXT(a_timeout, act && tl == TIMEOUT, irq_to && sda_o && scl_o)
  `SVA_RST(a_rst, 1'b1, scl_o && sda_o && smbalert_n && !irq_cml && !irq_upd && !irq_to)

  // ---------------- functional coverage ----------------
  // classes computed at the clock edge, sampled half a clock later (-1: idle)
  int k_cd, k_pec, k_fault, k_wp;
  always @(posedge clk) begin
    k_cd = -1; k_pec = -1; k_fault = -1; k_wp = -1;
    // command x direction of a completed write or a read that returned data
    if (rst_n && e_stop && act && ((!rep && !drop && nb >= 2) || rd_go)) k_cd = 2 * cmd + rep;
    if (rst_n && e_stop && act && !rep && !drop && nb >= 2 && wl(cmd) >= 0) k_pec = nw == wl(cmd) + 1;
    if (rst_n && e_stop) begin k_fault = m_cml; k_wp = m_wp; end
  end
  covergroup cg_xfer @(negedge clk);
    option.per_instance = 1;
    cp_cmd_dir: coverpoint k_cd
      { bins op_w = {2}; bins op_r = {3}; bins oo_w = {4}; bins oo_r = {5}; bins clr = {6};
        bins wp_w = {32}; bins wp_r = {33}; bins cap = {51}; bins vm = {65}; bins vc_w = {66}; bins vc_r = {67};
        bins sb = {241}; bins sw = {243}; bins cml = {253}; bins rv = {279}; bins rev = {305}; bins mfr = {307}; }
    cp_pec: coverpoint k_pec { bins no_pec = {0}; bins pec = {1}; }
    cp_fault: coverpoint k_fault
      { bins none = {0}; bins cmd = {128}; bins data = {64}; bins pec = {32}; bins other = {2}; }
    cp_wp: coverpoint k_wp { bins none = {0}; bins all = {128}; bins op = {64}; bins ctl = {32}; }
  endgroup
  cg_xfer u_cg_xfer = new;

  `FC(ara_won, act && ara && tx && e_rise && bitc == 7 && !(txb[0] && !f_sda))
  `FC(ara_lost, lost)
  `FC(read_past_pec, act && tx && e_rise && bitc == 8 && !f_sda && ntx > rl(cmd) && !ara)
  `FC(stretch, !scl_o)
  `FC(repeated_start_other_addr, act && rep && e_rise && bitc == 7 && nb == 2 && sh[6:0] != ADDR[5:0])
  `FC(spike_scl, y_scl[1] != f_scl && c_scl == FILT - 2 ##1 y_scl[1] == f_scl)
  `FC(spike_sda, y_sda[1] != f_sda && c_sda == FILT - 2 ##1 y_sda[1] == f_sda)
  `FC(ov_while_alert_acked, vout_ov && m_aack)
  `FC_RST(reset_in_transfer, rst_n && act ##1 !rst_n)
endmodule

bind SMBus_top SMBus_sva #(.ADDR(ADDR), .FILT(FILT), .HOLD(HOLD), .STRETCH(STRETCH), .TIMEOUT(TIMEOUT)) u_sva (.*);
