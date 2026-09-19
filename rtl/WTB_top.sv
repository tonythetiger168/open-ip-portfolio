// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// WTB protocol -- IEEE 802.4 style token-bus station (educational slice)
// Frame: preamble(8'h55 x2) + SD(8'hD5) + FC{0=claim,1=token,2=data,3=solicit}
//        + DA + SA + LEN + payload(<=16B) + CRC16(0x1021,init 0xFFFF) + ED(8'hD4)
// Serial rx/tx at 1 bit/clk (MSB first per byte), idle bus = 1.
// Station FSM: LISTEN -> token(DA==my_addr) -> HOLD window (<=4 frames or
//   <=200 clk) -> data frames from 8x32 TX FIFO (cpu port) -> pass token to NS.
// claim_token contention after bus-idle timeout with response window.
// Bad CRC / bad ED / overlong frames are dropped + irq pulse.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module WTB_top #(
  parameter int DW = 32,             // cpu data width
  parameter int AW = 32,             // kept for framework compatibility
  parameter int IDLE_TO   = 300,     // bus-idle clocks before claim_token
  parameter int CLAIM_WIN = 150,     // claim response window (clocks)
  parameter int HOLD_WIN  = 200,     // token holding window (clocks)
  parameter int MAX_FR    = 4        // max data frames per token hold
)(
  input  logic        clk,
  input  logic        rst_n,
  // serial token-bus
  input  logic        rx_bit,
  output logic        tx_bit,
  output logic        tx_en,
  // station identity
  input  logic [7:0]  my_addr,
  // cpu port: 0=TX FIFO push, 1=NS register, 2=data-DA register, 3=ctrl(claim_en)
  input  logic        cpu_we,
  input  logic [1:0]  cpu_addr,
  input  logic [DW-1:0] cpu_wdata,
  output logic [3:0]  fifo_count,
  output logic        token_held,
  output logic        irq
);

  // frame control codes
  localparam logic [7:0] FC_CLAIM = 8'h00;
  localparam logic [7:0] FC_TOKEN = 8'h01;
  localparam logic [7:0] FC_DATA  = 8'h02;
  localparam logic [7:0] FC_SOL   = 8'h03;  // solicit (decode only)
  // byte constants
  localparam logic [7:0] B_PRE = 8'h55;
  localparam logic [7:0] B_SD  = 8'hD5;
  localparam logic [7:0] B_ED  = 8'hD4;

  // ------------------------------------------------------------------
  // CRC16 (poly 0x1021, init 0xFFFF), byte-wise update
  // ------------------------------------------------------------------
  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    begin
      c = crc ^ {data, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_byte = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // configuration registers + TX FIFO (8 x 32)
  // ------------------------------------------------------------------
  logic [7:0]  ns_reg;        // next-station address
  logic [7:0]  da_reg;        // data-frame destination
  logic        claim_en;
  logic [31:0] fifo [0:7];
  logic [2:0]  fifo_wr, fifo_rd;
  logic [3:0]  fifo_cnt;
  logic        fifo_pop;
  logic        cfg_irq;
  logic        push, pop;

  assign fifo_count = fifo_cnt;
  assign push = cpu_we && (cpu_addr == 2'd0);
  assign pop  = fifo_pop && (fifo_cnt != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ns_reg   <= 8'h02;
      da_reg   <= 8'hFF;
      claim_en <= 1'b0;
      fifo_wr  <= '0;
      fifo_rd  <= '0;
      fifo_cnt <= '0;
      cfg_irq  <= 1'b0;
    end else begin
      cfg_irq <= 1'b0;
      if (cpu_we && (cpu_addr != 2'd0)) begin
        case (cpu_addr)
          2'd1: ns_reg   <= cpu_wdata[7:0];
          2'd2: da_reg   <= cpu_wdata[7:0];
          2'd3: claim_en <= cpu_wdata[0];
          default: ;
        endcase
      end
      // FIFO push / pop (may happen in the same cycle)
      if (push && (fifo_cnt < 4'd8 || pop)) begin
        fifo[fifo_wr] <= cpu_wdata;
        fifo_wr       <= fifo_wr + 3'd1;
      end else if (push) begin
        cfg_irq <= 1'b1;            // FIFO overflow write
      end
      if (pop) fifo_rd <= fifo_rd + 3'd1;
      case ({push && (fifo_cnt < 4'd8 || pop), pop})
        2'b10:   fifo_cnt <= fifo_cnt + 4'd1;
        2'b01:   fifo_cnt <= fifo_cnt - 4'd1;
        default: fifo_cnt <= fifo_cnt;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // RX engine: bit-serial hunt for 0x55 0xD5, then byte-aligned fields
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    R_HUNT, R_FC, R_DA, R_SA, R_LEN, R_PAY, R_CRCH, R_CRCL, R_ED
  } rstate_t;
  rstate_t     rstate;
  logic [15:0] sh16;
  logic [7:0]  sh8;
  logic [2:0]  bit_cnt;
  logic [15:0] rcrc;
  logic [7:0]  rfc, rda, rsa, rlen;
  logic [3:0]  rpay_cnt;
  logic [7:0]  rcrc_hi;
  logic        rx_done, rx_bad;
  logic        crc_ok;
  logic [7:0]  rx_fc, rx_da, rx_sa;

  wire [7:0] rbyte = {sh8[6:0], rx_bit};   // completed byte

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate   <= R_HUNT;
      sh16     <= 16'hFFFF;
      sh8      <= 8'hFF;
      bit_cnt  <= '0;
      rcrc     <= 16'hFFFF;
      rfc      <= '0; rda <= '0; rsa <= '0; rlen <= '0;
      rpay_cnt <= '0;
      rcrc_hi  <= '0;
      rx_done  <= 1'b0;
      rx_bad   <= 1'b0;
      crc_ok   <= 1'b0;
      rx_fc    <= '0; rx_da <= '0; rx_sa <= '0;
    end else begin
      rx_done <= 1'b0;
      rx_bad  <= 1'b0;
      case (rstate)
        R_HUNT: begin
          sh16 <= {sh16[14:0], rx_bit};
          if ({sh16[14:0], rx_bit} == {B_PRE, B_SD}) begin
            rstate  <= R_FC;
            bit_cnt <= '0;
            sh8     <= 8'h00;
            rcrc    <= 16'hFFFF;
          end
        end
        default: begin
          sh8     <= rbyte;
          bit_cnt <= bit_cnt + 3'd1;
          if (bit_cnt == 3'd7) begin
            bit_cnt <= '0;
            case (rstate)
              R_FC: begin
                rfc  <= rbyte;
                rcrc <= crc16_byte(16'hFFFF, rbyte);
                rstate <= R_DA;
              end
              R_DA: begin
                rda  <= rbyte;
                rcrc <= crc16_byte(rcrc, rbyte);
                rstate <= R_SA;
              end
              R_SA: begin
                rsa  <= rbyte;
                rcrc <= crc16_byte(rcrc, rbyte);
                rstate <= R_LEN;
              end
              R_LEN: begin
                rlen <= rbyte;
                rcrc <= crc16_byte(rcrc, rbyte);
                rpay_cnt <= '0;
                if (rbyte > 8'd16) begin
                  rx_bad <= 1'b1;           // overlong frame: drop
                  rstate <= R_HUNT;
                end else if (rbyte == 8'd0) begin
                  rstate <= R_CRCH;
                end else begin
                  rstate <= R_PAY;
                end
              end
              R_PAY: begin
                rcrc <= crc16_byte(rcrc, rbyte);
                rpay_cnt <= rpay_cnt + 4'd1;
                if (rpay_cnt == rlen[3:0] - 4'd1) rstate <= R_CRCH;
              end
              R_CRCH: begin
                rcrc_hi <= rbyte;
                rstate  <= R_CRCL;
              end
              R_CRCL: begin
                crc_ok <= (rcrc == {rcrc_hi, rbyte});
                if (rcrc != {rcrc_hi, rbyte}) rx_bad <= 1'b1; // CRC error
                rstate <= R_ED;
              end
              R_ED: begin
                if (rbyte != B_ED) begin
                  rx_bad <= 1'b1;           // bad end delimiter
                end else if (crc_ok) begin
                  rx_done <= 1'b1;
                  rx_fc   <= rfc;
                  rx_da   <= rda;
                  rx_sa   <= rsa;
                end
                rstate <= R_HUNT;
                sh16   <= 16'hFFFF;
              end
              default: rstate <= R_HUNT;
            endcase
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // TX engine: serialize one frame on request
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    T_IDLE, T_PRE1, T_PRE2, T_SD, T_FC, T_DA, T_SA, T_LEN,
    T_PAY, T_CRCH, T_CRCL, T_ED
  } tstate_t;
  tstate_t     tstate;
  logic [7:0]  tsh;
  logic [7:0]  tcur;   // byte currently being shifted out (for CRC)
  logic [2:0]  tbit;
  logic [15:0] tcrc;
  logic [7:0]  tfc, tda;
  logic [31:0] tword;
  logic [2:0]  tpay_cnt;
  logic        tx_start;
  logic [7:0]  tx_fc_in, tx_da_in;
  logic [31:0] tx_word_in;
  logic        tx_busy, tx_done;

  logic [15:0] tcrc_next;
  always_comb tcrc_next = crc16_byte(tcrc, tcur);

  // payload byte selector (big-endian word on the wire)
  function automatic logic [7:0] pay_byte(input logic [31:0] w,
                                          input logic [2:0]  i);
    case (i)
      3'd0:    pay_byte = w[31:24];
      3'd1:    pay_byte = w[23:16];
      3'd2:    pay_byte = w[15:8];
      default: pay_byte = w[7:0];
    endcase
  endfunction

  assign tx_busy = (tstate != T_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate   <= T_IDLE;
      tsh      <= 8'hFF;
      tcur     <= 8'hFF;
      tbit     <= '0;
      tcrc     <= 16'hFFFF;
      tfc      <= '0; tda <= '0;
      tword    <= '0;
      tpay_cnt <= '0;
      tx_bit   <= 1'b1;
      tx_en    <= 1'b0;
      tx_done  <= 1'b0;
    end else begin
      tx_done <= 1'b0;
      if (tstate == T_IDLE) begin
        tx_en  <= 1'b0;
        tx_bit <= 1'b1;
        if (tx_start) begin
          tstate <= T_PRE1;
          tsh    <= {B_PRE[6:0], 1'b0};   // pre-shifted: bit7 driven this cycle
          tcur   <= B_PRE;
          tbit   <= 3'd1;
          tcrc   <= 16'hFFFF;
          tfc    <= tx_fc_in;
          tda    <= tx_da_in;
          tword  <= tx_word_in;
          tpay_cnt <= '0;
          tx_en  <= 1'b1;
          tx_bit <= B_PRE[7];
        end
      end else begin
        tx_en  <= 1'b1;
        tx_bit <= tsh[7];
        tsh    <= {tsh[6:0], 1'b0};
        if (tbit == 3'd7) begin
          tbit <= '0;
          case (tstate)
            T_PRE1: begin tstate <= T_PRE2; tsh <= B_PRE; tcur <= B_PRE; end
            T_PRE2: begin tstate <= T_SD;   tsh <= B_SD;  tcur <= B_SD;  end
            T_SD:   begin tstate <= T_FC;   tsh <= tfc;   tcur <= tfc;   end
            T_FC: begin
              tstate <= T_DA; tsh <= tda; tcur <= tda;
              tcrc   <= tcrc_next;               // crc over FC
            end
            T_DA: begin
              tstate <= T_SA; tsh <= my_addr; tcur <= my_addr;
              tcrc   <= tcrc_next;               // crc over DA
            end
            T_SA: begin
              tstate <= T_LEN;
              tsh    <= (tfc == FC_DATA) ? 8'd4 : 8'd0;
              tcur   <= (tfc == FC_DATA) ? 8'd4 : 8'd0;
              tcrc   <= tcrc_next;               // crc over SA
            end
            T_LEN: begin
              tcrc   <= tcrc_next;               // crc over LEN
              if (tfc == FC_DATA) begin
                tstate   <= T_PAY;
                tsh      <= pay_byte(tword, 3'd0);
                tcur     <= pay_byte(tword, 3'd0);
                tpay_cnt <= '0;
              end else begin
                tstate <= T_CRCH;
                tsh    <= tcrc_next[15:8];
              end
            end
            T_PAY: begin
              tcrc <= tcrc_next;                 // crc over payload
              if (tpay_cnt == 3'd3) begin
                tstate <= T_CRCH;
                tsh    <= tcrc_next[15:8];
              end else begin
                tpay_cnt <= tpay_cnt + 3'd1;
                tsh      <= pay_byte(tword, tpay_cnt + 3'd1);
                tcur     <= pay_byte(tword, tpay_cnt + 3'd1);
              end
            end
            T_CRCH: begin tstate <= T_CRCL; tsh <= tcrc[7:0]; end
            T_CRCL: begin tstate <= T_ED;   tsh <= B_ED;      end
            T_ED: begin
              tstate  <= T_IDLE;
              tx_done <= 1'b1;
            end
            default: tstate <= T_IDLE;
          endcase
        end else begin
          tbit <= tbit + 3'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // station FSM
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_LISTEN, ST_HOLD, ST_CLAIM_TX, ST_CLAIM_WAIT, ST_PASS
  } sstate_t;
  sstate_t     sstate;
  logic [15:0] idle_cnt;
  logic [7:0]  hold_cnt;
  logic [2:0]  fr_sent;
  logic [7:0]  claim_cnt;
  logic        tok_irq;

  assign token_held = (sstate == ST_HOLD) || (sstate == ST_PASS);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sstate    <= ST_LISTEN;
      idle_cnt  <= '0;
      hold_cnt  <= '0;
      fr_sent   <= '0;
      claim_cnt <= '0;
      tx_start  <= 1'b0;
      tx_fc_in  <= '0;
      tx_da_in  <= '0;
      tx_word_in<= '0;
      fifo_pop  <= 1'b0;
      tok_irq   <= 1'b0;
    end else begin
      tx_start <= 1'b0;
      fifo_pop <= 1'b0;
      tok_irq  <= 1'b0;

      // bus idle timer (saturates)
      if (!rx_bit) idle_cnt <= '0;
      else if (idle_cnt != 16'hFFFF) idle_cnt <= idle_cnt + 16'd1;

      case (sstate)
        ST_LISTEN: begin
          if (rx_done && rx_fc == FC_TOKEN && rx_da == my_addr) begin
            sstate   <= ST_HOLD;
            hold_cnt <= '0;
            fr_sent  <= '0;
          end else if (claim_en && idle_cnt >= IDLE_TO[15:0] && !tx_busy) begin
            // bus silent: contend for the token
            tx_start  <= 1'b1;
            tx_fc_in  <= FC_CLAIM;
            tx_da_in  <= 8'hFF;
            tx_word_in<= 32'h0;
            sstate    <= ST_CLAIM_TX;
          end
        end

        ST_HOLD: begin
          if (hold_cnt != 8'hFF) hold_cnt <= hold_cnt + 8'd1;
          if (!tx_busy && !tx_start) begin
            if (fr_sent < MAX_FR[2:0] && hold_cnt < HOLD_WIN[7:0] &&
                fifo_cnt != 0) begin
              // transmit queued data frame (4-byte payload)
              tx_start   <= 1'b1;
              tx_fc_in   <= FC_DATA;
              tx_da_in   <= da_reg;
              tx_word_in <= fifo[fifo_rd];
              fifo_pop   <= 1'b1;
              fr_sent    <= fr_sent + 3'd1;
            end else begin
              // window over: pass token to next station
              tx_start   <= 1'b1;
              tx_fc_in   <= FC_TOKEN;
              tx_da_in   <= ns_reg;
              tx_word_in <= 32'h0;
              sstate     <= ST_PASS;
            end
          end
        end

        ST_PASS: begin
          if (tx_done) sstate <= ST_LISTEN;
        end

        ST_CLAIM_TX: begin
          if (tx_done) begin
            sstate    <= ST_CLAIM_WAIT;
            claim_cnt <= '0;
          end
        end

        ST_CLAIM_WAIT: begin
          claim_cnt <= claim_cnt + 8'd1;
          if (rx_done) begin
            if (rx_fc == FC_TOKEN && rx_da == my_addr) begin
              sstate   <= ST_HOLD;          // someone passed us the token
              hold_cnt <= '0;
              fr_sent  <= '0;
            end else if (rx_fc == FC_CLAIM && rx_sa < my_addr) begin
              sstate <= ST_LISTEN;          // lower address wins: back off
            end else begin
              sstate <= ST_LISTEN;          // other activity: retry later
            end
          end else if (claim_cnt >= CLAIM_WIN[7:0]) begin
            // no contender: we hold the token
            sstate   <= ST_HOLD;
            hold_cnt <= '0;
            fr_sent  <= '0;
          end
        end

        default: sstate <= ST_LISTEN;
      endcase
    end
  end

  // irq: bad frame (CRC/ED/len) or FIFO overflow, single-cycle pulse
  always_comb irq = rx_bad | cfg_irq | tok_irq;

endmodule
