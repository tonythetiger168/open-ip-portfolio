// SPDX-License-Identifier: Apache-2.0
// SPMI slave (simplified command set): a pin-level frame decoder predicts
// rx_valid/rx_byte/rx_addr, the write ACK bit and every read data bit
// (from tx_byte at the start of the read), and when the slave may drive.
`include "cov_macros.svh"
module SPMI_sva #(parameter logic [3:0] SPMI_ADDR = 4'h5) (
  input logic       clk, rst_n, sclk, sdata, rx_valid, busy, irq, sd_oe,
  input logic [7:0] rx_byte, rx_addr, tx_byte
);
  `COV_CLOCKING(clk, !rst_n)

  logic c1, c2, d1, d2;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin c1 <= 0; c2 <= 0; d1 <= 1; d2 <= 1; end
    else begin c1 <= sclk; c2 <= c1; d1 <= sdata; d2 <= d1; end
  wire rise = c1 && !c2, fall = !c1 && c2, ssc = !d1 && d2 && c1;

  // 0 idle, 1 header, 2 address, 3 write data, 4 ack, 5 read data, 6 ignore
  int         ph, n;
  logic [7:0] sh, m_addr, m_byte, m_tx;
  logic [3:0] m_cmd;
  logic       m_drv, m_valid;
  wire  [7:0] w = {sh[6:0], d1};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= 0; n <= 0; sh <= 0; m_addr <= 0; m_byte <= 0; m_tx <= 0; m_cmd <= 0;
      m_drv <= 0; m_valid <= 0;
    end else begin
      m_valid <= 0;
      if (ssc) begin ph <= 1; n <= 0; m_drv <= 0; end
      else if (rise && ph >= 1 && ph <= 3) begin
        sh <= w; n <= n + 1;
        if (n == 7) begin
          n <= 0;
          case (ph)
            1: if (w[7:4] == SPMI_ADDR) begin m_cmd <= w[3:0]; ph <= 2; end else ph <= 6;
            2: begin
              m_addr <= w; m_tx <= tx_byte;
              ph <= (m_cmd == 0) ? 3 : (m_cmd == 1) ? 5 : 6;
            end
            default: begin m_byte <= w; m_valid <= 1; ph <= 4; end
          endcase
        end
      end else if (fall) begin
        case (ph)
          4: begin m_drv <= 1; ph <= 0; end                  // ACK bit
          5: begin
            m_drv <= !m_tx[7 - n];
            if (n == 7) begin ph <= 0; n <= 0; end else n <= n + 1;
          end
          0: m_drv <= 0;
          default: ;
        endcase
      end
    end
  end

  `SVA_RST(a_reset_released, !rst_n, !sd_oe && !busy && !rx_valid)
  `SVA_INV(a_drive_model, sd_oe == m_drv)
  `SVA_INV(a_rx_valid_model, rx_valid == m_valid)
  `SVA_IMP(a_rx_data_model, rx_valid, rx_byte == m_byte && rx_addr == m_addr)
  `SVA_INV(a_busy_model, busy == (ph >= 1 && ph <= 5))
  `SVA_INV(a_irq_is_rx_valid, irq == rx_valid)

  // accepted command x register address class, write / read data
  // classes, every read bit position x value, the field a repeated SSC
  // restarted
  function automatic logic [1:0] bcls(input logic [7:0] v);
    bcls = (v == 8'h00) ? 2'd0 : (v == 8'hFF) ? 2'd1 : (v == 8'h55 || v == 8'hAA) ? 2'd2 : 2'd3;
  endfunction
  wire addr_done = rise && ph == 2 && n == 7;
  covergroup cg_frame @(posedge clk);
    option.per_instance = 1;
    cp_cmd: coverpoint m_cmd iff (rst_n && addr_done)
      { bins write = {0}; bins read = {1}; bins other = {[2:15]}; }
    cp_rw: coverpoint m_cmd iff (rst_n && addr_done && m_cmd <= 1) { bins write = {0}; bins read = {1}; }
    cp_reg: coverpoint w iff (rst_n && addr_done && m_cmd <= 1)
      { bins r00 = {8'h00}; bins rff = {8'hFF}; bins other = {[8'h01:8'hFE]}; }
    x_rw_reg: cross cp_rw, cp_reg;
    cp_wdata: coverpoint bcls(w) iff (rst_n && rise && ph == 3 && n == 7)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint bcls(m_tx) iff (rst_n && fall && ph == 5 && n == 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rpos: coverpoint n iff (rst_n && fall && ph == 5) { bins b[] = {[0:7]}; }
    cp_rval: coverpoint m_tx[7 - n] iff (rst_n && fall && ph == 5) { bins zero = {0}; bins one = {1}; }
    x_rbit: cross cp_rpos, cp_rval;
    cp_restart: coverpoint ph iff (rst_n && ssc && ph >= 1 && ph <= 3 && n > 0)
      { bins header = {1}; bins addr = {2}; bins data = {3}; }
  endgroup
  cg_frame u_cg_frame = new;

  `FC(write_acked, fall && ph == 4)
  `FC(read_bit0_low, fall && ph == 5 && n == 7 && !m_tx[0])
  `FC(read_all_ones, fall && ph == 5 && n == 0 && m_tx == 8'hFF)
  `FC(read_all_zero, fall && ph == 5 && n == 0 && m_tx == 8'h00)
  `FC(tx_byte_changes_during_read, ph == 5 && tx_byte != m_tx)
  `FC(other_slave_ignored, rise && ph == 1 && n == 7 && w[7:4] != SPMI_ADDR)
  `FC(illegal_cmd_ignored, rise && ph == 2 && n == 7 && m_cmd > 1)
  `FC(ssc_restarts_frame, ssc && ph >= 1 && ph <= 3 && n > 0)
  `FC(write_addr_00, m_valid && m_addr == 8'h00)
  `FC(write_addr_ff, m_valid && m_addr == 8'hFF)
  `FC_RST(reset_while_driving, rst_n && sd_oe ##1 !rst_n)
endmodule

bind SPMI_top SPMI_sva #(.SPMI_ADDR(SPMI_ADDR)) u_sva (.*);
