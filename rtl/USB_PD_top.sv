// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB-PD (USB Power Delivery) UFP / sink-side controller
//
// Implementation scope:
//   * CC-line BMC (biphase-mark coding) encoder/decoder, simplified to
//     1 bit/clk symbol rate: '1' = toggle line level at UI boundary,
//     '0' = hold level (bi-phase-space). Decoder = toggle detect.
//   * Ordered sets (5-bit K-codes, sent MSB first):
//       K_SYNC1 = 5'b11000 (Sync-1), K_SYNC2 = 5'b10001 (Sync-2)
//       K_RST1  = 5'b00111 (RST-1),  K_RST2  = 5'b11001 (RST-2)
//       K_EOP   = 5'b01101 (EOP)
//     SOP       = {SYNC1,SYNC1,SYNC1,SYNC2}  (packed 20'hC6311, annotated as
//                 28'h00C_6311 when zero-extended to 28 bits)
//     HardReset = {RST1,RST1,RST1,RST2}      (SOP'-class reset ordered set)
//   * Message frame: preamble(16 alt bits) + SOP + 16-bit header
//     {ext[15], numobj[14:12], msgid[11:9], powerrole[8], specrev[7:6],
//      datarole[5], msgtype[4:0]} + up to 2 x 32-bit data objects
//     + CRC-32 (poly 0x04C11DB7 reflected -> 32'hEDB8_8320, init/xorout
//     all-ones, good-frame residue 32'hDEBB_20E3) + EOP.
//   * Policy engine (UFP): Source_Capabilities (fixed-supply PDOs; the
//     9 V PDO is chosen when offered as object 2, else 5 V object 1)
//     -> GoodCRC -> Request -> GoodCRC -> Accept -> GoodCRC -> PS_RDY
//     -> GoodCRC -> vbus_ok=1. Reject returns to waiting for capabilities;
//     a new Source_Capabilities in the contract renegotiates.
//   * The Request carries the MessageIDCounter, which advances when its
//     GoodCRC arrives. Without that GoodCRC within GCRC_TO clocks the
//     Request is retried N_RETRY times, then the engine gives up (irq) and
//     waits for capabilities again. A GoodCRC with another id sets irq.
//   * Every valid received non-GoodCRC message is answered with GoodCRC
//     (echoing rx msgid). Bad CRC / framing / numobj>2 -> no GoodCRC + irq.
//   * irq is a level: set by an error, cleared by the next good message.
//   * HardReset ordered set detected any time receiver is hunting sync:
//     policy engine + TX abort back to initial state, vbus_ok cleared,
//     MessageIDCounter reset.
//
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module USB_PD_top #(
  parameter int GCRC_TO = 200,    // CRCReceiveTimer (clocks after the Request)
  parameter int N_RETRY = 2       // Request retries without GoodCRC
)(
  input  logic clk,
  input  logic rst_n,
  input  logic cc_rxd,            // BMC line level received on CC
  output logic cc_txd,            // BMC line level driven onto CC
  output logic cc_tx_en,          // high while this sink owns the CC wire
  output logic vbus_ok,           // explicit contract established
  output logic irq                // protocol error (level, cleared by next good message)
);

  // ------------------------------------------------------------------
  // K-codes / message types / timing constants
  // ------------------------------------------------------------------
  localparam logic [4:0] K_SYNC1 = 5'b11000;  // Sync-1
  localparam logic [4:0] K_SYNC2 = 5'b10001;  // Sync-2
  localparam logic [4:0] K_RST1  = 5'b00111;  // RST-1 (HardReset ordered set)
  localparam logic [4:0] K_RST2  = 5'b11001;  // RST-2
  localparam logic [4:0] K_EOP   = 5'b01101;  // end of packet

  localparam logic [4:0] MT_GOODCRC = 5'h01;  // control (numobj=0)
  localparam logic [4:0] MT_ACCEPT  = 5'h03;  // control
  localparam logic [4:0] MT_REJECT  = 5'h04;  // control
  localparam logic [4:0] MT_PSRDY   = 5'h06;  // control
  localparam logic [4:0] MT_SRCCAP  = 5'h01;  // data (numobj>0)
  localparam logic [4:0] MT_REQUEST = 5'h02;  // data (numobj=1)

  localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3; // good-frame residue
  localparam int          PRE_LEN     = 16;   // preamble bits
  localparam int          TW          = $clog2(GCRC_TO + 1);
  localparam int          NW          = $clog2(N_RETRY + 1);

  // ------------------------------------------------------------------
  // CRC-32 (reflected) single-bit update
  // ------------------------------------------------------------------
  function automatic logic [31:0] crc32_bit(input logic [31:0] c,
                                            input logic        b);
    logic fb;
    begin
      fb        = c[0] ^ b;
      crc32_bit = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0000_0000);
    end
  endfunction

  // ------------------------------------------------------------------
  // RX engine : BMC decode + ordered-set / frame disassembly
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {RX_SYNC, RX_HDR, RX_DATA, RX_CRC, RX_EOP} rx_st_t;
  rx_st_t      rx_st;
  logic        rx_d;                    // previous line sample
  logic [3:0]  sym_win;                 // last 4 bits of the K-code window
  logic [2:0]  sym_skip;                // comma-lock skip counter
  logic        sop_seen, rst_seen;      // a Sync-1 / RST-1 just before
  logic [4:0]  bit_cnt;
  logic [14:0] hdr_sr;
  logic [30:0] obj_sr;
  logic        two_obj;                 // message carries 2 objects
  logic        obj_cnt;
  logic [31:0] rx_crc;
  // received-message capture (valid when rx_done pulses)
  logic [9:0]  rx_obj0_q;               // object 1 max current
  logic [19:0] rx_obj1_q;               // object 2 voltage + max current
  logic [2:0]  rx_msgid;
  logic [1:0]  rx_nobj;
  logic [4:0]  rx_mtype;
  // event pulses
  logic        rx_done, crc_err, prot_err, hrst_det;

  logic        tx_busy;                 // set by TX engine (below)

  wire         rx_bit   = cc_rxd ^ rx_d;        // BMC toggle detect
  wire [15:0]  hdr_next = {rx_bit, hdr_sr};
  wire [31:0]  obj_next = {rx_bit, obj_sr};
  wire [4:0]   win_next = {sym_win[3:0], rx_bit};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_st     <= RX_SYNC;
      rx_d      <= 1'b0;
      sym_win   <= '0;
      sym_skip  <= '0;
      sop_seen  <= 1'b0;
      rst_seen  <= 1'b0;
      bit_cnt   <= '0;
      hdr_sr    <= '0;
      obj_sr    <= '0;
      two_obj   <= 1'b0;
      obj_cnt   <= '0;
      rx_crc    <= CRC_INIT;
      rx_obj0_q <= '0;
      rx_obj1_q <= '0;
      rx_msgid  <= '0;
      rx_nobj   <= '0;
      rx_mtype  <= '0;
      rx_done   <= 1'b0;
      crc_err   <= 1'b0;
      prot_err  <= 1'b0;
      hrst_det  <= 1'b0;
    end else begin
      rx_d     <= cc_rxd;
      rx_done  <= 1'b0;                 // default: 1-clk pulses
      crc_err  <= 1'b0;
      prot_err <= 1'b0;
      hrst_det <= 1'b0;
      if (tx_busy) begin                // half-duplex: ignore own transmit
        rx_st    <= RX_SYNC;
        sym_win  <= '0;
        sym_skip <= '0;
        sop_seen <= 1'b0;
        rst_seen <= 1'b0;
        bit_cnt  <= '0;
      end else begin
        case (rx_st)
          // ---- hunt for SOP / HardReset ordered sets ------------------
          RX_SYNC: begin
            sym_win <= win_next[3:0];
            if (sym_skip != 3'd0) begin
              sym_skip <= sym_skip - 3'd1;
            end else begin
              sop_seen <= 1'b0;
              rst_seen <= 1'b0;
              if (win_next == K_SYNC1) begin
                sop_seen <= 1'b1;
                sym_skip <= 3'd4;       // comma lock: next symbol in 5 clks
              end else if (win_next == K_SYNC2 && sop_seen) begin
                rx_st    <= RX_HDR;     // SOP acquired
                bit_cnt  <= '0;
                rx_crc   <= CRC_INIT;
                sym_win  <= '0;
              end else if (win_next == K_RST1) begin
                rst_seen <= 1'b1;
                sym_skip <= 3'd4;
              end else if (win_next == K_RST2 && rst_seen) begin
                hrst_det <= 1'b1;       // HardReset ordered set received
                sym_skip <= 3'd4;
              end
            end
          end
          // ---- 16-bit message header (LSB first) ----------------------
          RX_HDR: begin
            hdr_sr  <= hdr_next[15:1];
            rx_crc  <= crc32_bit(rx_crc, rx_bit);
            bit_cnt <= bit_cnt + 5'd1;
            if (bit_cnt == 5'd15) begin
              bit_cnt <= '0;
              if (hdr_next[14:12] > 3'd2) begin
                prot_err <= 1'b1;       // this design carries <=2 objects
                rx_st    <= RX_SYNC;
                sym_win  <= '0;
              end else begin
                rx_nobj  <= hdr_next[13:12];
                rx_msgid <= hdr_next[11:9];
                rx_mtype <= hdr_next[4:0];
                two_obj  <= hdr_next[13];
                obj_cnt  <= 1'b0;
                rx_st    <= (hdr_next[13:12] == 2'd0) ? RX_CRC : RX_DATA;
              end
            end
          end
          // ---- up to 2 data objects (LSB first) -----------------------
          RX_DATA: begin
            obj_sr  <= obj_next[31:1];
            rx_crc  <= crc32_bit(rx_crc, rx_bit);
            bit_cnt <= bit_cnt + 5'd1;
            if (bit_cnt == 5'd31) begin
              if (obj_cnt == 1'b0) rx_obj0_q <= obj_next[9:0];
              else                 rx_obj1_q <= obj_next[19:0];
              obj_cnt <= 1'b1;
              if (obj_cnt == two_obj) rx_st <= RX_CRC;
            end
          end
          // ---- 32-bit CRC (fed through the checker) -------------------
          RX_CRC: begin
            rx_crc  <= crc32_bit(rx_crc, rx_bit);
            bit_cnt <= bit_cnt + 5'd1;
            if (bit_cnt == 5'd31) begin
              sym_win <= '0;
              rx_st   <= RX_EOP;
            end
          end
          // ---- EOP K-code ---------------------------------------------
          default: begin                // RX_EOP
            sym_win <= win_next[3:0];
            bit_cnt <= bit_cnt + 5'd1;
            if (bit_cnt == 5'd4) begin
              bit_cnt  <= '0;
              rx_st    <= RX_SYNC;
              sym_win  <= '0;
              if (win_next == K_EOP && rx_crc == CRC_RESIDUE)
                rx_done <= 1'b1;        // valid message available
              else
                crc_err <= 1'b1;        // bad CRC or bad framing
            end
          end
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // TX engine : BMC encode + frame assembly (GoodCRC / Request)
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {TX_IDLE, TX_PRE, TX_SOP, TX_HDR,
                            TX_DATA, TX_CRC, TX_EOP, TX_GAP} tx_st_t;
  tx_st_t      tx_st;
  logic [4:0]  tx_bit_cnt;
  logic [1:0]  tx_sym_cnt;
  logic        tx_req;                  // frame is a Request (else GoodCRC)
  logic [2:0]  tx_id;                   // header MessageID
  logic [31:0] tx_crc;
  logic        line;
  logic [1:0]  gap_cnt;

  // pending transmit requests (owned by policy engine)
  logic        pend_gc, pend_req;
  logic [2:0]  gc_msgid, tx_msgid;
  logic        rdo_9v;                  // Request object position 2 (else 1)
  logic [9:0]  rdo_cur;                 // operating = max current (10 mA)
  logic        tx_gc_start, tx_req_start;

  assign tx_busy = (tx_st != TX_IDLE);

  // header bit i: {ext, numobj, msgid, powerrole=0(sink), specrev=2'b10,
  //                datarole=0(UFP), msgtype} -- Request (1 object) or GoodCRC
  function automatic logic hdr_bit(input logic req, input logic [2:0] id,
                                   input logic [3:0] i);
    logic [15:0] h;
    h = req ? {1'b0, 3'd1, id, 1'b0, 2'b10, 1'b0, MT_REQUEST}
            : {1'b0, 3'd0, id, 1'b0, 2'b10, 1'b0, MT_GOODCRC};
    return h[i];
  endfunction
  // fixed-supply Request data object bit i: {object position (2 = 9 V,
  // else 1), 8'h00, operating current, max current}
  function automatic logic rdo_bit(input logic pos2, input logic [9:0] cur,
                                   input logic [4:0] i);
    logic [31:0] r;
    r = {1'b0, pos2 ? 3'd2 : 3'd1, 8'h00, cur, cur};
    return r[i];
  endfunction
  // SOP K-code sequence SYNC1,SYNC1,SYNC1,SYNC2: bit i (MSB first) of symbol n
  function automatic logic sop_bit(input logic [1:0] n, input logic [2:0] i);
    logic [4:0] k;
    k = (n == 2'd3) ? K_SYNC2 : K_SYNC1;
    return k[3'd4 - i];
  endfunction
  wire [31:0] tx_crc_final = ~tx_crc;

  logic tx_bit;
  always_comb begin
    case (tx_st)
      TX_PRE : tx_bit = tx_bit_cnt[0];                 // 0,1,0,1...
      TX_SOP : tx_bit = sop_bit(tx_sym_cnt, tx_bit_cnt[2:0]);
      TX_HDR : tx_bit = hdr_bit(tx_req, tx_id, tx_bit_cnt[3:0]); // LSB first
      TX_DATA: tx_bit = rdo_bit(rdo_9v, rdo_cur, tx_bit_cnt);    // LSB first
      TX_CRC : tx_bit = tx_crc_final[tx_bit_cnt];      // LSB first
      default: tx_bit = K_EOP[3'd4 - tx_bit_cnt[2:0]]; // EOP, MSB first
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_st        <= TX_IDLE;
      tx_bit_cnt   <= '0;
      tx_sym_cnt   <= '0;
      tx_req       <= 1'b0;
      tx_id        <= '0;
      tx_crc       <= CRC_INIT;
      line         <= 1'b1;
      cc_tx_en     <= 1'b0;
      gap_cnt      <= '0;
      tx_gc_start  <= 1'b0;
      tx_req_start <= 1'b0;
    end else begin
      tx_gc_start  <= 1'b0;
      tx_req_start <= 1'b0;
      case (tx_st)
        TX_IDLE: begin
          if (pend_gc || pend_req) begin
            tx_req       <= !pend_gc;   // GoodCRC first
            tx_id        <= pend_gc ? gc_msgid : tx_msgid;
            tx_gc_start  <= pend_gc;
            tx_req_start <= !pend_gc;
            line       <= 1'b1;
            cc_tx_en   <= 1'b1;
            tx_crc     <= CRC_INIT;
            tx_bit_cnt <= '0;
            tx_sym_cnt <= '0;
            tx_st      <= TX_PRE;
          end
        end
        TX_PRE: begin
          line       <= line ^ tx_bit;  // BMC: toggle on '1'
          tx_bit_cnt <= tx_bit_cnt + 5'd1;
          if (tx_bit_cnt == 5'(PRE_LEN - 1)) begin
            tx_bit_cnt <= '0;
            tx_st      <= TX_SOP;
          end
        end
        TX_SOP: begin
          line       <= line ^ tx_bit;
          tx_bit_cnt <= tx_bit_cnt + 5'd1;
          if (tx_bit_cnt == 5'd4) begin
            tx_bit_cnt <= '0;
            tx_sym_cnt <= tx_sym_cnt + 2'd1;
            if (tx_sym_cnt == 2'd3) tx_st <= TX_HDR;
          end
        end
        TX_HDR: begin
          line       <= line ^ tx_bit;
          tx_crc     <= crc32_bit(tx_crc, tx_bit);
          tx_bit_cnt <= tx_bit_cnt + 5'd1;
          if (tx_bit_cnt == 5'd15) begin
            tx_bit_cnt <= '0;
            tx_st      <= tx_req ? TX_DATA : TX_CRC;
          end
        end
        TX_DATA: begin
          line       <= line ^ tx_bit;
          tx_crc     <= crc32_bit(tx_crc, tx_bit);
          tx_bit_cnt <= tx_bit_cnt + 5'd1;
          if (tx_bit_cnt == 5'd31) tx_st <= TX_CRC;
        end
        TX_CRC: begin
          line       <= line ^ tx_bit;
          tx_bit_cnt <= tx_bit_cnt + 5'd1;
          if (tx_bit_cnt == 5'd31) tx_st <= TX_EOP;
        end
        TX_EOP: begin
          line       <= line ^ tx_bit;
          tx_bit_cnt <= tx_bit_cnt + 5'd1;
          if (tx_bit_cnt == 5'd4) begin
            gap_cnt <= '0;
            tx_st   <= TX_GAP;
          end
        end
        default: begin                // TX_GAP: inter-frame gap, release CC
          cc_tx_en <= 1'b0;
          gap_cnt  <= gap_cnt + 2'd1;
          if (gap_cnt == 2'd2) tx_st <= TX_IDLE;
        end
      endcase
    end
  end

  assign cc_txd = line;

  // ------------------------------------------------------------------
  // Policy engine (UFP): SrcCap -> Request -> Accept -> PS_RDY
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {PE_WAIT_CAPS, PE_WAIT_GCRC, PE_WAIT_ACCEPT,
                            PE_WAIT_PSRDY, PE_CONTRACT} pe_st_t;
  pe_st_t        pe_st;
  logic          irq_r;
  logic [TW-1:0] gcrc_cnt;
  logic [NW-1:0] retry;

  // fixed-supply PDO decode: voltage in 50 mV units at [19:10],
  // max current in 10 mA units at [9:0]. Select 9 V (180) when offered.
  wire obj1_is_9v = (rx_obj1_q[19:10] == 10'd180) && (rx_nobj == 2'd2);
  wire is_ctrl    = (rx_nobj == 2'd0);
  wire caps_rx    = rx_done && rx_mtype == MT_SRCCAP && !is_ctrl;
  wire gcrc_rx    = rx_done && rx_mtype == MT_GOODCRC && is_ctrl;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pe_st    <= PE_WAIT_CAPS;
      vbus_ok  <= 1'b0;
      pend_gc  <= 1'b0;
      pend_req <= 1'b0;
      gc_msgid <= '0;
      tx_msgid <= '0;
      rdo_9v   <= 1'b0;
      rdo_cur  <= '0;
      irq_r    <= 1'b0;
      gcrc_cnt <= '0;
      retry    <= '0;
    end else if (hrst_det) begin
      pe_st    <= PE_WAIT_CAPS;         // HardReset: back to initial state
      vbus_ok  <= 1'b0;
      pend_gc  <= 1'b0;
      pend_req <= 1'b0;
      tx_msgid <= '0;
      irq_r    <= 1'b0;
    end else begin
      if (tx_gc_start)  pend_gc  <= 1'b0;
      if (tx_req_start) pend_req <= 1'b0;
      if (crc_err || prot_err) irq_r <= 1'b1;
      else if (rx_done)        irq_r <= 1'b0;
      // GoodCRC every valid received message except GoodCRC itself
      if (rx_done && !gcrc_rx) begin
        pend_gc  <= 1'b1;
        gc_msgid <= rx_msgid;
      end
      if (caps_rx && (pe_st == PE_WAIT_CAPS || pe_st == PE_CONTRACT)) begin
        rdo_9v   <= obj1_is_9v;         // latch the Request data object
        rdo_cur  <= obj1_is_9v ? rx_obj1_q[9:0] : rx_obj0_q;
        pend_req <= 1'b1;
        vbus_ok  <= 1'b0;
        gcrc_cnt <= '0;
        retry    <= '0;
        pe_st    <= PE_WAIT_GCRC;
      end
      case (pe_st)
        PE_WAIT_GCRC: begin
          if (pend_req || tx_busy) gcrc_cnt <= '0;
          else                     gcrc_cnt <= gcrc_cnt + 1'b1;
          if (gcrc_rx) begin
            if (rx_msgid == tx_msgid) begin
              tx_msgid <= tx_msgid + 3'd1;  // MessageIDCounter
              pe_st    <= PE_WAIT_ACCEPT;
            end else irq_r <= 1'b1;         // msgid mismatch
          end else if (gcrc_cnt == TW'(GCRC_TO)) begin
            gcrc_cnt <= '0;
            if (retry == NW'(N_RETRY)) begin
              irq_r <= 1'b1;                // no GoodCRC: give up
              pe_st <= PE_WAIT_CAPS;
            end else begin
              retry    <= retry + 1'b1;
              pend_req <= 1'b1;             // retransmit, same MessageID
            end
          end
        end
        PE_WAIT_ACCEPT: begin
          if (rx_done && is_ctrl && rx_mtype == MT_ACCEPT) pe_st <= PE_WAIT_PSRDY;
          if (rx_done && is_ctrl && rx_mtype == MT_REJECT) pe_st <= PE_WAIT_CAPS;
        end
        PE_WAIT_PSRDY: begin
          if (rx_done && is_ctrl && rx_mtype == MT_PSRDY) begin
            vbus_ok <= 1'b1;            // explicit contract up
            pe_st   <= PE_CONTRACT;
          end
        end
        default: ;                      // WAIT_CAPS / CONTRACT: caps above
      endcase
    end
  end

  assign irq = irq_r;

endmodule
