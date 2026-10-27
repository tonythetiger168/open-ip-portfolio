// SPDX-License-Identifier: Apache-2.0
// AVSBus slave: a pin-level frame decoder (START, 31 payload bits, CRC4,
// ACK slot, 20-bit GET readback) with its own CRC and voltage ramp model
// predicts the ACK/NACK, every readback bit, irq, vdac and busy.
`include "cov_macros.svh"
module AVSBus__Adaptive_Voltage_Scaling__sva #(parameter int TIMEOUT = 1024) (
  input logic        clk, rst_n, sclk, sdat, busy, irq, sdat_oe,
  input logic [11:0] vdac
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [3:0] crc4(input logic [3:0] c, input logic b);
    automatic logic fb = b ^ c[3];
    return {c[2], c[1], c[0] ^ fb, fb};
  endfunction

  logic [2:0]  cs, ds;
  wire         rise = cs[2:1] == 2'b01, bitv = ds[2];
  // 0 idle, 1 receive, 2 ack slot, 3 readback
  int          ph, n, idle;
  logic [34:0] sh;
  logic [3:0]  c;
  logic [19:0] tx;
  logic [11:0] m_v, m_t;
  logic        m_irq;
  wire [6:0]   a  = sh[34:28];
  wire [7:0]   cm = sh[27:20];
  wire [15:0]  d  = sh[19:4];
  wire         good = a == 7'h55 && sh[3:0] == c &&
                      (cm == 8'h02 || (cm == 8'h01 && d[15:12] == 0));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs <= 0; ds <= 0; ph <= 0; n <= 0; idle <= 0; sh <= 0; c <= 0; tx <= 0;
      m_v <= 0; m_t <= 0; m_irq <= 0;
    end else begin
      cs <= {cs[1:0], sclk}; ds <= {ds[1:0], sdat}; m_irq <= 0;
      if (m_v < m_t) m_v <= (m_t - m_v > 10) ? m_v + 10 : m_t;
      else if (m_v > m_t) m_v <= (m_v - m_t > 10) ? m_v - 10 : m_t;
      idle <= (ph == 0 || rise) ? 0 : (idle < TIMEOUT ? idle + 1 : idle);
      if (idle == TIMEOUT) ph <= 0;
      else if (rise) case (ph)
        0: if (bitv) begin ph <= 1; n <= 0; c <= 0; end
        1: begin
          sh <= {sh[33:0], bitv};
          if (n < 31) c <= crc4(c, bitv);
          if (n == 34) ph <= 2;
          n <= n + 1;
        end
        2: begin
          if (good && cm == 8'h01) m_t <= d[11:0];
          if (a == 7'h55 && !good) m_irq <= 1;
          if (good && cm == 8'h02) begin
            automatic logic [3:0] k = 0;
            for (int i = 15; i >= 0; i--) k = crc4(k, (i < 12) ? m_v[i] : 1'b0);
            tx <= {4'h0, m_v, k}; n <= 0; ph <= 3;
          end else ph <= 0;
        end
        default: begin tx <= tx << 1; if (n == 19) ph <= 0; n <= n + 1; end
      endcase
    end
  end
  wire m_oe = (ph == 2) ? good : (ph == 3) ? !tx[19] : 1'b0;

  `SVA_RST(a_reset_idle, !rst_n, !sdat_oe && !busy && !irq && vdac == 0)
  `SVA_INV(a_drive_model, sdat_oe == m_oe)
  `SVA_INV(a_irq_model, irq == m_irq)
  `SVA_INV(a_vdac_model, vdac == m_v && busy == (m_v != m_t))
  `SVA_IMP(a_open_drain, sdat_oe, sdat == 1'b0)

  // command x outcome at the ACK slot (feasible pairs listed), SET code
  // class x ramp direction, GET readback class, the field a timed-out
  // frame was abandoned in
  wire [1:0] cmk = (cm == 8'h01) ? 2'd0 : (cm == 8'h02) ? 2'd1 : 2'd2;
  wire [1:0] rsk = (a != 7'h55) ? 2'd1 : (sh[3:0] != c) ? 2'd2 : good ? 2'd0 : 2'd3;
  wire       ack_slot = rise && ph == 2;
  wire [1:0] fld = (ph == 1) ? ((n < 7) ? 2'd0 : (n < 15) ? 2'd1 : 2'd2) : 2'd3;
  covergroup cg_frame @(posedge clk);
    option.per_instance = 1;
    cp_outcome: coverpoint {cmk, rsk} iff (rst_n && ack_slot)
      { bins set_ack = {4'b00_00}; bins set_foreign = {4'b00_01}; bins set_crc = {4'b00_10};
        bins set_range = {4'b00_11}; bins get_ack = {4'b01_00}; bins get_foreign = {4'b01_01};
        bins get_crc = {4'b01_10}; bins other_foreign = {4'b10_01}; bins other_crc = {4'b10_10};
        bins other_unknown = {4'b10_11}; }
    // SET code class x ramp direction (code 0 cannot ramp up, 0xFFF
    // cannot ramp down)
    cp_code_dir: coverpoint {(d[11:0] == 0) ? 2'd0 : (d[11:0] == 12'hFFF) ? 2'd2 : 2'd1,
                             (d[11:0] > m_t) ? 2'd0 : (d[11:0] < m_t) ? 2'd1 : 2'd2}
                 iff (rst_n && ack_slot && good && cm == 8'h01)
      { bins zero_down = {4'b00_01}; bins zero_same = {4'b00_10}; bins mid_up = {4'b01_00};
        bins mid_down = {4'b01_01}; bins mid_same = {4'b01_10}; bins max_up = {4'b10_00};
        bins max_same = {4'b10_10}; }
    cp_get: coverpoint m_v iff (rst_n && ack_slot && good && cm == 8'h02)
      { bins zero = {0}; bins max = {12'hFFF}; bins mid = {[1:12'hFFE]}; }
    cp_abandon: coverpoint fld iff (rst_n && idle == TIMEOUT && ph != 0)
      { bins addr = {0}; bins cmd = {1}; bins data_crc = {2}; bins ack_or_tx = {3}; }
  endgroup
  cg_frame u_cg_frame = new;

  `FC(set_acked, rise && ph == 2 && good && cm == 8'h01)
  `FC(get_acked, rise && ph == 2 && good && cm == 8'h02)
  `FC(nack_foreign_addr, rise && ph == 2 && a != 7'h55)
  `FC(nack_bad_crc, rise && ph == 2 && a == 7'h55 && sh[3:0] != c)
  `FC(nack_unknown_cmd, rise && ph == 2 && a == 7'h55 && sh[3:0] == c && !(cm inside {8'h01, 8'h02}))
  `FC(nack_code_out_of_range, rise && ph == 2 && a == 7'h55 && sh[3:0] == c && cm == 8'h01 && d[15:12] != 0)
  `FC(ramp_up, m_v < m_t)
  `FC(ramp_down, m_v > m_t)
  `FC(ramp_last_partial_step, m_v != m_t && (m_t - m_v < 10 || m_v - m_t < 10))
  `FC(frame_timeout, idle == TIMEOUT)
  `FC_RST(reset_while_ramping, rst_n && m_v != m_t ##1 !rst_n)
endmodule

bind AVSBus__Adaptive_Voltage_Scaling__top AVSBus__Adaptive_Voltage_Scaling__sva #(.TIMEOUT(TIMEOUT)) u_sva (.*);
