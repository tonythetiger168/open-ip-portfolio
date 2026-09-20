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
//   * Policy engine (UFP): Source_Capabilities (fixed-supply PDOs
//     5V/1.5A + 9V/2A) -> GoodCRC -> Request (selects 9V PDO, obj pos 2)
//     -> GoodCRC -> Accept -> GoodCRC -> PS_RDY -> GoodCRC -> vbus_ok=1.
//   * Every valid received non-GoodCRC message is answered with GoodCRC
//     (echoing rx msgid). Bad CRC / framing / numobj>2 -> no GoodCRC + irq.
//   * HardReset ordered set detected any time receiver is hunting sync:
//     policy engine + TX abort back to initial state, vbus_ok cleared.
//
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module USB_PD_top #(
  parameter int DW = 32,          // kept for framework compatibility
  parameter int AW = 32           // kept for framework compatibility
)(
  input  logic clk,
  input  logic rst_n,
  input  logic cc_rxd,            // BMC line level received on CC
  output logic cc_txd,            // BMC line level driven onto CC
  output logic cc_tx_en,          // high while this sink owns the CC wire
  output logic vbus_ok,           // explicit 9V contract established
  output logic irq                // protocol error event (sticky till next ok)
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
  localparam logic [4:0] MT_PSRDY   = 5'h06;  // control
  localparam logic [4:0] MT_SRCCAP  = 5'h01;  // data (numobj>0)
  localparam logic [4:0] MT_REQUEST = 5'h02;  // data (numobj=1)

  localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3; // good-frame residue
  localparam int          PRE_LEN     = 16;   // preamble bits

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
  logic [4:0]  sym_win;                 // sliding 5-bit K-code window
  logic [2:0]  sym_skip;                // comma-lock skip counter
  logic [1:0]  sop_cnt, rst_cnt;
  logic [5:0]  bit_cnt;
  logic [15:0] hdr_sr;
  logic [31:0] obj_sr;
  logic [2:0]  nobj;
  logic        obj_cnt;
  logic [31:0] rx_crc;
  // received-message capture (valid when rx_done pulses)
  logic [15:0] rx_hdr_q;
  logic [31:0] rx_obj0_q, rx_obj1_q;
  logic [2:0]  rx_msgid, rx_nobj;
  logic [4:0]  rx_mtype;
  // event pulses
  logic        rx_done, crc_err, prot_err, hrst_det;

  logic        tx_busy;                 // set by TX engine (below)

  wire         rx_bit   = cc_rxd ^ rx_d;        // BMC toggle detect
  wire [15:0]  hdr_next = {rx_bit, hdr_sr[15:1]};
  wire [31:0]  obj_next = {rx_bit, obj_sr[31:1]};
  wire [4:0]   win_next = {sym_win[3:0], rx_bit};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_st     <= RX_SYNC;
      rx_d      <= 1'b0;
      sym_win   <= '0;
      sym_skip  <= '0;
      sop_cnt   <= '0;
      rst_cnt   <= '0;
      bit_cnt   <= '0;
      hdr_sr    <= '0;
      obj_sr    <= '0;
      nobj      <= '0;
      obj_cnt   <= '0;
      rx_crc    <= CRC_INIT;
      rx_hdr_q  <= '0;
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
        sop_cnt  <= '0;
        rst_cnt  <= '0;
        bit_cnt  <= '0;
      end else begin
        case (rx_st)
          // ---- hunt for SOP / HardReset ordered sets ------------------
          RX_SYNC: begin
            sym_win <= win_next;
            if (sym_skip != 3'd0) begin
              sym_skip <= sym_skip - 3'd1;
            end else begin
              if (win_next == K_SYNC1) begin
                sop_cnt  <= (sop_cnt == 2'd3) ? 2'd3 : sop_cnt + 2'd1;
                rst_cnt  <= 2'd0;
                sym_skip <= 3'd4;       // comma lock: next symbol in 5 clks
              end else if (win_next == K_SYNC2 && sop_cnt != 2'd0) begin
                rx_st    <= RX_HDR;     // SOP acquired
                bit_cnt  <= '0;
                hdr_sr   <= '0;
                rx_crc   <= CRC_INIT;
                sop_cnt  <= '0;
                rst_cnt  <= '0;
                sym_win  <= '0;
                sym_skip <= '0;
              end else if (win_next == K_RST1) begin
                rst_cnt  <= (rst_cnt == 2'd3) ? 2'd3 : rst_cnt + 2'd1;
                sop_cnt  <= 2'd0;
                sym_skip <= 3'd4;
              end else if (win_next == K_RST2 && rst_cnt != 2'd0) begin
                hrst_det <= 1'b1;       // HardReset ordered set received
                rst_cnt  <= 2'd0;
                sop_cnt  <= 2'd0;
                sym_skip <= 3'd4;
              end else begin
                sop_cnt <= 2'd0;
                rst_cnt <= 2'd0;
              end
            end
          end
          // ---- 16-bit message header (LSB first) ----------------------
          RX_HDR: begin
            hdr_sr <= hdr_next;
            rx_crc <= crc32_bit(rx_crc, rx_bit);
            if (bit_cnt == 6'd15) begin
              bit_cnt <= '0;
              if (hdr_next[14:12] > 3'd2) begin
                prot_err <= 1'b1;       // this design carries <=2 objects
                rx_st    <= RX_SYNC;
                sym_win  <= '0;
                sym_skip <= '0;
              end else begin
                rx_hdr_q <= hdr_next;
                rx_nobj  <= hdr_next[14:12];
                rx_msgid <= hdr_next[11:9];
                rx_mtype <= hdr_next[4:0];
                nobj     <= hdr_next[14:12];
                obj_cnt  <= 1'b0;
                obj_sr   <= '0;
                rx_st    <= (hdr_next[14:12] == 3'd0) ? RX_CRC : RX_DATA;
              end
            end else begin
              bit_cnt <= bit_cnt + 6'd1;
            end
          end
          // ---- up to 2 data objects (LSB first) -----------------------
          RX_DATA: begin
            obj_sr <= obj_next;
            rx_crc <= crc32_bit(rx_crc, rx_bit);
            if (bit_cnt == 6'd31) begin
              bit_cnt <= '0;
              obj_sr  <= '0;
              if (obj_cnt == 1'b0) rx_obj0_q <= obj_next;
              else                 rx_obj1_q <= obj_next;
              if ({2'b0, obj_cnt} == nobj - 3'd1) rx_st <= RX_CRC;
              else                                obj_cnt <= obj_cnt + 1'b1;
            end else begin
              bit_cnt <= bit_cnt + 6'd1;
            end
          end
          // ---- 32-bit CRC (fed through the checker) -------------------
          RX_CRC: begin
            rx_crc <= crc32_bit(rx_crc, rx_bit);
            if (bit_cnt == 6'd31) begin
              bit_cnt <= '0;
              sym_win <= '0;
              rx_st   <= RX_EOP;
            end else begin
              bit_cnt <= bit_cnt + 6'd1;
            end
          end
          // ---- EOP K-code ---------------------------------------------
          RX_EOP: begin
            sym_win <= win_next;
            if (bit_cnt == 6'd4) begin
              bit_cnt  <= '0;
              rx_st    <= RX_SYNC;
              sym_win  <= '0;
              sym_skip <= '0;
              sop_cnt  <= '0;
              rst_cnt  <= '0;
              if (win_next == K_EOP && rx_crc == CRC_RESIDUE)
                rx_done <= 1'b1;        // valid message available
              else
                crc_err <= 1'b1;        // bad CRC or bad framing
            end else begin
              bit_cnt <= bit_cnt + 6'd1;
            end
          end
          default: rx_st <= RX_SYNC;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // TX engine : BMC encode + frame assembly (GoodCRC / Request)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {TX_IDLE, TX_PRE, TX_SOP, TX_HDR,
                            TX_DATA, TX_CRC, TX_EOP, TX_GAP} tx_st_t;
  tx_st_t      tx_st;
  logic [5:0]  tx_bit_cnt;
  logic [1:0]  tx_sym_cnt;
  logic [15:0] tx_hdr_q;
  logic [31:0] tx_obj_q;
  logic        tx_nobj;
  logic [31:0] tx_crc;
  logic        line;
  logic [1:0]  gap_cnt;

  // pending transmit requests (owned by policy engine)
  logic        pend_gc, pend_req;
  logic [2:0]  gc_msgid;
  logic [31:0] rdo_q;
  logic        tx_gc_start, tx_req_start;

  assign tx_busy = (tx_st != TX_IDLE);

  // SOP K-code sequence: SYNC1,SYNC1,SYNC1,SYNC2 (MSB first)
  wire [4:0] tx_sym = (tx_sym_cnt == 2'd3) ? K_SYNC2 : K_SYNC1;
  wire [31:0] tx_crc_final = tx_crc ^ 32'hFFFF_FFFF;

  logic tx_bit;
  always @* begin
    tx_bit = 1'b0;
    case (tx_st)
      TX_PRE : tx_bit = tx_bit_cnt[0];                 // 0,1,0,1...
      TX_SOP : tx_bit = tx_sym[3'd4 - tx_bit_cnt[2:0]];// MSB first
      TX_HDR : tx_bit = tx_hdr_q[tx_bit_cnt[3:0]];     // LSB first
      TX_DATA: tx_bit = tx_obj_q[tx_bit_cnt[4:0]];     // LSB first
      TX_CRC : tx_bit = tx_crc_final[tx_bit_cnt[4:0]]; // LSB first
      TX_EOP : tx_bit = K_EOP[3'd4 - tx_bit_cnt[2:0]]; // MSB first
      default: tx_bit = 1'b0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_st        <= TX_IDLE;
      tx_bit_cnt   <= '0;
      tx_sym_cnt   <= '0;
      tx_hdr_q     <= '0;
      tx_obj_q     <= '0;
      tx_nobj      <= 1'b0;
      tx_crc       <= CRC_INIT;
      line         <= 1'b1;
      cc_tx_en     <= 1'b0;
      gap_cnt      <= '0;
      tx_gc_start  <= 1'b0;
      tx_req_start <= 1'b0;
    end else begin
      tx_gc_start  <= 1'b0;
      tx_req_start <= 1'b0;
      if (hrst_det) begin               // HardReset aborts any transmit
        tx_st    <= TX_IDLE;
        cc_tx_en <= 1'b0;
      end else begin
        case (tx_st)
          TX_IDLE: begin
            cc_tx_en <= 1'b0;
            if (pend_gc || pend_req) begin
              // header: {ext, numobj, msgid, powerrole=0(sink),
              //          specrev=2'b10, datarole=0(UFP), msgtype}
              if (pend_gc) begin
                tx_hdr_q     <= {1'b0, 3'd0, gc_msgid, 1'b0, 2'b10,
                                 1'b0, MT_GOODCRC};
                tx_nobj      <= 1'b0;
                tx_gc_start  <= 1'b1;
              end else begin
                tx_hdr_q     <= {1'b0, 3'd1, 3'd0, 1'b0, 2'b10,
                                 1'b0, MT_REQUEST};
                tx_obj_q     <= rdo_q;
                tx_nobj      <= 1'b1;
                tx_req_start <= 1'b1;
              end
              line       <= 1'b1;
              cc_tx_en   <= 1'b1;
              tx_crc     <= CRC_INIT;
              tx_bit_cnt <= '0;
              tx_sym_cnt <= '0;
              tx_st      <= TX_PRE;
            end
          end
          TX_PRE: begin
            line <= line ^ tx_bit;      // BMC: toggle on '1'
            if (tx_bit_cnt == PRE_LEN-1) begin
              tx_bit_cnt <= '0;
              tx_st      <= TX_SOP;
            end else tx_bit_cnt <= tx_bit_cnt + 6'd1;
          end
          TX_SOP: begin
            line <= line ^ tx_bit;
            if (tx_bit_cnt == 6'd4) begin
              tx_bit_cnt <= '0;
              if (tx_sym_cnt == 2'd3) tx_st <= TX_HDR;
              else                    tx_sym_cnt <= tx_sym_cnt + 2'd1;
            end else tx_bit_cnt <= tx_bit_cnt + 6'd1;
          end
          TX_HDR: begin
            line   <= line ^ tx_bit;
            tx_crc <= crc32_bit(tx_crc, tx_bit);
            if (tx_bit_cnt == 6'd15) begin
              tx_bit_cnt <= '0;
              tx_st      <= tx_nobj ? TX_DATA : TX_CRC;
            end else tx_bit_cnt <= tx_bit_cnt + 6'd1;
          end
          TX_DATA: begin
            line   <= line ^ tx_bit;
            tx_crc <= crc32_bit(tx_crc, tx_bit);
            if (tx_bit_cnt == 6'd31) begin
              tx_bit_cnt <= '0;
              tx_st      <= TX_CRC;
            end else tx_bit_cnt <= tx_bit_cnt + 6'd1;
          end
          TX_CRC: begin
            line <= line ^ tx_bit;
            if (tx_bit_cnt == 6'd31) begin
              tx_bit_cnt <= '0;
              tx_st      <= TX_EOP;
            end else tx_bit_cnt <= tx_bit_cnt + 6'd1;
          end
          TX_EOP: begin
            line <= line ^ tx_bit;
            if (tx_bit_cnt == 6'd4) begin
              tx_bit_cnt <= '0;
              gap_cnt    <= '0;
              tx_st      <= TX_GAP;
            end else tx_bit_cnt <= tx_bit_cnt + 6'd1;
          end
          TX_GAP: begin                 // inter-frame gap, release CC wire
            cc_tx_en <= 1'b0;
            if (gap_cnt == 2'd2) tx_st <= TX_IDLE;
            else                 gap_cnt <= gap_cnt + 2'd1;
          end
          default: tx_st <= TX_IDLE;
        endcase
      end
    end
  end

  assign cc_txd = line;

  // ------------------------------------------------------------------
  // Policy engine (UFP): SrcCap -> Request(9V) -> Accept -> PS_RDY
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {PE_WAIT_CAPS, PE_WAIT_GCRC, PE_WAIT_ACCEPT,
                            PE_WAIT_PSRDY, PE_CONTRACT} pe_st_t;
  pe_st_t pe_st;
  logic   irq_r;

  // fixed-supply PDO decode: voltage in 50 mV units at [19:10],
  // max current in 10 mA units at [9:0]. Select 9 V (180) when offered.
  wire obj1_is_9v = (rx_obj1_q[19:10] == 10'd180) && (rx_nobj >= 3'd2);
  wire [31:0] rdo_sel = obj1_is_9v
        ? {4'd2, 8'h00, rx_obj1_q[9:0], rx_obj1_q[9:0]}  // pos 2, op=max
        : {4'd1, 8'h00, rx_obj0_q[9:0], rx_obj0_q[9:0]}; // fallback 5 V

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pe_st    <= PE_WAIT_CAPS;
      vbus_ok  <= 1'b0;
      pend_gc  <= 1'b0;
      pend_req <= 1'b0;
      gc_msgid <= '0;
      rdo_q    <= '0;
      irq_r    <= 1'b0;
    end else begin
      if (tx_gc_start)  pend_gc  <= 1'b0;
      if (tx_req_start) pend_req <= 1'b0;
      if (hrst_det) begin
        pe_st    <= PE_WAIT_CAPS;       // HardReset: back to initial state
        vbus_ok  <= 1'b0;
        pend_gc  <= 1'b0;
        pend_req <= 1'b0;
        irq_r    <= 1'b0;
      end else begin
        if (crc_err || prot_err) irq_r <= 1'b1;
        else if (rx_done)        irq_r <= 1'b0;
        if (rx_done) begin
          // GoodCRC every valid received message except GoodCRC itself
          if (!(rx_mtype == MT_GOODCRC && rx_nobj == 3'd0)) begin
            pend_gc  <= 1'b1;
            gc_msgid <= rx_msgid;
          end
          case (pe_st)
            PE_WAIT_CAPS: begin
              if (rx_mtype == MT_SRCCAP && rx_nobj != 3'd0) begin
                rdo_q    <= rdo_sel;    // latch Request data object (9V)
                pend_req <= 1'b1;
                pe_st    <= PE_WAIT_GCRC;
              end
            end
            PE_WAIT_GCRC: begin
              if (rx_mtype == MT_GOODCRC) begin
                if (rx_msgid == 3'd0) pe_st <= PE_WAIT_ACCEPT;
                else                  irq_r <= 1'b1;  // msgid mismatch
              end
            end
            PE_WAIT_ACCEPT: begin
              if (rx_mtype == MT_ACCEPT && rx_nobj == 3'd0)
                pe_st <= PE_WAIT_PSRDY;
            end
            PE_WAIT_PSRDY: begin
              if (rx_mtype == MT_PSRDY && rx_nobj == 3'd0) begin
                vbus_ok <= 1'b1;        // explicit 9 V contract up
                pe_st   <= PE_CONTRACT;
              end
            end
            PE_CONTRACT: begin          // source may re-advertise caps
              if (rx_mtype == MT_SRCCAP && rx_nobj != 3'd0) begin
                rdo_q    <= rdo_sel;    // re-negotiate: new Request
                pend_req <= 1'b1;
                vbus_ok  <= 1'b0;
                pe_st    <= PE_WAIT_GCRC;
              end
            end
            default: pe_st <= PE_WAIT_CAPS;
          endcase
        end
      end
    end
  end

  assign irq = irq_r;

  // keep framework parameters visibly used (no functional effect)
  wire unused = &{1'b0, DW[0], AW[0]};

endmodule
