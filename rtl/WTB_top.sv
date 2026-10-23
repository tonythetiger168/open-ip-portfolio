// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// WTB protocol -- IEEE 802.4 style token-bus station (educational slice)
// Frame: preamble(8'h55 x2) + SD(8'hD5) + FC{0=claim,1=token,2=data,3=solicit}
//        + DA + SA + LEN + payload(<=16B) + CRC16(0x1021,init 0xFFFF) + ED(8'hD4)
// Serial rx/tx at 1 bit/clk (MSB first per byte), idle bus = 1.
// Station FSM: LISTEN -> token(DA==my_addr) -> HOLD: data frames (4-byte
//   payload) from the 8x32 TX FIFO while fewer than MAX_FR frames were sent
//   and the hold time is below the programmable window -> pass token to NS.
// claim_token contention after bus-idle timeout with response window: a
//   claim from a lower address wins (we back off), a claim from a higher
//   address is ignored, other traffic ends the attempt.
// The station hears its own frames on the bus; frames with SA == my_addr
//   are ignored.
// Data frames for my_addr (or broadcast DA 8'hFF) with a good CRC and ED
//   are delivered to an 8x32 RX FIFO: payload bytes packed big-endian into
//   words, the last word zero-padded; a word that does not fit is dropped
//   with irq.
// irq (1-clk pulse): bad CRC / bad ED / overlong frame, TX FIFO overflow,
//   RX FIFO overflow, token acquired.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module WTB_top #(
  parameter int IDLE_TO   = 300,     // bus-idle clocks before claim_token
  parameter int CLAIM_WIN = 150,     // claim response window (clocks)
  parameter int HOLD_WIN  = 400,     // reset value of the token holding window
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
  // cpu port: write 0=TX FIFO push, 1=NS register, 2=data-DA register,
  // 3=ctrl {hold window (clocks) at [8 +: HW], claim_en at [0]};
  // cpu_re pops the RX FIFO (cpu_rdata = its head)
  input  logic        cpu_we,
  input  logic [1:0]  cpu_addr,
  input  logic [31:0] cpu_wdata,
  input  logic        cpu_re,
  output logic [31:0] cpu_rdata,
  output logic [3:0]  fifo_count,
  output logic [3:0]  rx_count,
  output logic        token_held,
  output logic        irq
);

  localparam int HW = $clog2(HOLD_WIN + 1);
  localparam int IW = $clog2(IDLE_TO + 1);
  localparam int CW = $clog2(CLAIM_WIN + 1);
  localparam int FW = $clog2(MAX_FR + 1);

  // frame control codes (the station sends claim / token / data)
  localparam logic [1:0] FC_CLAIM = 2'd0;
  localparam logic [1:0] FC_TOKEN = 2'd1;
  localparam logic [1:0] FC_DATA  = 2'd2;
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
  logic [7:0]    ns_reg;        // next-station address
  logic [7:0]    da_reg;        // data-frame destination
  logic          claim_en;
  logic [HW-1:0] hold_win;
  logic [31:0]   fifo [0:7];
  logic [2:0]    fifo_wr, fifo_rd;
  logic [3:0]    fifo_cnt;
  logic          fifo_pop;
  logic          cfg_irq;
  logic          push, pop, push_ok;

  assign fifo_count = fifo_cnt;
  assign push    = cpu_we && (cpu_addr == 2'd0);
  assign pop     = fifo_pop && (fifo_cnt != 0);
  assign push_ok = push && (fifo_cnt != 4'd8 || pop);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ns_reg   <= 8'h02;
      da_reg   <= 8'hFF;
      claim_en <= 1'b0;
      hold_win <= HW'(HOLD_WIN);
      fifo_wr  <= '0;
      fifo_rd  <= '0;
      fifo_cnt <= '0;
      cfg_irq  <= 1'b0;
    end else begin
      cfg_irq <= push && !push_ok;            // TX FIFO overflow write
      if (cpu_we && cpu_addr == 2'd1) ns_reg <= cpu_wdata[7:0];
      if (cpu_we && cpu_addr == 2'd2) da_reg <= cpu_wdata[7:0];
      if (cpu_we && cpu_addr == 2'd3) begin
        claim_en <= cpu_wdata[0];
        hold_win <= cpu_wdata[8 +: HW];
      end
      // FIFO push / pop (may happen in the same cycle)
      if (push_ok) begin
        fifo[fifo_wr] <= cpu_wdata;
        fifo_wr       <= fifo_wr + 3'd1;
      end
      if (pop) fifo_rd <= fifo_rd + 3'd1;
      fifo_cnt <= fifo_cnt + {3'd0, push_ok} - {3'd0, pop};
    end
  end

  // ------------------------------------------------------------------
  // RX engine: bit-serial hunt for 0x55 0xD5, then byte-aligned fields
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    R_HUNT, R_FC, R_DA, R_SA, R_LEN, R_PAY, R_CRCH, R_CRCL, R_ED
  } rstate_t;
  rstate_t     rstate;
  logic [14:0] sh16;   // last 15 bits while hunting
  logic [6:0]  sh8;    // bits of the byte being received
  logic [2:0]  bit_cnt;
  logic [15:0] rcrc;
  logic [7:0]  rfc, rda, rsa, rlen;
  logic [3:0]  rpay_cnt;
  logic [7:0]  rcrc_hi;
  logic        rx_done, rx_bad;
  logic        crc_ok;
  logic [31:0] rx_w [0:3];   // payload staging, big-endian words

  wire [7:0] rbyte = {sh8, rx_bit};   // completed byte

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate   <= R_HUNT;
      sh16     <= '1;
      sh8      <= '1;
      bit_cnt  <= '0;
      rcrc     <= 16'hFFFF;
      rfc      <= '0; rda <= '0; rsa <= '0; rlen <= '0;
      rpay_cnt <= '0;
      rcrc_hi  <= '0;
      rx_done  <= 1'b0;
      rx_bad   <= 1'b0;
      crc_ok   <= 1'b0;
      for (int i = 0; i < 4; i++) rx_w[i] <= '0;
    end else begin
      rx_done <= 1'b0;
      rx_bad  <= 1'b0;
      case (rstate)
        R_HUNT: begin
          sh16 <= {sh16[13:0], rx_bit};
          if ({sh16, rx_bit} == {B_PRE, B_SD}) begin
            rstate  <= R_FC;
            bit_cnt <= '0;
            sh8     <= '0;
            for (int i = 0; i < 4; i++) rx_w[i] <= '0;
          end
        end
        default: begin
          sh8     <= rbyte[6:0];
          bit_cnt <= bit_cnt + 3'd1;
          if (bit_cnt == 3'd7) begin
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
                  sh16   <= '1;
                end else if (rbyte == 8'd0) begin
                  rstate <= R_CRCH;
                end else begin
                  rstate <= R_PAY;
                end
              end
              R_PAY: begin
                rcrc <= crc16_byte(rcrc, rbyte);
                rx_w[rpay_cnt[3:2]][{~rpay_cnt[1:0], 3'b000} +: 8] <= rbyte;
                rpay_cnt <= rpay_cnt + 4'd1;
                if (rpay_cnt == rlen[3:0] - 4'd1) rstate <= R_CRCH;
              end
              R_CRCH: begin
                rcrc_hi <= rbyte;
                rstate  <= R_CRCL;
              end
              R_CRCL: begin
                crc_ok <= (rcrc == {rcrc_hi, rbyte});
                rx_bad <= (rcrc != {rcrc_hi, rbyte});   // CRC error
                rstate <= R_ED;
              end
              default: begin                            // R_ED
                // bad end delimiter: drop; good frame from another station
                rx_bad  <= (rbyte != B_ED);
                rx_done <= (rbyte == B_ED) && crc_ok && (rsa != my_addr);
                rstate  <= R_HUNT;
                sh16    <= '1;
              end
            endcase
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // RX FIFO (8 x 32): deliver data frames for my_addr / broadcast
  // ------------------------------------------------------------------
  logic [31:0] rxf [0:7];
  logic [2:0]  rxf_wr, rxf_rd;
  logic [3:0]  rxf_cnt;
  logic [2:0]  dl_left;      // words of the received frame still to push
  logic [1:0]  dl_idx;
  logic        rx_ovf_irq;
  logic        rpush, rpop, rpush_ok;

  assign rx_count  = rxf_cnt;
  assign cpu_rdata = rxf[rxf_rd];
  assign rpush     = (dl_left != 0);
  assign rpop      = cpu_re && (rxf_cnt != 0);
  assign rpush_ok  = rpush && (rxf_cnt != 4'd8 || rpop);

  wire deliver = rx_done && (rfc == {6'd0, FC_DATA}) &&
                 (rda == my_addr || rda == 8'hFF);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxf_wr     <= '0;
      rxf_rd     <= '0;
      rxf_cnt    <= '0;
      dl_left    <= '0;
      dl_idx     <= '0;
      rx_ovf_irq <= 1'b0;
    end else begin
      rx_ovf_irq <= rpush && !rpush_ok;       // word dropped: RX FIFO full
      if (deliver) begin
        dl_left <= 3'((rlen[4:0] + 5'd3) >> 2);
        dl_idx  <= '0;
      end else if (rpush) begin
        dl_left <= dl_left - 3'd1;
        dl_idx  <= dl_idx + 2'd1;
      end
      if (rpush_ok) begin
        rxf[rxf_wr] <= rx_w[dl_idx];
        rxf_wr      <= rxf_wr + 3'd1;
      end
      if (rpop) rxf_rd <= rxf_rd + 3'd1;
      rxf_cnt <= rxf_cnt + {3'd0, rpush_ok} - {3'd0, rpop};
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
  logic [1:0]  tfc;
  logic [7:0]  tda;
  logic [31:0] tword;
  logic [1:0]  tpay_cnt;
  logic        tx_start;
  logic [1:0]  tx_fc_in;
  logic [7:0]  tx_da_in;
  logic [31:0] tx_word_in;
  logic        tx_busy, tx_done;

  logic [15:0] tcrc_next;
  always_comb tcrc_next = crc16_byte(tcrc, tcur);

  // payload byte selector (big-endian word on the wire)
  function automatic logic [7:0] pay_byte(input logic [31:0] w,
                                          input logic [1:0]  i);
    pay_byte = w[{~i, 3'b000} +: 8];
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
        tbit   <= tbit + 3'd1;
        if (tbit == 3'd7) begin
          case (tstate)
            T_PRE1: begin tstate <= T_PRE2; tsh <= B_PRE; tcur <= B_PRE; end
            T_PRE2: begin tstate <= T_SD;   tsh <= B_SD;  tcur <= B_SD;  end
            T_SD: begin
              tstate <= T_FC; tsh <= {6'd0, tfc}; tcur <= {6'd0, tfc};
            end
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
              tsh    <= {5'd0, tfc == FC_DATA, 2'd0};   // LEN 4 or 0
              tcur   <= {5'd0, tfc == FC_DATA, 2'd0};
              tcrc   <= tcrc_next;               // crc over SA
            end
            T_LEN: begin
              tcrc   <= tcrc_next;               // crc over LEN
              if (tfc == FC_DATA) begin
                tstate   <= T_PAY;
                tsh      <= pay_byte(tword, 2'd0);
                tcur     <= pay_byte(tword, 2'd0);
              end else begin
                tstate <= T_CRCH;
                tsh    <= tcrc_next[15:8];
              end
            end
            T_PAY: begin
              tcrc     <= tcrc_next;             // crc over payload
              tpay_cnt <= tpay_cnt + 2'd1;
              if (tpay_cnt == 2'd3) begin
                tstate <= T_CRCH;
                tsh    <= tcrc_next[15:8];
              end else begin
                tsh  <= pay_byte(tword, tpay_cnt + 2'd1);
                tcur <= pay_byte(tword, tpay_cnt + 2'd1);
              end
            end
            T_CRCH: begin tstate <= T_CRCL; tsh <= tcrc[7:0]; end
            T_CRCL: begin tstate <= T_ED;   tsh <= B_ED;      end
            default: begin                       // T_ED
              tstate  <= T_IDLE;
              tx_done <= 1'b1;
            end
          endcase
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
  sstate_t       sstate;
  logic [IW-1:0] idle_cnt;
  logic [HW-1:0] hold_cnt;
  logic [FW-1:0] fr_sent;
  logic [CW-1:0] claim_cnt;
  logic          tok_irq;

  assign token_held = (sstate == ST_HOLD) || (sstate == ST_PASS);

  wire tok_for_me = rx_done && (rfc == {6'd0, FC_TOKEN}) && (rda == my_addr);

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

      // bus idle timer (saturates at IDLE_TO)
      if (!rx_bit) idle_cnt <= '0;
      else if (idle_cnt != IW'(IDLE_TO)) idle_cnt <= idle_cnt + 1'b1;

      case (sstate)
        ST_LISTEN: begin
          if (tok_for_me) begin
            sstate   <= ST_HOLD;
            hold_cnt <= '0;
            fr_sent  <= '0;
            tok_irq  <= 1'b1;               // token acquired
          end else if (claim_en && idle_cnt == IW'(IDLE_TO)) begin
            // bus silent: contend for the token
            tx_start  <= 1'b1;
            tx_fc_in  <= FC_CLAIM;
            tx_da_in  <= 8'hFF;
            tx_word_in<= 32'h0;
            sstate    <= ST_CLAIM_TX;
          end
        end

        ST_HOLD: begin
          if (hold_cnt < hold_win) hold_cnt <= hold_cnt + 1'b1;   // stops at the window
          if (!tx_busy && !tx_start) begin
            if (fr_sent != FW'(MAX_FR) && hold_cnt < hold_win &&
                fifo_cnt != 0) begin
              // transmit queued data frame (4-byte payload)
              tx_start   <= 1'b1;
              tx_fc_in   <= FC_DATA;
              tx_da_in   <= da_reg;
              tx_word_in <= fifo[fifo_rd];
              fifo_pop   <= 1'b1;
              fr_sent    <= fr_sent + 1'b1;
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

        default: begin                      // ST_CLAIM_WAIT
          claim_cnt <= claim_cnt + 1'b1;
          if (tok_for_me || (!rx_done && claim_cnt == CW'(CLAIM_WIN))) begin
            // passed the token, or no contender: we hold the token
            sstate   <= ST_HOLD;
            hold_cnt <= '0;
            fr_sent  <= '0;
            tok_irq  <= 1'b1;
          end else if (rx_done && !(rfc == {6'd0, FC_CLAIM} && rsa > my_addr)) begin
            // a lower-address claim wins, other traffic: back off
            sstate <= ST_LISTEN;
          end
          // a claim from a higher address is ignored
        end
      endcase
    end
  end

  // irq: bad frame (CRC/ED/len), FIFO overflows, token acquired; 1-clk pulse
  always_comb irq = rx_bad | cfg_irq | rx_ovf_irq | tok_irq;

  wire _unused = &{1'b0, cpu_wdata[31:8 + HW], rlen[7:5]};

endmodule
