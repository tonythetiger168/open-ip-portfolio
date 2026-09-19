// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// AVSBus (Adaptive Voltage Scaling, PMBus-style) -- synthesizable slave
// Scope: serial sclk/sdat (open-drain) frame interface:
//          START + addr[6:0] + cmd[7:0] + data[15:0] + CRC4 + ACK/NACK slot,
//        GET reads back {4'h0, vdac} + CRC4; set/get voltage commands with an
//        internal 12-bit DAC code register and a voltage ramp FSM (10 mV/clk,
//        1 code = 1 mV). NACK on illegal address / bad CRC / unknown command.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module AVSBus__Adaptive_Voltage_Scaling__top #(
  parameter int DW = 32,          // data width (framework parameter)
  parameter int AW = 32           // address width (framework parameter)
)(
  input  logic        clk,
  input  logic        rst_n,
  // ---------------- AVSBus serial interface --------------------------------
  input  logic        sclk,       // bus clock from master
  inout  wire         sdat,       // open-drain serial data (slave drives low only)
  // ---------------- voltage monitor / status -------------------------------
  output logic [11:0] vdac,       // current DAC code (1 code = 1 mV)
  output logic        busy,       // high while ramping toward target
  // ---------------- framework ----------------------------------------------
  output logic        irq         // protocol error event (CRC / unknown cmd)
);

  localparam logic [6:0] SLAVE_ADDR = 7'h55;
  localparam logic [7:0] CMD_SET    = 8'h01;  // set voltage: data[11:0] = code
  localparam logic [7:0] CMD_GET    = 8'h02;  // get voltage: readback vdac code
  localparam logic [11:0] RAMP_STEP = 12'd10; // 10 mV per clk

  // open-drain drive: pull low only
  logic sdat_oe;
  assign sdat = sdat_oe ? 1'b0 : 1'bz;
  wire  sdat_in = sdat;

  // ------------------------- bus clock / data synchronization ---------------
  logic [2:0] sclk_sync;
  logic [2:0] sdat_sync;
  wire sclk_rise = (sclk_sync[2:1] == 2'b01);
  wire sbit      = sdat_sync[2];

  // ------------------------- CRC4 (poly x^4+x+1, init 0, MSB first) ---------
  function automatic logic [3:0] crc4_bit(input logic [3:0] c, input logic b);
    logic fb;
    begin
      fb       = b ^ c[3];
      crc4_bit = {c[2], c[1], c[0] ^ fb, fb};
    end
  endfunction

  function automatic logic [3:0] crc4_vec16(input logic [15:0] d);
    logic [3:0] c;
    begin
      c = 4'h0;
      for (int i = 15; i >= 0; i--) c = crc4_bit(c, d[i]);
      crc4_vec16 = c;
    end
  endfunction

  // ------------------------- receive FSM ------------------------------------
  typedef enum logic [2:0] {AV_IDLE, AV_RX, AV_ACK, AV_TX, AV_DONE} avstate_t;
  avstate_t     avstate;
  logic [5:0]   bit_cnt;
  logic [34:0]  rx_shift;    // {addr[6:0], cmd[7:0], data[15:0], crc[3:0]}
  logic [3:0]   crc_calc;
  logic [19:0]  tx_shift;    // {rdata16, crc4} for GET readback
  logic [4:0]   tx_cnt;

  wire [6:0]  rx_addr = rx_shift[34:28];
  wire [7:0]  rx_cmd  = rx_shift[27:20];
  wire [15:0] rx_data = rx_shift[19:4];
  wire [3:0]  rx_crc  = rx_shift[3:0];

  wire addr_ok = (rx_addr == SLAVE_ADDR);
  wire cmd_ok  = (rx_cmd == CMD_SET) || (rx_cmd == CMD_GET);
  wire crc_ok  = (rx_crc == crc_calc);
  wire ack_ok  = addr_ok && crc_ok && cmd_ok;

  // ------------------------- voltage ramp registers -------------------------
  logic [11:0] vdac_q;         // current code
  logic [11:0] vtgt_q;         // target code
  wire  [15:0] get_word = {4'h0, vdac_q};

  // ==========================================================================
  // sequential logic
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_sync <= '0;
      sdat_sync <= '0;
      avstate   <= AV_IDLE;
      bit_cnt   <= '0;
      rx_shift  <= '0;
      crc_calc  <= 4'h0;
      tx_shift  <= '0;
      tx_cnt    <= '0;
      vdac_q    <= 12'h000;
      vtgt_q    <= 12'h000;
      irq       <= 1'b0;
    end else begin
      irq       <= 1'b0;   // single-cycle pulse
      sclk_sync <= {sclk_sync[1:0], sclk};
      sdat_sync <= {sdat_sync[1:0], sdat_in};

      // ---------------- voltage ramp: 10 mV per clk toward target ---------
      if (vdac_q != vtgt_q) begin
        if (vtgt_q > vdac_q)
          vdac_q <= ((vtgt_q - vdac_q) > RAMP_STEP) ? vdac_q + RAMP_STEP : vtgt_q;
        else
          vdac_q <= ((vdac_q - vtgt_q) > RAMP_STEP) ? vdac_q - RAMP_STEP : vtgt_q;
      end

      // ---------------- serial frame FSM (sclk rising-edge driven) --------
      case (avstate)
        AV_IDLE: if (sclk_rise && sbit) begin   // START bit
          avstate  <= AV_RX;
          bit_cnt  <= '0;
          crc_calc <= 4'h0;
        end

        AV_RX: if (sclk_rise) begin
          rx_shift <= {rx_shift[33:0], sbit};
          if (bit_cnt < 6'd31)
            crc_calc <= crc4_bit(crc_calc, sbit);
          if (bit_cnt == 6'd34)
            avstate <= AV_ACK;
          bit_cnt <= bit_cnt + 6'd1;
        end

        AV_ACK: if (sclk_rise) begin            // master samples ACK/NACK here
          if (ack_ok && (rx_cmd == CMD_SET))
            vtgt_q <= rx_data[11:0];
          if (ack_ok && (rx_cmd == CMD_GET)) begin
            tx_shift <= {get_word, crc4_vec16(get_word)};
            tx_cnt   <= '0;
            avstate  <= AV_TX;
          end else begin
            avstate <= AV_DONE;
          end
          // protocol errors on this slave address raise irq
          if (addr_ok && (!crc_ok || !cmd_ok))
            irq <= 1'b1;
        end

        AV_TX: if (sclk_rise) begin
          tx_shift <= {tx_shift[18:0], 1'b0};
          if (tx_cnt == 5'd19)
            avstate <= AV_DONE;
          tx_cnt <= tx_cnt + 5'd1;
        end

        AV_DONE: avstate <= AV_IDLE;
        default: avstate <= AV_IDLE;
      endcase
    end
  end

  // ==========================================================================
  // combinational outputs: open-drain sdat drive + status
  // ==========================================================================
  always_comb begin
    case (avstate)
      AV_ACK:  sdat_oe = ack_ok;          // drive low = ACK, release = NACK
      AV_TX:   sdat_oe = ~tx_shift[19];   // open-drain: drive low for 0 bits
      default: sdat_oe = 1'b0;
    endcase
    vdac = vdac_q;
    busy = (vdac_q != vtgt_q);
  end

endmodule
