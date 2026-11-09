// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// I2C_Host: I2C controller (master) for sensor / PMIC control
// ----------------------------------------------------------------------------
// The controller role the I2C_top target does not cover. Byte commands in
// the style of the OpenCores I2C master:
// - A command (cmd_valid) is any of: STA (START, or a repeated START when
//   the bus is held), then WR (send TX_DATA, read the ACK bit into RX_ACK)
//   or RD (read a byte into RX_DATA, then send ACK, or NACK with NACK = 1),
//   then STO (STOP). DONE pulses when the command ends; BUSY is high during
//   it. A command while busy is ignored; STO alone with the bus free does
//   nothing on the wire.
// - Timing: one quarter of the SCL period is PRESCALE + 1 clocks (at least
//   3, for targets that sample on their own clock). SCL is driven push-pull
//   (no clock stretching, single controller); SDA is open drain.
// - BUS_HELD: SCL is low between a START and a STOP (the controller owns
//   the bus).
// ============================================================================
module I2C_Host_top (
  input  logic        clk,
  input  logic        rst_n,
  // I2C pins
  output logic        scl,
  inout  tri          sda,
  // command
  input  logic [15:0] prescale,
  input  logic        cmd_valid,
  input  logic        cmd_sta,
  input  logic        cmd_wr,
  input  logic        cmd_rd,
  input  logic        cmd_sto,
  input  logic        cmd_nack,
  input  logic [7:0]  tx_data,
  output logic [7:0]  rx_data,
  output logic        rx_ack,        // ACK bit after WR: 0 ACK, 1 NACK
  output logic        busy,
  output logic        bus_held,
  output logic        done
);
  typedef enum logic [2:0] {S_IDLE, S_STA, S_BIT, S_ACK, S_STO} st_t;
  st_t st;
  logic        sda_lo;               // pull SDA low
  logic [15:0] qcnt;                 // clocks left in this quarter
  logic [1:0]  q;                    // quarter of the current bit / condition
  logic [2:0]  bi;                   // bit of the byte (7 first)
  logic        sta_q, wr_q, rd_q, sto_q, nack_q;
  logic [7:0]  sh;
  logic        sda_s;

  assign sda = sda_lo ? 1'b0 : 1'bz;
  assign busy = (st != S_IDLE);
  wire   qend = (qcnt == 16'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; sda_lo <= 1'b0; scl <= 1'b1; qcnt <= '0; q <= '0; bi <= '0;
      sta_q <= 1'b0; wr_q <= 1'b0; rd_q <= 1'b0; sto_q <= 1'b0; nack_q <= 1'b0;
      sh <= '0; rx_data <= '0; rx_ack <= 1'b0; bus_held <= 1'b0; done <= 1'b0; sda_s <= 1'b1;
    end else begin
      done  <= 1'b0;
      sda_s <= (sda !== 1'b0);
      if (st != S_IDLE) qcnt <= qend ? prescale : qcnt - 16'd1;
      case (st)
        S_IDLE: if (cmd_valid) begin
          sta_q <= cmd_sta; wr_q <= cmd_wr; rd_q <= cmd_rd && !cmd_wr; sto_q <= cmd_sto;
          nack_q <= cmd_nack; sh <= tx_data; q <= '0; bi <= 3'd7; qcnt <= prescale;
          if (cmd_sta) st <= S_STA;
          else if (cmd_wr || cmd_rd) st <= S_BIT;
          else if (cmd_sto && bus_held) st <= S_STO;
          else done <= 1'b1;                       // nothing to do (STO with the bus free)
        end
        // START / repeated START: SDA up, SCL up, SDA down, SCL down
        S_STA: if (qend) begin
          q <= q + 2'd1;
          case (q)
            2'd0: sda_lo <= 1'b0;
            2'd1: scl <= 1'b1;
            2'd2: sda_lo <= 1'b1;
            default: begin
              scl <= 1'b0; bus_held <= 1'b1; q <= '0;
              if (wr_q || rd_q) st <= S_BIT;
              else if (sto_q) st <= S_STO;
              else begin st <= S_IDLE; done <= 1'b1; end
            end
          endcase
        end
        // data bit: set SDA, SCL up, sample (middle of the high time), SCL down
        S_BIT: if (qend) begin
          q <= q + 2'd1;
          case (q)
            2'd0: sda_lo <= wr_q ? !sh[7] : 1'b0;
            2'd1: scl <= 1'b1;
            2'd2: if (rd_q) sh <= {sh[6:0], sda_s};
            default: begin
              scl <= 1'b0; q <= '0;
              if (wr_q) sh <= {sh[6:0], 1'b0};
              if (bi == 3'd0) st <= S_ACK; else bi <= bi - 3'd1;
            end
          endcase
        end
        // ACK bit: read it after WR, send it after RD
        S_ACK: if (qend) begin
          q <= q + 2'd1;
          case (q)
            2'd0: sda_lo <= rd_q && !nack_q;
            2'd1: scl <= 1'b1;
            2'd2: if (wr_q) rx_ack <= sda_s;
            default: begin
              scl <= 1'b0; q <= '0;
              if (rd_q) rx_data <= sh;
              if (sto_q) st <= S_STO;
              else begin sda_lo <= 1'b0; st <= S_IDLE; done <= 1'b1; end
            end
          endcase
        end
        // STOP: SDA down, SCL up, SDA up, bus free time
        S_STO: if (qend) begin
          q <= q + 2'd1;
          case (q)
            2'd0: sda_lo <= 1'b1;
            2'd1: scl <= 1'b1;
            2'd2: begin sda_lo <= 1'b0; bus_held <= 1'b0; end
            default: begin q <= '0; st <= S_IDLE; done <= 1'b1; end
          endcase
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
