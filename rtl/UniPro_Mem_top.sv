// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI UniPro-Mem -- UniPro 1.x data-link layer (educational slice) with a
// memory-mapped transaction-layer service.
//   * 8-bit symbol serial link, ESC_DL escape (8'h9D) + COF (8'hC0) framing
//   * L2 frame: hdr{tc,cport[3:0]}{seq[3:0]}{len[7:0]} payload(<=16B) CRC16(0x1021)
//   * CPort1 memory transactions: write/read of a 64x32 memory; a queued read
//     response that cannot start transmission within 100 clk is replaced by an
//     error frame (read timeout)
//   * PACP-style attribute get/set (16x8 regs) on CPort 0xF
//   * Outgoing data frames carry seq numbers; NAC triggers retransmit (<=3,
//     then irq). QoS: TC1 strict priority over TC0. irq: CRC error /
//     out-of-bounds / NAC retransmit exhausted.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module UniPro_Mem_top #(
  parameter int DW = 32,   // memory word width
  parameter int AW = 32    // (framework) address width
)(
  input  logic       clk,
  input  logic       rst_n,
  // RX symbol stream (peer -> this endpoint)
  input  logic [7:0] rx_sym,
  input  logic       rx_valid,
  // TX symbol stream (this endpoint -> peer)
  output logic [7:0] tx_sym,
  output logic       tx_valid,
  input  logic       tx_ready,
  output logic       irq
);

  // ------------------------------------------------------------------
  // constants
  // ------------------------------------------------------------------
  localparam logic [7:0] SYM_ESC = 8'h9D;   // ESC_DL escape symbol (custom)
  localparam logic [7:0] SYM_COF = 8'hC0;   // COF frame delimiter  (custom)
  localparam logic [7:0] ESC_XOR = 8'h20;   // escaped byte = data ^ 8'h20

  localparam logic [3:0] CPORT_MEM  = 4'h1; // memory transaction CPort
  localparam logic [3:0] CPORT_PACP = 4'hF; // PACP / control CPort

  // transaction-layer opcodes (payload byte 0)
  localparam logic [7:0] OP_MEM_WR       = 8'h01;
  localparam logic [7:0] OP_MEM_RD       = 8'h02;
  localparam logic [7:0] OP_WR_ACK       = 8'h81;
  localparam logic [7:0] OP_RD_RSP       = 8'h82;
  localparam logic [7:0] OP_ERR          = 8'hE0;
  localparam logic [7:0] OP_PACP_GET     = 8'h10;
  localparam logic [7:0] OP_PACP_SET     = 8'h11;
  localparam logic [7:0] OP_PACP_GET_RSP = 8'h90;
  localparam logic [7:0] OP_PACP_SET_RSP = 8'h91;
  localparam logic [7:0] OP_NAC          = 8'h20;
  // error codes (payload byte 1 of OP_ERR frames)
  localparam logic [7:0] ERR_TIMEOUT = 8'h01;  // read response timed out
  localparam logic [7:0] ERR_OOB     = 8'h02;  // out-of-bounds / invalid
  localparam logic [7:0] ERR_BADOP   = 8'h03;  // unknown opcode / cport

  // ------------------------------------------------------------------
  // CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, MSB first)
  // ------------------------------------------------------------------
  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  d);
    logic [15:0] c;
    begin
      c = crc ^ {d, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_byte = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // storage
  // ------------------------------------------------------------------
  logic [31:0] mem  [0:63];   // 64x32 memory-mapped service storage
  logic [7:0]  attr [0:15];   // 16x8 CPort attribute registers

  // TX frame queues, one slot per traffic class
  logic        q0_valid, q1_valid;
  logic [3:0]  q0_cport, q1_cport;
  logic [3:0]  q0_seq,   q1_seq;
  logic [7:0]  q0_len,   q1_len;
  logic        q0_rd,    q1_rd;     // queued frame is a read response
  logic [7:0]  q0_timer, q1_timer;  // read-response timeout (100 clk)
  logic [7:0]  q0_pay [0:15];
  logic [7:0]  q1_pay [0:15];

  // retransmit buffer (last transmitted seq-bearing frame)
  logic        rb_valid, rb_pend;
  logic        rb_tc;
  logic [3:0]  rb_cport, rb_seq;
  logic [7:0]  rb_len;
  logic [1:0]  rb_retry;
  logic [7:0]  rb_pay [0:15];

  logic [3:0]  tx_seq;              // outgoing frame sequence counter

  // ------------------------------------------------------------------
  // RX engine
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {R_IDLE, R_ESC0, R_FRAME, R_DISCARD} rstate_t;
  rstate_t   rxs;
  logic      e_flag;                 // ESC seen inside frame / discard
  logic [4:0] bcnt;                  // byte count within frame
  logic       r_tc;
  logic [3:0] r_cport, r_seq;
  logic [7:0] r_len;
  logic [7:0] rx_pay [0:15];
  logic [15:0] r_crc;
  logic        match_hi;

  wire [7:0] rbyte = e_flag ? (rx_sym ^ ESC_XOR) : rx_sym;
  wire [5:0] waddr0 = rx_pay[2][7:2];   // word address of mem transaction

  // ------------------------------------------------------------------
  // TX engine
  // ------------------------------------------------------------------
  typedef enum logic [0:0] {T_IDLE, T_RUN} tstate_t;
  tstate_t   txs;
  logic        t_tc;
  logic [3:0]  t_cport, t_seq;
  logic [7:0]  t_len;
  logic [7:0]  t_pay [0:15];
  logic [15:0] t_crc;
  logic [4:0]  t_cnt;
  logic        t_esc, t_escd;

  wire       tx_idle = (txs == T_IDLE);
  wire       ld_retx = tx_idle && rb_pend;
  wire       ld_tc1  = tx_idle && !rb_pend && q1_valid;
  wire       ld_tc0  = tx_idle && !rb_pend && !q1_valid && q0_valid;
  wire       ld_any  = ld_retx || ld_tc1 || ld_tc0;

  wire [4:0] total = 5'd3 + t_len[4:0];   // header+payload byte count

  // byte at stream position idx: 0=ESC, 1=COF, 2.. = header/payload, then CRC
  function automatic logic [7:0] byte_at(input logic [4:0] idx);
    logic [4:0] di;
    begin
      di = idx - 5'd2;
      if (idx == 5'd0)           byte_at = SYM_ESC;
      else if (idx == 5'd1)      byte_at = SYM_COF;
      else if (idx <= total + 5'd1) begin
        if (di == 5'd0)      byte_at = {3'b000, t_tc, t_cport};
        else if (di == 5'd1) byte_at = {4'h0, t_seq};
        else if (di == 5'd2) byte_at = t_len;
        else                 byte_at = t_pay[di - 5'd3];
      end
      else if (idx == total + 5'd2) byte_at = t_crc[15:8];
      else                          byte_at = t_crc[7:0];
    end
  endfunction

  wire [7:0]  cur_d   = byte_at(t_cnt);          // byte being transmitted
  wire [7:0]  nxt_d   = byte_at(t_cnt + 5'd1);   // byte queued next
  wire [15:0] crc_n   = crc16_byte(t_crc, cur_d);
  // when the byte just consumed was the last payload byte, the CRC register
  // has not been updated yet: take the fresh CRC for the CRC-hi symbol
  wire [7:0]  nbyte   = (t_cnt == total + 5'd1) ? crc_n[15:8] : nxt_d;
  wire        esc_nxt = (nbyte == SYM_ESC) || (nbyte == SYM_COF);

  // ------------------------------------------------------------------
  // enqueue helper: push a response frame into a TC queue
  // ------------------------------------------------------------------
  task automatic enq_rsp(input logic        tc,
                         input logic [3:0]  cport,
                         input logic [7:0]  plen,
                         input logic [127:0] pay,
                         input logic        is_rd);
    begin
      if (tc) begin
        if (!q1_valid || ld_tc1) begin
          q1_valid <= 1'b1;
          q1_cport <= cport;
          q1_seq   <= tx_seq;
          q1_len   <= plen;
          q1_rd    <= is_rd;
          q1_timer <= 8'd100;
          for (int i = 0; i < 16; i++) q1_pay[i] <= pay[127-8*i -: 8];
          tx_seq   <= tx_seq + 4'd1;
        end
      end else begin
        if (!q0_valid || ld_tc0) begin
          q0_valid <= 1'b1;
          q0_cport <= cport;
          q0_seq   <= tx_seq;
          q0_len   <= plen;
          q0_rd    <= is_rd;
          q0_timer <= 8'd100;
          for (int i = 0; i < 16; i++) q0_pay[i] <= pay[127-8*i -: 8];
          tx_seq   <= tx_seq + 4'd1;
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // sequential logic (single clocked process)
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxs <= R_IDLE;  e_flag <= 1'b0; bcnt <= 5'd0;
      r_tc <= 1'b0; r_cport <= 4'h0; r_seq <= 4'h0; r_len <= 8'h0;
      r_crc <= 16'hFFFF; match_hi <= 1'b0;
      for (int i = 0; i < 16; i++) rx_pay[i] <= 8'h00;
      txs <= T_IDLE; t_tc <= 1'b0; t_cport <= 4'h0; t_seq <= 4'h0;
      t_len <= 8'h0; t_crc <= 16'hFFFF; t_cnt <= 5'd0;
      t_esc <= 1'b0; t_escd <= 1'b0;
      for (int i = 0; i < 16; i++) t_pay[i] <= 8'h00;
      tx_sym <= 8'h00; tx_valid <= 1'b0;
      q0_valid <= 1'b0; q1_valid <= 1'b0;
      q0_cport <= 4'h0; q1_cport <= 4'h0;
      q0_seq <= 4'h0;   q1_seq <= 4'h0;
      q0_len <= 8'h0;   q1_len <= 8'h0;
      q0_rd <= 1'b0;    q1_rd <= 1'b0;
      q0_timer <= 8'h0; q1_timer <= 8'h0;
      for (int i = 0; i < 16; i++) begin q0_pay[i] <= 8'h00; q1_pay[i] <= 8'h00; end
      rb_valid <= 1'b0; rb_pend <= 1'b0; rb_tc <= 1'b0;
      rb_cport <= 4'h0; rb_seq <= 4'h0; rb_len <= 8'h0; rb_retry <= 2'd0;
      for (int i = 0; i < 16; i++) rb_pay[i] <= 8'h00;
      tx_seq <= 4'h0;
      for (int i = 0; i < 64; i++) mem[i]  <= 32'h0;
      for (int i = 0; i < 16; i++) attr[i] <= 8'h0;
      irq <= 1'b0;
    end else begin
      irq <= 1'b0;   // irq is a one-cycle event pulse

      // ---------------- TX engine ----------------
      case (txs)
        T_IDLE: if (ld_any) begin
          if (ld_retx) begin
            t_tc <= rb_tc; t_cport <= rb_cport; t_seq <= rb_seq; t_len <= rb_len;
            for (int i = 0; i < 16; i++) t_pay[i] <= rb_pay[i];
            rb_pend <= 1'b0;
          end else if (ld_tc1) begin
            t_tc <= 1'b1; t_cport <= q1_cport; t_seq <= q1_seq; t_len <= q1_len;
            for (int i = 0; i < 16; i++) t_pay[i] <= q1_pay[i];
            q1_valid <= 1'b0;
            // keep a copy for possible NAC retransmission
            rb_valid <= 1'b1; rb_tc <= 1'b1; rb_cport <= q1_cport;
            rb_seq <= q1_seq; rb_len <= q1_len; rb_retry <= 2'd0;
            for (int i = 0; i < 16; i++) rb_pay[i] <= q1_pay[i];
          end else begin
            t_tc <= 1'b0; t_cport <= q0_cport; t_seq <= q0_seq; t_len <= q0_len;
            for (int i = 0; i < 16; i++) t_pay[i] <= q0_pay[i];
            q0_valid <= 1'b0;
            rb_valid <= 1'b1; rb_tc <= 1'b0; rb_cport <= q0_cport;
            rb_seq <= q0_seq; rb_len <= q0_len; rb_retry <= 2'd0;
            for (int i = 0; i < 16; i++) rb_pay[i] <= q0_pay[i];
          end
          t_crc <= 16'hFFFF; t_cnt <= 5'd0; t_esc <= 1'b0; t_escd <= 1'b0;
          tx_sym <= SYM_ESC; tx_valid <= 1'b1;   // first symbol on the wire
          txs <= T_RUN;
        end
        T_RUN: if (tx_valid && tx_ready) begin
          if (t_esc) begin
            // ESC consumed: send the escaped data byte, byte not yet complete
            tx_sym <= cur_d ^ ESC_XOR;
            t_esc  <= 1'b0;
            t_escd <= 1'b1;
          end else begin
            // current byte (plain or escaped-data) consumed: byte complete
            t_escd <= 1'b0;
            if ((t_cnt >= 5'd2) && (t_cnt <= total + 5'd1))
              t_crc <= crc_n;                    // CRC over header+payload
            if (t_cnt == total + 5'd3) begin
              txs      <= T_IDLE;                // frame complete
              tx_valid <= 1'b0;
            end else begin
              t_cnt <= t_cnt + 5'd1;
              if ((t_cnt >= 5'd1) && esc_nxt) begin
                tx_sym <= SYM_ESC;               // escape next data byte
                t_esc  <= 1'b1;
              end else tx_sym <= nbyte;
            end
          end
        end
        default: txs <= T_IDLE;
      endcase

      // ---------------- read-response timeout (100 clk) ----------------
      if (q0_valid && q0_rd && !ld_tc0) begin
        if (q0_timer == 8'd1) begin
          q0_len    <= 8'd2;
          q0_pay[0] <= OP_ERR;
          q0_pay[1] <= ERR_TIMEOUT;
          q0_rd     <= 1'b0;
        end else q0_timer <= q0_timer - 8'd1;
      end
      if (q1_valid && q1_rd && !ld_tc1) begin
        if (q1_timer == 8'd1) begin
          q1_len    <= 8'd2;
          q1_pay[0] <= OP_ERR;
          q1_pay[1] <= ERR_TIMEOUT;
          q1_rd     <= 1'b0;
        end else q1_timer <= q1_timer - 8'd1;
      end

      // ---------------- RX engine ----------------
      case (rxs)
        R_IDLE: if (rx_valid && (rx_sym == SYM_ESC)) rxs <= R_ESC0;
        R_ESC0: if (rx_valid) begin
          if (rx_sym == SYM_COF) begin
            rxs <= R_FRAME; bcnt <= 5'd0; r_crc <= 16'hFFFF;
            e_flag <= 1'b0; match_hi <= 1'b0;
          end else if (rx_sym != SYM_ESC) rxs <= R_IDLE;
        end
        R_DISCARD: if (rx_valid) begin
          if (!e_flag && (rx_sym == SYM_ESC)) e_flag <= 1'b1;
          else if (e_flag && (rx_sym == SYM_COF)) begin
            rxs <= R_FRAME; bcnt <= 5'd0; r_crc <= 16'hFFFF;
            e_flag <= 1'b0; match_hi <= 1'b0;
          end else e_flag <= 1'b0;
        end
        R_FRAME: if (rx_valid) begin
          if (!e_flag && (rx_sym == SYM_ESC)) e_flag <= 1'b1;
          else if (e_flag && (rx_sym == SYM_COF)) begin
            // COF restarts framing: abort current frame, start a new one
            bcnt <= 5'd0; r_crc <= 16'hFFFF; e_flag <= 1'b0; match_hi <= 1'b0;
          end else begin
            e_flag <= 1'b0;
            if (bcnt == 5'd0) begin
              r_tc    <= rbyte[4];
              r_cport <= rbyte[3:0];
            end else if (bcnt == 5'd1) begin
              r_seq <= rbyte[3:0];
            end else if (bcnt == 5'd2) begin
              r_len <= rbyte;
              if (rbyte > 8'd16) rxs <= R_DISCARD;   // oversized: drop frame
            end else if (bcnt < (5'd3 + {1'b0, r_len})) begin
              if ((bcnt - 5'd3) < 5'd16) rx_pay[bcnt - 5'd3] <= rbyte;
            end else if (bcnt == (5'd3 + {1'b0, r_len})) begin
              match_hi <= (rbyte == r_crc[15:8]);
            end else begin
              // last CRC byte: frame complete
              rxs <= R_IDLE;
              if (!match_hi || (rbyte != r_crc[7:0])) begin
                irq <= 1'b1;                       // CRC error
              end else begin
                // ---------------- dispatch ----------------
                case (r_cport)
                  CPORT_MEM: begin
                    if (r_len >= 8'd4) begin
                      case (rx_pay[0])
                        OP_MEM_WR: begin
                          if (((rx_pay[3] == 8'd4) || (rx_pay[3] == 8'd8) ||
                               (rx_pay[3] == 8'd12)) &&
                              (rx_pay[1] == 8'h00) && (rx_pay[2][1:0] == 2'b00) &&
                              ({2'b00, rx_pay[2]} + {2'b00, rx_pay[3]} <= 10'd256) &&
                              (r_len == (rx_pay[3] + 8'd4))) begin
                            for (int i = 0; i < 3; i++)
                              if (i < (rx_pay[3] >> 2))
                                mem[waddr0 + i] <= {rx_pay[4*i+4], rx_pay[4*i+5],
                                                    rx_pay[4*i+6], rx_pay[4*i+7]};
                            enq_rsp(r_tc, CPORT_MEM, 8'd5,
                                    {OP_WR_ACK, rx_pay[1], rx_pay[2], rx_pay[3],
                                     8'h00, 88'h0}, 1'b0);
                          end else begin
                            irq <= 1'b1;             // out-of-bounds write
                            enq_rsp(r_tc, CPORT_MEM, 8'd2,
                                    {OP_ERR, ERR_OOB, 112'h0}, 1'b0);
                          end
                        end
                        OP_MEM_RD: begin
                          if (((rx_pay[3] == 8'd4) || (rx_pay[3] == 8'd8) ||
                               (rx_pay[3] == 8'd12)) &&
                              (rx_pay[1] == 8'h00) && (rx_pay[2][1:0] == 2'b00) &&
                              ({2'b00, rx_pay[2]} + {2'b00, rx_pay[3]} <= 10'd256) &&
                              (r_len == 8'd4)) begin
                            enq_rsp(r_tc, CPORT_MEM, rx_pay[3] + 8'd4,
                                    {OP_RD_RSP, rx_pay[1], rx_pay[2], rx_pay[3],
                                     mem[waddr0], mem[waddr0 + 6'd1],
                                     mem[waddr0 + 6'd2]}, 1'b1);
                          end else begin
                            irq <= 1'b1;             // out-of-bounds read
                            enq_rsp(r_tc, CPORT_MEM, 8'd2,
                                    {OP_ERR, ERR_OOB, 112'h0}, 1'b0);
                          end
                        end
                        default: enq_rsp(r_tc, CPORT_MEM, 8'd2,
                                         {OP_ERR, ERR_BADOP, 112'h0}, 1'b0);
                      endcase
                    end else begin
                      enq_rsp(r_tc, CPORT_MEM, 8'd2,
                              {OP_ERR, ERR_BADOP, 112'h0}, 1'b0);
                    end
                  end
                  CPORT_PACP: begin
                    case (rx_pay[0])
                      OP_PACP_GET: begin
                        if ((r_len >= 8'd2) && (rx_pay[1] < 8'd16))
                          enq_rsp(r_tc, CPORT_PACP, 8'd3,
                                  {OP_PACP_GET_RSP, rx_pay[1],
                                   attr[rx_pay[1][3:0]], 104'h0}, 1'b0);
                        else begin
                          if (rx_pay[1] >= 8'd16) irq <= 1'b1;  // attr OOB
                          enq_rsp(r_tc, CPORT_PACP, 8'd2,
                                  {OP_ERR, (rx_pay[1] >= 8'd16) ? ERR_OOB : ERR_BADOP,
                                   112'h0}, 1'b0);
                        end
                      end
                      OP_PACP_SET: begin
                        if ((r_len >= 8'd3) && (rx_pay[1] < 8'd16)) begin
                          attr[rx_pay[1][3:0]] <= rx_pay[2];
                          enq_rsp(r_tc, CPORT_PACP, 8'd3,
                                  {OP_PACP_SET_RSP, rx_pay[1], rx_pay[2], 104'h0},
                                  1'b0);
                        end else begin
                          if (rx_pay[1] >= 8'd16) irq <= 1'b1;  // attr OOB
                          enq_rsp(r_tc, CPORT_PACP, 8'd2,
                                  {OP_ERR, (rx_pay[1] >= 8'd16) ? ERR_OOB : ERR_BADOP,
                                   112'h0}, 1'b0);
                        end
                      end
                      OP_NAC: begin
                        // retransmit last outgoing frame with matching seq
                        if (rb_valid && (rb_seq == rx_pay[1][3:0])) begin
                          if (rb_retry == 2'd3) begin
                            rb_valid <= 1'b0;
                            irq      <= 1'b1;        // retransmit exhausted
                          end else begin
                            rb_pend  <= 1'b1;
                            rb_retry <= rb_retry + 2'd1;
                          end
                        end
                      end
                      default: enq_rsp(r_tc, CPORT_PACP, 8'd2,
                                       {OP_ERR, ERR_BADOP, 112'h0}, 1'b0);
                    endcase
                  end
                  default: enq_rsp(r_tc, r_cport, 8'd2,
                                   {OP_ERR, ERR_BADOP, 112'h0}, 1'b0);
                endcase
              end
            end
            // CRC covers header + payload bytes only
            if ((bcnt <= 5'd2) || (bcnt < (5'd3 + {1'b0, r_len})))
              r_crc <= crc16_byte(r_crc, rbyte);
            bcnt <= bcnt + 5'd1;
          end
        end
        default: rxs <= R_IDLE;
      endcase
    end
  end

endmodule
