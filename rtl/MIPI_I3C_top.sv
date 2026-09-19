// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI I3C protocol IP -- I3C slave controller
// Implementation scope:
//   - Legacy I2C write/read on a 7-bit static address (16x8 register file)
//   - ENTDAA dynamic address assignment (broadcast CCC 0x07): slave returns
//     48-bit PID + BCR + DCR, then captures the 7-bit dynamic address
//   - Direct CCC GETPID (0x8C): subsequent addressed read returns 6 PID bytes
//   - IBI (in-band interrupt): slave pulls SDA while bus idle, arbitrates its
//     dynamic address, then pushes one IBI data byte
//   - Open-drain vs push-pull phase switching (address/arbitration phases are
//     open-drain, data transmit phases are push-pull -- simplified, the pad is
//     a shared clk-domain model so both are driven from the same enable logic)
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module MIPI_I3C_top #(
  parameter int DW = 32,              // data width (framework, unused width kept)
  parameter int AW = 32,              // address width (framework, kept)
  parameter logic [6:0]  STATIC_ADDR = 7'h3C,
  parameter logic [47:0] PID         = 48'h0123_4567_89AB,
  parameter logic [7:0]  BCR         = 8'h06,
  parameter logic [7:0]  DCR         = 8'h5A
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       scl,             // I3C clock (driven by the master)
  inout  wire        sda,             // I3C data (open-drain / push-pull)
  input  logic       ibi_req,         // level: request an in-band interrupt
  input  logic [7:0] ibi_data,        // IBI payload byte
  output logic [6:0] dyn_addr,        // assigned dynamic address
  output logic       dyn_addr_valid,
  output logic       irq              // sticky protocol-error / IBI-loss flag
);

  // ------------------------------------------------------------------
  // local constants
  // ------------------------------------------------------------------
  localparam logic [7:0] CCC_ENTDAA = 8'h07;
  localparam logic [7:0] CCC_GETPID = 8'h8C;

  typedef enum logic [4:0] {
    S_IDLE,        // bus idle / wait for START or issue IBI pull
    S_ADDR,        // shift in 7-bit address + RnW
    S_ADDR_ACK,    // drive ACK/NACK for the address phase
    S_RX_DATA,     // receive register / CCC data bytes
    S_RX_ACK,      // drive ACK/NACK for a received byte
    S_TX_DATA,     // transmit register / PID data byte (push-pull)
    S_TX_ACK,      // sample master ACK/NACK after a transmitted byte
    S_DAA_TX,      // ENTDAA: shift out 64 bits {PID,BCR,DCR} open-drain
    S_DAA_RX,      // ENTDAA: receive 7-bit dynamic address + parity
    S_DAA_ACK,     // ENTDAA: ACK the assigned dynamic address
    S_IBI_ARB,     // IBI: arbitrate own dynamic address (open-drain)
    S_IBI_ACK,     // IBI: sample master ACK of the arbitration
    S_IBI_TX,      // IBI: transmit payload byte (push-pull)
    S_IBI_TXACK,   // IBI: sample master ACK of the payload
    S_WAIT_STOP    // wait for STOP / repeated START
  } state_t;

  state_t state;

  // ------------------------------------------------------------------
  // input synchronizers (clk oversamples the I3C bus)
  // ------------------------------------------------------------------
  logic [2:0] scl_d, sda_d;
  wire sda_in = sda;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_d <= 3'b111;
      sda_d <= 3'b111;
    end else begin
      scl_d <= {scl_d[1:0], scl};
      sda_d <= {sda_d[1:0], sda_in};
    end
  end

  wire ev_scl_r = (scl_d[2:1] == 2'b01);
  wire ev_scl_f = (scl_d[2:1] == 2'b10);
  // START = SDA falling while SCL high; STOP = SDA rising while SCL high.
  // Both are qualified with "we are not the ones moving SDA".
  wire ev_start = scl_d[1] & (sda_d[2:1] == 2'b10) & ~od_low & ~pp_en;
  wire ev_stop  = scl_d[1] & (sda_d[2:1] == 2'b01) & ~od_low & ~pp_en;

  // ------------------------------------------------------------------
  // SDA pad: open-drain pull (address/ACK/arbitration) or push-pull (data)
  // ------------------------------------------------------------------
  logic od_low;              // open-drain: pull SDA low
  logic pp_en, pp_val;       // push-pull: drive SDA to pp_val
  assign sda = pp_en ? pp_val : (od_low ? 1'b0 : 1'bz);

  // ------------------------------------------------------------------
  // datapath registers
  // ------------------------------------------------------------------
  logic [7:0] sh;                    // receive shift register
  wire  [7:0] sh_full = {sh[6:0], sda_d[1]};
  logic [3:0] bcnt;                  // bit counter (byte phases)
  logic [5:0] dcnt;                  // bit counter (ENTDAA 64-bit phase)
  logic [7:0] txb;                   // transmit byte register
  logic       ack_ok;                // ACK decision for current ACK phase
  logic       ack_ph;                // ACK sub-phase (drive / release)
  logic       ack_smp;               // sampled master ACK
  logic       rnw_q, bcast_q;        // decoded address-phase qualifiers
  logic       bcast_mode;            // receiving broadcast CCC byte
  logic       first_byte;            // next RX byte is register pointer/CCC
  logic       pid_mode;              // GETPID pending: reads return PID
  logic       daa_pend;              // ENTDAA armed
  logic [3:0] reg_ptr;               // register-file pointer
  logic [3:0] pid_cnt;               // PID byte index
  logic [7:0] mem [0:15];            // 16x8 register file
  logic       ibi_pend;              // IBI request pending
  logic       ibi_pull;              // currently pulling SDA for IBI
  logic       err_sticky;            // protocol error flag -> irq

  wire [7:0] arb_word = {dyn_addr, 1'b1};      // IBI arbitration: addr + RnW=1

  // PID byte selector (current and next)
  wire [7:0] pid_byte =
      (pid_cnt == 4'd0) ? PID[47:40] :
      (pid_cnt == 4'd1) ? PID[39:32] :
      (pid_cnt == 4'd2) ? PID[31:24] :
      (pid_cnt == 4'd3) ? PID[23:16] :
      (pid_cnt == 4'd4) ? PID[15:8]  : PID[7:0];
  wire [7:0] pid_byte_n =
      (pid_cnt == 4'd0) ? PID[39:32] :
      (pid_cnt == 4'd1) ? PID[31:24] :
      (pid_cnt == 4'd2) ? PID[23:16] :
      (pid_cnt == 4'd3) ? PID[15:8]  :
      (pid_cnt == 4'd4) ? PID[7:0]   : PID[7:0];
  wire [7:0] tx_cur  = pid_mode ? pid_byte   : mem[reg_ptr];
  wire [7:0] tx_next = pid_mode ? pid_byte_n : mem[reg_ptr + 4'd1];

  // address-phase decode (combinational, used when 8th bit arrives)
  wire [6:0] rx_addr  = sh_full[7:1];
  wire       rx_rnw   = sh_full[0];
  wire       rx_bcast = (rx_addr == 7'h7E);
  wire       rx_match = (rx_addr == STATIC_ADDR) ||
                        (dyn_addr_valid && (rx_addr == dyn_addr));
  wire       rx_ack   = (rx_bcast & ~rx_rnw)              ||  // broadcast write
                        (rx_bcast &  rx_rnw & daa_pend)   ||  // ENTDAA read
                        rx_match;                              // our address

  assign irq = err_sticky;

  // ------------------------------------------------------------------
  // sequential FSM + datapath
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_IDLE;
      sh             <= 8'h00;
      bcnt           <= 4'd0;
      dcnt           <= 6'd0;
      txb            <= 8'h00;
      ack_ok         <= 1'b0;
      ack_ph         <= 1'b0;
      ack_smp        <= 1'b0;
      rnw_q          <= 1'b0;
      bcast_q        <= 1'b0;
      bcast_mode     <= 1'b0;
      first_byte     <= 1'b0;
      pid_mode       <= 1'b0;
      daa_pend       <= 1'b0;
      reg_ptr        <= 4'd0;
      pid_cnt        <= 4'd0;
      od_low         <= 1'b0;
      pp_en          <= 1'b0;
      pp_val         <= 1'b0;
      dyn_addr       <= 7'h00;
      dyn_addr_valid <= 1'b0;
      ibi_pend       <= 1'b0;
      ibi_pull       <= 1'b0;
      err_sticky     <= 1'b0;
    end else begin
      // latch IBI request (cleared when the IBI byte has been delivered)
      if (ibi_req) ibi_pend <= 1'b1;

      if (ev_start) begin
        // START / repeated START: (re)enter address phase, clear error flag
        state      <= S_ADDR;
        bcnt       <= 4'd0;
        ack_ph     <= 1'b0;
        od_low     <= 1'b0;
        pp_en      <= 1'b0;
        bcast_mode <= 1'b0;
        err_sticky <= 1'b0;
      end else if (ev_stop) begin
        // STOP: back to idle, keep dynamic address, drop phase qualifiers
        state      <= S_IDLE;
        od_low     <= 1'b0;
        pp_en      <= 1'b0;
        ack_ph     <= 1'b0;
        bcast_mode <= 1'b0;
        first_byte <= 1'b0;
        pid_mode   <= 1'b0;
        daa_pend   <= 1'b0;
      end else begin
        case (state)
          // ------------------------------------------------ idle / IBI pull
          S_IDLE: begin
            if (ibi_pend && !ibi_pull) begin
              od_low   <= 1'b1;   // pull SDA to request in-band interrupt
              ibi_pull <= 1'b1;
            end else if (ibi_pull && ev_scl_f) begin
              // master took over and started clocking: arbitrate address
              od_low   <= ~arb_word[7];
              ibi_pull <= 1'b0;
              bcnt     <= 4'd0;
              state    <= S_IBI_ARB;
            end
          end

          // ------------------------------------------------ address phase
          S_ADDR: begin
            if (ev_scl_r) begin
              sh <= sh_full;
              if (bcnt == 4'd7) begin
                bcnt    <= 4'd0;
                ack_ok  <= rx_ack;
                rnw_q   <= rx_rnw;
                bcast_q <= rx_bcast;
                if (!rx_ack) err_sticky <= rx_bcast & rx_rnw; // 7E/R w/o DAA
                state   <= S_ADDR_ACK;
              end else begin
                bcnt <= bcnt + 4'd1;
              end
            end
          end

          S_ADDR_ACK: begin
            if (ev_scl_f && !ack_ph) begin
              od_low <= ack_ok;        // drive ACK during 9th clock low
              ack_ph <= 1'b1;
            end else if (ev_scl_f && ack_ph) begin
              od_low <= 1'b0;          // release after 9th clock
              ack_ph <= 1'b0;
              bcnt   <= 4'd0;
              if (!ack_ok) begin
                state <= S_WAIT_STOP;
              end else if (bcast_q && !rnw_q) begin
                bcast_mode <= 1'b1;    // broadcast CCC byte follows
                state      <= S_RX_DATA;
              end else if (bcast_q && rnw_q) begin
                dcnt   <= 6'd0;        // ENTDAA: send {PID,BCR,DCR}
                od_low <= ~PID[47];    // first bit (open-drain)
                state  <= S_DAA_TX;
              end else if (!rnw_q) begin
                bcast_mode <= 1'b0;
                first_byte <= 1'b1;    // first RX byte = reg ptr / direct CCC
                state      <= S_RX_DATA;
              end else begin
                txb    <= tx_cur;      // addressed read: register or PID data
                pp_en  <= 1'b1;        // data phase is push-pull
                pp_val <= tx_cur[7];
                state  <= S_TX_DATA;
              end
            end
          end

          // ------------------------------------------------ receive data
          S_RX_DATA: begin
            if (ev_scl_r) begin
              sh <= sh_full;
              if (bcnt == 4'd7) begin
                bcnt  <= 4'd0;
                state <= S_RX_ACK;
                if (bcast_mode) begin
                  // broadcast CCC: only ENTDAA is supported
                  if (sh_full == CCC_ENTDAA) begin
                    ack_ok   <= 1'b1;
                    daa_pend <= 1'b1;
                  end else begin
                    ack_ok     <= 1'b0;      // unknown CCC -> NACK + irq
                    err_sticky <= 1'b1;
                  end
                end else if (first_byte) begin
                  if (sh_full == CCC_GETPID) begin
                    ack_ok   <= 1'b1;        // direct CCC GETPID
                    pid_mode <= 1'b1;
                    pid_cnt  <= 4'd0;
                  end else if (sh_full[7]) begin
                    ack_ok     <= 1'b0;      // unknown direct CCC -> NACK+irq
                    err_sticky <= 1'b1;
                  end else begin
                    ack_ok     <= 1'b1;      // register pointer byte
                    reg_ptr    <= sh_full[3:0];
                    first_byte <= 1'b0;
                  end
                end else begin
                  ack_ok        <= 1'b1;     // register write data byte
                  mem[reg_ptr]  <= sh_full;
                  reg_ptr       <= reg_ptr + 4'd1;
                end
              end else begin
                bcnt <= bcnt + 4'd1;
              end
            end
          end

          S_RX_ACK: begin
            if (ev_scl_f && !ack_ph) begin
              od_low <= ack_ok;
              ack_ph <= 1'b1;
            end else if (ev_scl_f && ack_ph) begin
              od_low <= 1'b0;
              ack_ph <= 1'b0;
              bcnt   <= 4'd0;
              state  <= ack_ok ? S_RX_DATA : S_WAIT_STOP;
            end
          end

          // ------------------------------------------------ transmit data
          S_TX_DATA: begin
            if (ev_scl_f) begin
              if (bcnt == 4'd7) begin
                pp_en <= 1'b0;         // release for master ACK
                bcnt  <= 4'd0;
                state <= S_TX_ACK;
              end else begin
                bcnt   <= bcnt + 4'd1;
                pp_val <= txb[3'd6 - bcnt[2:0]];
              end
            end
          end

          S_TX_ACK: begin
            if (ev_scl_r) ack_smp <= (sda_d[1] == 1'b0);
            if (ev_scl_f) begin
              if (ack_smp) begin       // master wants another byte
                txb     <= tx_next;
                pp_en   <= 1'b1;
                pp_val  <= tx_next[7];
                bcnt    <= 4'd0;
                reg_ptr <= reg_ptr + 4'd1;
                pid_cnt <= pid_cnt + 4'd1;
                state   <= S_TX_DATA;
              end else begin
                state <= S_WAIT_STOP;  // master NACKed: end of read
              end
            end
          end

          // ------------------------------------------------ ENTDAA
          S_DAA_TX: begin
            if (ev_scl_f) begin
              if (dcnt == 6'd63) begin
                od_low <= 1'b0;
                bcnt   <= 4'd0;
                state  <= S_DAA_RX;
              end else begin
                dcnt   <= dcnt + 6'd1;
                od_low <= ~((dcnt < 6'd47) ? PID[6'd46 - dcnt] :
                            (dcnt < 6'd55) ? BCR[6'd54 - dcnt] :
                                             DCR[6'd62 - dcnt]);
              end
            end
          end

          S_DAA_RX: begin
            if (ev_scl_r) begin
              sh <= sh_full;
              if (bcnt == 4'd7) begin
                bcnt           <= 4'd0;
                dyn_addr       <= sh_full[7:1];   // 7-bit address + parity
                dyn_addr_valid <= 1'b1;
                daa_pend       <= 1'b0;
                ack_ok         <= 1'b1;
                state          <= S_DAA_ACK;
              end else begin
                bcnt <= bcnt + 4'd1;
              end
            end
          end

          S_DAA_ACK: begin
            if (ev_scl_f && !ack_ph) begin
              od_low <= 1'b1;          // ACK the assigned address
              ack_ph <= 1'b1;
            end else if (ev_scl_f && ack_ph) begin
              od_low <= 1'b0;
              ack_ph <= 1'b0;
              state  <= S_WAIT_STOP;
            end
          end

          // ------------------------------------------------ IBI
          S_IBI_ARB: begin
            if (ev_scl_r) begin
              // arbitration monitor: we released SDA for a '1' but read '0'
              if (arb_word[3'd7 - bcnt[2:0]] && (sda_d[1] == 1'b0)) begin
                od_low     <= 1'b0;
                ibi_pend   <= 1'b0;    // lost arbitration -> retry next req
                err_sticky <= 1'b1;
                state      <= S_WAIT_STOP;
              end
            end
            if (ev_scl_f) begin
              if (bcnt == 4'd7) begin
                od_low <= 1'b0;
                bcnt   <= 4'd0;
                state  <= S_IBI_ACK;
              end else begin
                bcnt   <= bcnt + 4'd1;
                od_low <= ~arb_word[3'd6 - bcnt[2:0]];
              end
            end
          end

          S_IBI_ACK: begin
            if (ev_scl_r) ack_smp <= (sda_d[1] == 1'b0);
            if (ev_scl_f) begin
              if (ack_smp) begin       // master accepts the IBI
                txb    <= ibi_data;
                pp_en  <= 1'b1;
                pp_val <= ibi_data[7];
                bcnt   <= 4'd0;
                state  <= S_IBI_TX;
              end else begin
                state  <= S_WAIT_STOP; // refused: keep ibi_pend for retry
              end
            end
          end

          S_IBI_TX: begin
            if (ev_scl_f) begin
              if (bcnt == 4'd7) begin
                pp_en <= 1'b0;
                bcnt  <= 4'd0;
                state <= S_IBI_TXACK;
              end else begin
                bcnt   <= bcnt + 4'd1;
                pp_val <= txb[3'd6 - bcnt[2:0]];
              end
            end
          end

          S_IBI_TXACK: begin
            if (ev_scl_f) begin
              ibi_pend <= 1'b0;        // payload delivered
              state    <= S_WAIT_STOP;
            end
          end

          // ------------------------------------------------ drain
          S_WAIT_STOP: begin
            od_low <= 1'b0;
            pp_en  <= 1'b0;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

endmodule
