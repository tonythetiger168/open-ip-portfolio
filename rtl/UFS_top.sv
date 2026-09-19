// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UFS protocol Open IP -- UFS host: simplified UniPro frame link + UPIU
// command transactions (TEST UNIT READY / READ10 / WRITE10 on a serial lane)
// Open IP design implementation v2.4
// -- Apache-2.0
// ============================================================================
// Simplifications (per SPEC.md section 2.4):
//  * refclk is kept for interface compatibility only; the lane symbol clock is
//    derived from clk (1 bit per clk, MSB-first within each 32-bit dword).
//  * Frame : SOF(32'h5546_5301) HDR PAYLOAD(len <= 8 dwords) CRC32 EOF(32'h5546_5302)
//    HDR   : {type[7:0], task_tag[7:0], lun[7:0], len[7:0]}
//    CRC32 : poly 32'h04C11DB7 (reflected shift form 32'hEDB8_8320), init
//            all-ones, final XOR all-ones; computed over the on-the-wire bit
//            stream of HDR+PAYLOAD and transmitted as one dword MSB-first.
//  * COMMAND UPIU (type 8'h01): payload[0..3] = 16-byte CDB
//      dword0 = {opcode[7:0], lba[23:0]}, dword1 = {xfer_dwords[7:0], 24'h0}
//      WRITE10 data is carried inline in payload[4..7] (count = len-4 dwords)
//  * RESPONSE UPIU (type 8'h81): payload[0] = {sense[15:0], status[15:0]}
//      READ10 data follows in a DATA UPIU (type 8'h02)
//  * LUN0 medium: internal 256 x 32-bit storage array.
//  * irq pulses one clk on: CRC mismatch, unknown opcode, len > 8, bad EOF,
//    malformed CDB or out-of-range LBA/transfer length.
// ============================================================================
module UFS_top #(
  parameter int DW = 32,       // data width (port contract, unused internally)
  parameter int AW = 32,       // address width (port contract, unused internally)
  parameter int BIT_CLKS = 1   // clk cycles per serial bit (bit-rate divider)
)(
  input  logic clk,
  input  logic rst_n,
  output logic tx_n,
  output logic tx_p,
  input  logic rx_n,           // differential complement (loopback contract)
  input  logic rx_p,
  input  logic refclk,         // kept for contract; lane clock is clk (header note)
  output logic irq
);
  // ------------------------------ constants ------------------------------
  localparam logic [31:0] SOF   = 32'h5546_5301;  // "UFS" start-of-frame mark
  localparam logic [31:0] EOFR  = 32'h5546_5302;  // end-of-frame mark
  localparam logic [31:0] TRAIN = 32'hBC3C_5A5A;  // link training dword

  // LP_WAIT_RSP retrain timeout: waits for a peer burst at the divided bit
  // rate, so it scales with BIT_CLKS.  BIT_CLKS=1 keeps the legacy value
  // 4095 and 12-bit counter width.  The LP_PWR_ON settle delay below stays
  // a raw-clk wall-clock delay and is intentionally not scaled.
  localparam int TR_TMO = 4095 * BIT_CLKS;
  localparam int TRW    = 12 + ((BIT_CLKS > 1) ? $clog2(BIT_CLKS) : 0);

  localparam logic [7:0] T_CMD  = 8'h01;          // COMMAND UPIU
  localparam logic [7:0] T_DATA = 8'h02;          // DATA UPIU
  localparam logic [7:0] T_RESP = 8'h81;          // RESPONSE UPIU

  localparam logic [7:0] OP_TUR = 8'h00;          // TEST UNIT READY
  localparam logic [7:0] OP_R10 = 8'h28;          // READ10
  localparam logic [7:0] OP_W10 = 8'h2A;          // WRITE10

  localparam logic [15:0] ST_GOOD    = 16'h0000;
  localparam logic [15:0] ST_CHECK   = 16'h0001;  // CHECK CONDITION
  localparam logic [15:0] SENSE_NONE = 16'h0000;
  localparam logic [15:0] SENSE_ILL  = 16'h0005;  // ILLEGAL REQUEST

  // ---------------- CRC32: poly 04C11DB7, reflected, 1 bit/step ----------------
  function automatic logic [31:0] crc_step(input logic [31:0] c, input logic b);
    logic fb;
    begin
      fb       = c[0] ^ b;
      crc_step = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0000_0000);
    end
  endfunction

  // ------------------------ link training FSM ------------------------
  // Bit-rate divider: per-bit shift/sample logic advances only on bit_tick.
  // BIT_CLKS=1 keeps the legacy 1-bit-per-clk behavior (bit_tick constant 1).
  localparam int BCW = (BIT_CLKS <= 1) ? 1 : $clog2(BIT_CLKS);
  logic [BCW-1:0] bd_cnt;
  wire bit_tick = (BIT_CLKS <= 1) || (bd_cnt == BIT_CLKS-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          bd_cnt <= '0;
    else if (bit_tick)   bd_cnt <= '0;
    else                 bd_cnt <= bd_cnt + 1'b1;
  end

  typedef enum logic [1:0] {LP_PWR_ON, LP_TX_TRAIN, LP_WAIT_RSP, LP_LINKUP} lp_e;
  lp_e        lp_state;
  logic [4:0]  tr_bit;    // bit counter inside one training dword
  logic [3:0]  tr_rep;    // training dword repetition counter
  logic [31:0] tr_shift;  // rx shift register for training detection
  logic [4:0]  tr_gap;    // countdown to the expected 2nd training dword
  logic        tr_arm;    // first training dword seen
  logic [TRW-1:0] tr_timer;  // power-on delay / wait-response timeout
  logic        link_up;

  assign link_up = (lp_state == LP_LINKUP);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lp_state <= LP_PWR_ON;
      tr_bit <= '0; tr_rep <= '0; tr_shift <= '0;
      tr_gap <= '0; tr_arm <= 1'b0; tr_timer <= '0;
    end else case (lp_state)
      LP_PWR_ON: begin                       // settle, then start training
        // raw-clk wall-clock settle delay, intentionally not scaled
        if (tr_timer == 15) begin
          lp_state <= LP_TX_TRAIN; tr_timer <= '0; tr_bit <= '0; tr_rep <= '0;
        end else tr_timer <= tr_timer + 1'b1;
      end
      LP_TX_TRAIN: begin                     // burst: TRAIN dword x 8
        if (bit_tick) begin
        if (tr_bit == 5'd31) begin
          tr_bit <= '0;
          if (tr_rep == 4'd7) begin
            lp_state <= LP_WAIT_RSP; tr_timer <= '0; tr_arm <= 1'b0;
          end else tr_rep <= tr_rep + 1'b1;
        end else tr_bit <= tr_bit + 1'b1;
        end // bit_tick
      end
      LP_WAIT_RSP: begin                     // detect peer training response
        if (bit_tick) begin
        tr_shift <= {tr_shift[30:0], rx_p};
        if (!tr_arm) begin                   // sliding-window search, 1st dword
          if ({tr_shift[30:0], rx_p} == TRAIN) begin
            tr_arm <= 1'b1; tr_gap <= '0;
          end
        end else if (tr_gap == 5'd31) begin  // aligned check, 2nd dword
          tr_arm <= 1'b0;
          if ({tr_shift[30:0], rx_p} == TRAIN) lp_state <= LP_LINKUP;
        end else tr_gap <= tr_gap + 1'b1;
        end // bit_tick
        if (tr_timer == TR_TMO[TRW-1:0]) begin  // no response: retrain
          lp_state <= LP_TX_TRAIN; tr_bit <= '0; tr_rep <= '0;
          tr_timer <= '0; tr_arm <= 1'b0;
        end else tr_timer <= tr_timer + 1'b1;
      end
      LP_LINKUP: ;                           // link steady state
      default:   lp_state <= LP_PWR_ON;
    endcase
  end

  // ------------------ RX / dispatcher / storage / TX ------------------
  typedef enum logic [2:0] {RX_SOF, RX_HDR, RX_PAY, RX_CRC, RX_EOF} rx_e;
  typedef enum logic [0:0] {TX_IDLE, TX_RUN} tx_e;

  rx_e rx_state;
  tx_e tx_state;
  logic [4:0]  rx_bit;
  logic [31:0] rx_shift;
  logic [3:0]  rx_cnt;
  logic [7:0]  hdr_type, hdr_tt, hdr_lun, hdr_len;
  logic [31:0] pay_buf [0:7];
  logic [31:0] crc_rx;

  (* ram_style = "block" *) logic [31:0] storage [0:255];   // LUN0 medium

  logic [31:0] tx_buf [0:11];                // SOF,HDR,pay0..7,(live CRC),EOF
  logic [3:0]  tx_total, tx_idx;
  logic [4:0]  tx_bit;
  logic [31:0] crc_tx;
  logic        tx_ser, tx_req;
  logic        rd_pend;                      // DATA UPIU owed after RESPONSE
  logic [7:0]  rd_lba;
  logic [3:0]  rd_n;

  // combinational temporaries (blocking-assigned inside the clocked process)
  logic [31:0] rxw;                          // just-completed rx dword
  logic [31:0] txw;                          // dword currently being serialized
  logic [15:0] r_status, r_sense;
  logic        do_resp;
  logic [7:0]  n_xfer;
  logic        lba_ok;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state <= RX_SOF; rx_bit <= '0; rx_shift <= '0; rx_cnt <= '0;
      hdr_type <= '0; hdr_tt <= '0; hdr_lun <= '0; hdr_len <= '0;
      crc_rx <= '0; irq <= 1'b0;
      tx_state <= TX_IDLE; tx_idx <= '0; tx_bit <= '0; crc_tx <= '0;
      tx_ser <= 1'b1; tx_req <= 1'b0; tx_total <= '0;
      rd_pend <= 1'b0; rd_lba <= '0; rd_n <= '0;
    end else begin
      rxw = {rx_shift[30:0], rx_p};
      irq <= 1'b0;                                   // irq is a 1-clk pulse
      if (tx_req && (tx_state == TX_RUN)) tx_req <= 1'b0;

      // -------------------- RX frame decoder --------------------
      if (link_up && bit_tick) begin
        rx_shift <= rxw;
        if ((rx_state == RX_HDR) || (rx_state == RX_PAY))
          crc_rx <= crc_step(crc_rx, rx_p);
        case (rx_state)
          RX_SOF: begin                              // sliding-window SOF hunt
            rx_bit <= '0;
            if (rxw == SOF) begin
              rx_state <= RX_HDR;
              crc_rx   <= 32'hFFFF_FFFF;
            end
          end
          default: begin
            if (rx_bit == 5'd31) begin
              rx_bit <= '0;
              case (rx_state)
                RX_HDR: begin
                  hdr_type <= rxw[31:24]; hdr_tt <= rxw[23:16];
                  hdr_lun  <= rxw[15:8];  hdr_len <= rxw[7:0];
                  if (rxw[7:0] > 8'd8) begin         // len out of range: drop
                    irq <= 1'b1; rx_state <= RX_SOF;
                  end else if (rxw[7:0] == 8'd0) rx_state <= RX_CRC;
                  else begin rx_state <= RX_PAY; rx_cnt <= '0; end
                end
                RX_PAY: begin
                  pay_buf[rx_cnt] <= rxw;
                  if ({4'b0, rx_cnt} == (hdr_len - 8'd1)) rx_state <= RX_CRC;
                  else rx_cnt <= rx_cnt + 1'b1;
                end
                RX_CRC: begin
                  if (rxw != (crc_rx ^ 32'hFFFF_FFFF)) begin
                    irq <= 1'b1; rx_state <= RX_SOF; // CRC error: discard
                  end else rx_state <= RX_EOF;
                end
                RX_EOF: begin
                  rx_state <= RX_SOF;
                  if (rxw != EOFR) irq <= 1'b1;      // framing violation
                  else if (hdr_type == T_CMD) begin
                    // ---------- COMMAND UPIU dispatch ----------
                    r_status = ST_GOOD; r_sense = SENSE_NONE;
                    do_resp  = 1'b1;    n_xfer = 8'd0; lba_ok = 1'b0;
                    if (hdr_len < 8'd4) begin
                      irq <= 1'b1; do_resp = 1'b0;   // malformed CDB: drop
                    end else begin
                      case (pay_buf[0][31:24])
                        OP_TUR: ;                    // nothing to do -> GOOD
                        OP_W10: begin
                          n_xfer = hdr_len - 8'd4;   // inline data dword count
                          lba_ok = ({8'h0, pay_buf[0][23:0]} + {24'h0, n_xfer})
                                   <= 32'd256;
                          if ((hdr_len >= 8'd5) && lba_ok) begin
                            for (int i = 0; i < 4; i++)
                              if (i < n_xfer)
                                storage[pay_buf[0][7:0] + i] <= pay_buf[4+i];
                          end else begin
                            r_status = ST_CHECK; r_sense = SENSE_ILL; irq <= 1'b1;
                          end
                        end
                        OP_R10: begin
                          n_xfer = pay_buf[1][31:24];
                          lba_ok = ({8'h0, pay_buf[0][23:0]} + {24'h0, n_xfer})
                                   <= 32'd256;
                          if ((n_xfer >= 8'd1) && (n_xfer <= 8'd8) && lba_ok) begin
                            rd_pend <= 1'b1;
                            rd_lba  <= pay_buf[0][7:0];
                            rd_n    <= n_xfer[3:0];
                          end else begin
                            r_status = ST_CHECK; r_sense = SENSE_ILL; irq <= 1'b1;
                          end
                        end
                        default: begin               // unknown opcode
                          r_status = ST_CHECK; r_sense = SENSE_ILL; irq <= 1'b1;
                        end
                      endcase
                    end
                    if (do_resp) begin               // build RESPONSE UPIU
                      tx_buf[0] <= SOF;
                      tx_buf[1] <= {T_RESP, hdr_tt, hdr_lun, 8'd1};
                      tx_buf[2] <= {r_sense, r_status};
                      tx_buf[4] <= EOFR;             // dword3 = live CRC slot
                      tx_total  <= 4'd5;
                      tx_req    <= 1'b1;
                    end
                  end
                end
                default: rx_state <= RX_SOF;
              endcase
            end else rx_bit <= rx_bit + 1'b1;
          end
        endcase
      end

      // -------------------- TX frame serializer --------------------
      if (bit_tick) begin
      case (tx_state)
        TX_IDLE: begin
          tx_ser <= 1'b1;                            // line idle high
          if (tx_req) begin
            tx_state <= TX_RUN; tx_idx <= '0; tx_bit <= '0;
            crc_tx <= 32'hFFFF_FFFF;
          end
        end
        TX_RUN: begin
          if (tx_idx == (tx_total - 4'd2)) txw = crc_tx ^ 32'hFFFF_FFFF;
          else                             txw = tx_buf[tx_idx];
          tx_ser <= txw[5'd31 - tx_bit];
          if ((tx_idx >= 4'd1) && (tx_idx <= (tx_total - 4'd3)))
            crc_tx <= crc_step(crc_tx, txw[5'd31 - tx_bit]);
          if (tx_bit == 5'd31) begin
            tx_bit <= '0;
            if (tx_idx == (tx_total - 4'd1)) begin
              if (rd_pend) begin                     // chain DATA UPIU
                tx_buf[0] <= SOF;
                tx_buf[1] <= {T_DATA, hdr_tt, hdr_lun, 4'h0, rd_n};
                for (int i = 0; i < 8; i++)
                  if (i < rd_n)
                    tx_buf[2+i] <= storage[rd_lba + i];
                tx_buf[rd_n + 4'd3] <= EOFR;         // dword rd_n+2 = live CRC
                tx_total <= rd_n + 4'd4;
                tx_idx   <= '0;
                crc_tx   <= 32'hFFFF_FFFF;
                rd_pend  <= 1'b0;
              end else begin
                tx_state <= TX_IDLE;         // TX_IDLE drives line idle next clk
              end
            end else tx_idx <= tx_idx + 1'b1;
          end else tx_bit <= tx_bit + 1'b1;
        end
        default: tx_state <= TX_IDLE;
      endcase
      end // bit_tick
    end
  end

  // ------------------------ line driver mux ------------------------
  always_comb begin
    if (lp_state == LP_TX_TRAIN)    tx_p = TRAIN[5'd31 - tr_bit];
    else if (lp_state == LP_LINKUP) tx_p = tx_ser;
    else                            tx_p = 1'b1;     // line idle
  end
  assign tx_n = ~tx_p;

endmodule
