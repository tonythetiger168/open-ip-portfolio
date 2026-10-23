// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI UniPro-Mem -- UniPro 1.x data-link layer (educational slice) with a
// memory-mapped transaction-layer service.
//   * 8-bit symbol serial link, ESC_DL escape (8'h9D) + COF (8'hC0) framing;
//     a data byte equal to ESC or COF is sent as ESC, byte ^ 8'h20
//   * L2 frame: hdr{tc,cport[3:0]}{seq[3:0]}{len[7:0]} payload(<=16B) CRC16(0x1021)
//     (the sequence number of received frames is not checked)
//   * CPort1 memory transactions: write/read of a 64x32 memory; a queued read
//     response that cannot start transmission within 100 clk is replaced by an
//     error frame (read timeout)
//   * PACP-style attribute get/set (16x8 regs) on CPort 0xF
//   * Outgoing data frames carry seq numbers; NAC triggers retransmit (<=3,
//     then irq). QoS: TC1 strict priority over TC0. irq: CRC error /
//     out-of-bounds / NAC retransmit exhausted / response dropped because
//     its traffic-class queue slot is still occupied (TX back-pressure).
//   * Responses are queued as records (kind + fields) and serialized into
//     bytes by the TX engine.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module UniPro_Mem_top (
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
  localparam logic [1:0] ERR_TIMEOUT = 2'd1;   // read response timed out
  localparam logic [1:0] ERR_OOB     = 2'd2;   // out-of-bounds / invalid
  localparam logic [1:0] ERR_BADOP   = 2'd3;   // unknown opcode / cport

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
  // response records
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {K_WACK, K_RRSP, K_ERR, K_GET, K_SET} kind_t;
  typedef struct packed {
    kind_t       kind;
    logic [3:0]  cport;
    logic [3:0]  seq;
    logic [3:0]  a1;       // address high byte (mem: 0) / attribute index
    logic [7:0]  a2;       // byte address / attribute value / set data
    logic [1:0]  nw;       // memory words (1..3)
    logic [1:0]  ec;       // error code
    logic [95:0] data;     // read data, word 0 first
  } rsp_t;

  // payload length of a record
  function automatic logic [4:0] rsp_len(input kind_t kind, input logic [1:0] nw);
    case (kind)
      K_WACK:  rsp_len = 5'd5;
      K_RRSP:  rsp_len = 5'd4 + {1'b0, nw, 2'b00};
      K_ERR:   rsp_len = 5'd2;
      default: rsp_len = 5'd3;                     // K_GET / K_SET
    endcase
  endfunction

  // payload byte k of a record
  function automatic logic [7:0] rsp_byte(input kind_t kind, input logic [3:0] a1,
                                          input logic [7:0] a2, input logic [1:0] nw,
                                          input logic [1:0] ec, input logic [95:0] data,
                                          input logic [3:0] k);
    logic [7:0] op;
    case (kind)
      K_WACK:  op = OP_WR_ACK;
      K_RRSP:  op = OP_RD_RSP;
      K_ERR:   op = OP_ERR;
      K_GET:   op = OP_PACP_GET_RSP;
      default: op = OP_PACP_SET_RSP;
    endcase
    case (k)
      4'd0:    rsp_byte = op;
      4'd1:    rsp_byte = (kind == K_ERR) ? {6'h00, ec} : {4'h0, a1};
      4'd2:    rsp_byte = a2;
      4'd3:    rsp_byte = {4'h0, nw, 2'b00};
      4'd4:    rsp_byte = (kind == K_WACK) ? 8'h00 : data[95:88];
      default: rsp_byte = data[7'd95 - {k - 4'd4, 3'b000} -: 8];
    endcase
  endfunction

  // ------------------------------------------------------------------
  // storage
  // ------------------------------------------------------------------
  logic [31:0] mem  [0:63];   // 64x32 memory-mapped service storage
  logic [7:0]  attr [0:15];   // 16x8 CPort attribute registers

  // TX response slots, one per traffic class
  logic        q0_valid, q1_valid;
  rsp_t        q0, q1;
  logic [6:0]  q0_timer, q1_timer;  // read-response timeout (100 clk)

  // retransmit buffer (last transmitted frame)
  logic        rb_valid, rb_pend;
  rsp_t        rb;
  logic        rb_tc;
  logic [1:0]  rb_retry;

  logic [3:0]  tx_seq;              // outgoing frame sequence counter

  // ------------------------------------------------------------------
  // RX engine
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {R_IDLE, R_ESC0, R_FRAME, R_DISCARD} rstate_t;
  rstate_t   rxs;
  logic      e_flag;                 // ESC seen inside frame / discard
  logic [4:0] bcnt;                  // byte count within frame
  logic       r_tc;
  logic [3:0] r_cport;
  logic [7:0] r_len;
  logic [7:0] rx_pay [0:15];
  logic [15:0] r_crc;
  logic        match_hi;

  wire [7:0] rbyte = e_flag ? (rx_sym ^ ESC_XOR) : rx_sym;
  wire [5:0] waddr0 = rx_pay[2][7:2];   // word address of mem transaction
  // memory request fields: length 4 / 8 / 12, word aligned, within 256 B
  wire       mem_ok = ((rx_pay[3] == 8'd4) || (rx_pay[3] == 8'd8) || (rx_pay[3] == 8'd12)) &&
                      (rx_pay[1] == 8'h00) && (rx_pay[2][1:0] == 2'b00) &&
                      ({2'b00, rx_pay[2]} + {2'b00, rx_pay[3]} <= 10'd256);

  // ------------------------------------------------------------------
  // TX engine
  // ------------------------------------------------------------------
  typedef enum logic [0:0] {T_IDLE, T_RUN} tstate_t;
  tstate_t   txs;
  rsp_t        t;
  logic        t_tc;
  logic [15:0] t_crc;
  logic [4:0]  t_cnt;
  logic        t_esc;

  wire       tx_idle = (txs == T_IDLE);
  wire       ld_retx = tx_idle && rb_pend;
  wire       ld_tc1  = tx_idle && !rb_pend && q1_valid;
  wire       ld_tc0  = tx_idle && !rb_pend && !q1_valid && q0_valid;
  wire       ld_any  = ld_retx || ld_tc1 || ld_tc0;

  wire [4:0] t_len = rsp_len(t.kind, t.nw);
  wire [4:0] total = 5'd3 + t_len;      // header+payload byte count

  // byte at stream position idx: 0=ESC, 1=COF, 2.. = header/payload, then CRC
  function automatic logic [7:0] byte_at(input logic [4:0] idx);
    logic [4:0] di;
    begin
      di = idx - 5'd2;
      if (idx == 5'd0)           byte_at = SYM_ESC;
      else if (idx == 5'd1)      byte_at = SYM_COF;
      else if (idx <= total + 5'd1) begin
        if (di == 5'd0)      byte_at = {3'b000, t_tc, t.cport};
        else if (di == 5'd1) byte_at = {4'h0, t.seq};
        else if (di == 5'd2) byte_at = {3'b000, t_len};
        else                 byte_at = rsp_byte(t.kind, t.a1, t.a2, t.nw, t.ec, t.data,
                                                4'(di - 5'd3));
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
  // frame decoder: on the last CRC symbol of a good frame, work out the
  // response record (e_go / e) and the side effects the clocked process
  // applies (memory / attribute write, out-of-bounds irq, NAC action)
  // ------------------------------------------------------------------
  wire fr_last = (rxs == R_FRAME) && rx_valid && !(!e_flag && (rx_sym == SYM_ESC)) &&
                 !(e_flag && (rx_sym == SYM_COF)) && (bcnt > 5'd3 + r_len[4:0]);
  wire fr_good = fr_last && match_hi && (rbyte == r_crc[7:0]);

  logic e_go, d_memwr, d_attrwr, d_oob, d_nac;
  rsp_t e;
  always_comb begin
    e_go = 1'b0; d_memwr = 1'b0; d_attrwr = 1'b0; d_oob = 1'b0; d_nac = 1'b0;
    e = '0;
    e.cport = r_cport; e.seq = tx_seq; e.kind = K_ERR;
    if (fr_good) begin
      e_go = 1'b1;
      e.ec = ERR_BADOP;                            // unless decoded below
      case (r_cport)
        CPORT_MEM:
          if (r_len >= 8'd4 && rx_pay[0] == OP_MEM_WR) begin
            if (mem_ok && (r_len == (rx_pay[3] + 8'd4))) begin
              d_memwr = 1'b1;
              e.kind = K_WACK; e.a2 = rx_pay[2]; e.nw = rx_pay[3][3:2];
            end else begin d_oob = 1'b1; e.ec = ERR_OOB; end
          end else if (r_len >= 8'd4 && rx_pay[0] == OP_MEM_RD) begin
            if (mem_ok && (r_len == 8'd4)) begin
              e.kind = K_RRSP; e.a2 = rx_pay[2]; e.nw = rx_pay[3][3:2];
              e.data = {mem[waddr0], mem[waddr0 + 6'd1], mem[waddr0 + 6'd2]};
            end else begin d_oob = 1'b1; e.ec = ERR_OOB; end
          end
        CPORT_PACP:
          if (rx_pay[0] == OP_PACP_GET || rx_pay[0] == OP_PACP_SET) begin
            if (rx_pay[1] >= 8'd16) begin d_oob = 1'b1; e.ec = ERR_OOB; end
            else if (rx_pay[0] == OP_PACP_GET && r_len >= 8'd2) begin
              e.kind = K_GET; e.a1 = rx_pay[1][3:0]; e.a2 = attr[rx_pay[1][3:0]];
            end else if (rx_pay[0] == OP_PACP_SET && r_len >= 8'd3) begin
              d_attrwr = 1'b1;
              e.kind = K_SET; e.a1 = rx_pay[1][3:0]; e.a2 = rx_pay[2];
            end                                    // else too short: bad op
          end else if (rx_pay[0] == OP_NAC) begin
            e_go  = 1'b0;                          // NAC has no response
            d_nac = 1'b1;
          end
        default: ;                                 // unknown CPort: bad op
      endcase
    end
  end

  // ------------------------------------------------------------------
  // sequential logic (single clocked process)
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxs <= R_IDLE;  e_flag <= 1'b0; bcnt <= 5'd0;
      r_tc <= 1'b0; r_cport <= 4'h0; r_len <= 8'h0;
      r_crc <= 16'hFFFF; match_hi <= 1'b0;
      for (int i = 0; i < 16; i++) rx_pay[i] <= 8'h00;
      txs <= T_IDLE; t <= '0; t_tc <= 1'b0; t_crc <= 16'hFFFF; t_cnt <= 5'd0; t_esc <= 1'b0;
      tx_sym <= 8'h00; tx_valid <= 1'b0;
      q0_valid <= 1'b0; q1_valid <= 1'b0; q0 <= '0; q1 <= '0;
      q0_timer <= 7'd0; q1_timer <= 7'd0;
      rb_valid <= 1'b0; rb_pend <= 1'b0; rb <= '0; rb_tc <= 1'b0; rb_retry <= 2'd0;
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
            t <= rb; t_tc <= rb_tc;
            rb_pend <= 1'b0;
          end else if (ld_tc1) begin
            t <= q1; t_tc <= 1'b1;
            q1_valid <= 1'b0;
            rb_valid <= 1'b1; rb <= q1; rb_tc <= 1'b1; rb_retry <= 2'd0;   // kept for NAC
          end else begin
            t <= q0; t_tc <= 1'b0;
            q0_valid <= 1'b0;
            rb_valid <= 1'b1; rb <= q0; rb_tc <= 1'b0; rb_retry <= 2'd0;
          end
          t_crc <= 16'hFFFF; t_cnt <= 5'd0; t_esc <= 1'b0;
          tx_sym <= SYM_ESC; tx_valid <= 1'b1;   // first symbol on the wire
          txs <= T_RUN;
        end
        default: if (tx_valid && tx_ready) begin   // T_RUN
          if (t_esc) begin
            // ESC consumed: send the escaped data byte, byte not yet complete
            tx_sym <= cur_d ^ ESC_XOR;
            t_esc  <= 1'b0;
          end else begin
            // current byte (plain or escaped-data) consumed: byte complete
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
      endcase

      // ---------------- read-response timeout (100 clk) ----------------
      if (q0_valid && q0.kind == K_RRSP && !ld_tc0) begin
        if (q0_timer == 7'd1) begin q0.kind <= K_ERR; q0.ec <= ERR_TIMEOUT; end
        else q0_timer <= q0_timer - 7'd1;
      end
      if (q1_valid && q1.kind == K_RRSP && !ld_tc1) begin
        if (q1_timer == 7'd1) begin q1.kind <= K_ERR; q1.ec <= ERR_TIMEOUT; end
        else q1_timer <= q1_timer - 7'd1;
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
        default: if (rx_valid) begin               // R_FRAME
          if (!e_flag && (rx_sym == SYM_ESC)) e_flag <= 1'b1;
          else if (e_flag && (rx_sym == SYM_COF)) begin
            // COF restarts framing: abort current frame, start a new one
            bcnt <= 5'd0; r_crc <= 16'hFFFF; e_flag <= 1'b0; match_hi <= 1'b0;
          end else begin
            e_flag <= 1'b0;
            if (bcnt == 5'd0) begin
              r_tc    <= rbyte[4];
              r_cport <= rbyte[3:0];
            end else if (bcnt == 5'd2) begin
              r_len <= rbyte;
              if (rbyte > 8'd16) rxs <= R_DISCARD;   // oversized: drop frame
            end else if (bcnt >= 5'd3 && bcnt < (5'd3 + r_len[4:0])) begin
              rx_pay[4'(bcnt - 5'd3)] <= rbyte;
            end else if (bcnt == (5'd3 + r_len[4:0])) begin
              match_hi <= (rbyte == r_crc[15:8]);
            end else if (bcnt > 5'd2) begin
              // last CRC byte: frame complete
              rxs <= R_IDLE;
              if (!match_hi || (rbyte != r_crc[7:0])) begin
                irq <= 1'b1;                       // CRC error
              end else begin
                // ---------------- dispatch ----------------
                if (d_memwr)
                  for (int i = 0; i < 3; i++)
                    if (i < 32'(rx_pay[3][7:2]))
                      mem[waddr0 + 6'(i)] <= {rx_pay[4*i+4], rx_pay[4*i+5],
                                              rx_pay[4*i+6], rx_pay[4*i+7]};
                if (d_attrwr) attr[rx_pay[1][3:0]] <= rx_pay[2];
                if (d_oob) irq <= 1'b1;            // out-of-bounds request
                // NAC: retransmit the last outgoing frame if its seq matches
                if (d_nac && rb_valid && (rb.seq == rx_pay[1][3:0])) begin
                  if (rb_retry == 2'd3) begin
                    rb_valid <= 1'b0;
                    irq      <= 1'b1;              // retransmit exhausted
                  end else begin
                    rb_pend  <= 1'b1;
                    rb_retry <= rb_retry + 2'd1;
                  end
                end
              end
            end
            // CRC covers header + payload bytes only
            if ((bcnt <= 5'd2) || (bcnt < (5'd3 + r_len[4:0])))
              r_crc <= crc16_byte(r_crc, rbyte);
            bcnt <= bcnt + 5'd1;
          end
        end
      endcase

      // ---------------- response enqueue ----------------
      if (e_go) begin
        if (r_tc ? (!q1_valid || ld_tc1) : (!q0_valid || ld_tc0)) begin
          if (r_tc) begin q1_valid <= 1'b1; q1 <= e; q1_timer <= 7'd100; end
          else      begin q0_valid <= 1'b1; q0 <= e; q0_timer <= 7'd100; end
          tx_seq <= tx_seq + 4'd1;
        end else irq <= 1'b1;            // slot busy: response dropped
      end
    end
  end

endmodule
