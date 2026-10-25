// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Bluetooth 5 (BLE) link layer peripheral -- synthesizable baseband model
//
// Implementation scope (simplified, NOT the full BLE LL specification):
//  - Air interface: 1 bit/clk, LSB-first per byte (BLE over-the-air order).
//    Preamble: 8'hAA when the access address LSB is 0, else 8'h55.
//  - Advertising channel 37: preamble + AccessAddress 32'h8E89BED6 +
//    PDU header {rfu[3:0],type[3:0]}{len[7:0]} + payload + CRC24 (serial
//    LFSR, poly 24'h00065B, init 24'h555555, sent register bit 0 first).
//  - Data whitening: LFSR poly x^7+x^4+1 (out = l[6], l <<= l[6]^l[3]),
//    seed = channel index | 1 (adv ch37 -> 7'h25); applied to everything
//    after the access address (header + payload + CRC).
//  - ADV_IND every ADV_INTV clks while advertising and adv_en (payload =
//    16x8 host-writable register file, read while it is sent).
//    SCAN_REQ (scan_en) -> SCAN_RSP (payload[i] = 8'h53+i).
//  - CONNECT_REQ with the simplified 15-byte LLData (AA[4], CRCInit[3],
//    interval[2], latency[2], timeout[2], hop[1], chan[1]) -> CONNECTION
//    state on the new access address. Another length -> irq, ignored.
//  - Connection events every `interval` clks. Channel selection (CSA#1
//    without channel-map remapping): the first event uses chan mod 37,
//    each later event (channel + hop) mod 37.
//  - Data channel PDU: header {rfu[2:0],md,sn,nesn,llid[1:0]}{len[7:0]}
//    + payload (<= 16 B) + CRC24 (init = CRCInit). SN / NESN as in the
//    spec; every valid central PDU gets an empty-PDU response (ack).
//    An event without central traffic counts as missed; after more than
//    `latency` missed events in a row the peripheral sends an empty PDU
//    each event; `timeout` (events, 0 = off) missed events in a row drop
//    the connection (back to advertising, irq).
//  - irq (1-clk pulse): bad CRC24, unknown advertising PDU type, reserved
//    LLID, length > 16, CONNECT_REQ of the wrong length, supervision
//    timeout.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module Bluetooth5_top #(
  parameter int ADV_INTV = 1200      // advertising interval (clks)
)(
  input  logic        clk,
  input  logic        rst_n,
  // BLE baseband (1 bit/clk, LSB-first)
  input  logic        rxd,
  output logic        txd,
  output logic        tx_act,
  // host config port: addr 0..15 = adv payload bytes, 16 = ctrl(bit0 adv_en),
  //                   17 = ctrl2(bit0 scan_en)
  input  logic        cfg_we,
  input  logic [4:0]  cfg_addr,
  input  logic [7:0]  cfg_wdata,
  output logic        irq
);

  // ------------------------- constants -------------------------------------
  localparam logic [31:0] ADV_AA    = 32'h8E89BED6; // advertising access addr
  localparam logic [23:0] ADV_CRCI  = 24'h555555;   // adv channel CRC init
  localparam logic [6:0]  ADV_WSEED = 7'h25;        // ch37 | 1 whitening seed
  localparam logic [3:0]  PT_ADV_IND    = 4'h0;
  localparam logic [3:0]  PT_ADV_DIRECT = 4'h1;
  localparam logic [3:0]  PT_ADV_NONC   = 4'h2;
  localparam logic [3:0]  PT_SCAN_REQ   = 4'h3;
  localparam logic [3:0]  PT_SCAN_RSP   = 4'h4;
  localparam logic [3:0]  PT_CONN_REQ   = 4'h5;
  localparam logic [3:0]  PT_ADV_SCAN   = 4'h6;

  // ------------------------- whitening / CRC24 ------------------------------
  function automatic logic [6:0] white_next(input logic [6:0] l);
    white_next = {l[5:0], l[6] ^ l[3]};
  endfunction

  function automatic logic [23:0] crc24_bit(input logic [23:0] crc, input logic b);
    crc24_bit = (crc[0] ^ b) ? ((crc >> 1) ^ 24'h00065B) : (crc >> 1);
  endfunction

  // ------------------------- host config / adv payload ----------------------
  logic [7:0] adv_pay [0:15];
  logic       adv_en, scan_en;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      adv_en  <= 1'b1;
      scan_en <= 1'b1;
      for (int i = 0; i < 16; i++) adv_pay[i] <= 8'hB0 + 8'(i);
    end else if (cfg_we) begin
      if (cfg_addr < 5'd16)       adv_pay[cfg_addr[3:0]] <= cfg_wdata;
      else if (cfg_addr == 5'd16) adv_en  <= cfg_wdata[0];
      else if (cfg_addr == 5'd17) scan_en <= cfg_wdata[0];
    end
  end

  // ------------------------- link state / connection registers --------------
  typedef enum logic {LS_ADV, LS_CONN} ls_t;
  ls_t         ll_state;
  logic [31:0] conn_aa;
  logic [23:0] conn_crci;
  logic [15:0] conn_interval, conn_latency, conn_timeout;
  logic [4:0]  hop_inc;
  logic [5:0]  dch;                    // data channel index
  logic        rx_sn;                  // next expected SN from the central (= our NESN)
  logic        tx_sn;                  // our SN
  logic [15:0] conn_timer;
  logic [15:0] miss;                   // missed connection events in a row
  logic        rx_seen;                // central traffic this event
  localparam int ATW = $clog2(ADV_INTV + 1);
  logic [ATW-1:0] adv_timer;

  // whitening seed of a data channel
  function automatic logic [6:0] dseed(input logic [5:0] ch);
    dseed = {1'b0, ch} | 7'h01;
  endfunction
  // receive-side access address / CRC init / whitening seed for the link state
  function automatic logic [31:0] aa_cur(input ls_t ls, input logic [31:0] caa);
    aa_cur = (ls == LS_CONN) ? caa : ADV_AA;
  endfunction
  function automatic logic [23:0] crci_cur(input ls_t ls, input logic [23:0] ci);
    crci_cur = (ls == LS_CONN) ? ci : ADV_CRCI;
  endfunction
  function automatic logic [6:0] wseed_cur(input ls_t ls, input logic [5:0] ch);
    wseed_cur = (ls == LS_CONN) ? dseed(ch) : ADV_WSEED;
  endfunction

  // ------------------------- RX engine --------------------------------------
  typedef enum logic [1:0] {RXS_AA, RXS_HDR, RXS_PAY, RXS_CRC} rxs_t;
  rxs_t        rxs;
  logic [30:0] aa_sh;                  // 31 latest bits (rxd is the 32nd)
  logic [6:0]  wlfsr_r;
  logic [23:0] crc_r;
  logic [22:0] crc_sh;                 // 23 latest CRC bits
  logic [6:0]  byte_sr;                // 7 latest bits of the current byte
  logic [2:0]  bit_cnt;
  logic [3:0]  byte_cnt;
  logic [4:0]  crc_bit_cnt, plen_r;
  logic [3:0]  hdr0_r;                 // PDU type / {sn,nesn,llid}
  logic [7:0]  rx_buf [0:15];
  logic        rx_done, rx_crc_ok, rx_long;

  logic        tx_act_r;
  wire         rx_en     = !tx_act_r;
  wire [31:0]  aa_sh_new = {rxd, aa_sh};
  wire         rx_db     = rxd ^ wlfsr_r[6];
  wire [7:0]   byte_new  = {rx_db, byte_sr};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxs         <= RXS_AA;
      aa_sh       <= 31'd0;
      wlfsr_r     <= 7'd0;
      crc_r       <= 24'd0;
      crc_sh      <= 23'd0;
      byte_sr     <= 7'd0;
      bit_cnt     <= 3'd0;
      byte_cnt    <= 4'd0;
      crc_bit_cnt <= 5'd0;
      plen_r      <= 5'd0;
      hdr0_r      <= 4'd0;
      rx_done     <= 1'b0;
      rx_crc_ok   <= 1'b0;
      rx_long     <= 1'b0;
      for (int i = 0; i < 16; i++) rx_buf[i] <= 8'h00;
    end else begin
      rx_done <= 1'b0;
      rx_long <= 1'b0;
      if (rx_en) begin
        aa_sh <= aa_sh_new[31:1];
        case (rxs)
          RXS_AA: begin
            if (aa_sh_new == aa_cur(ll_state, conn_aa)) begin
              wlfsr_r  <= wseed_cur(ll_state, dch);   // whitening starts after AA
              crc_r    <= crci_cur(ll_state, conn_crci);
              bit_cnt  <= 3'd0;
              byte_cnt <= 4'd0;
              rxs      <= RXS_HDR;
            end
          end
          RXS_HDR: begin               // 2 header bytes (de-whitened)
            wlfsr_r <= white_next(wlfsr_r);
            crc_r   <= crc24_bit(crc_r, rx_db);
            byte_sr <= byte_new[7:1];
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              if (byte_cnt == 4'd0) begin
                hdr0_r   <= byte_new[3:0];
                byte_cnt <= 4'd1;
              end else begin
                byte_cnt    <= 4'd0;
                crc_bit_cnt <= 5'd0;
                if (byte_new > 8'd16) begin
                  rx_long <= 1'b1;     // oversize len: drop packet + irq
                  rxs     <= RXS_AA;
                end else begin
                  plen_r <= byte_new[4:0];
                  rxs    <= (byte_new == 8'd0) ? RXS_CRC : RXS_PAY;
                end
              end
            end
          end
          RXS_PAY: begin               // plen_r payload bytes
            wlfsr_r <= white_next(wlfsr_r);
            crc_r   <= crc24_bit(crc_r, rx_db);
            byte_sr <= byte_new[7:1];
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              rx_buf[byte_cnt] <= byte_new;
              if (byte_cnt == 4'(plen_r - 5'd1)) begin
                byte_cnt <= 4'd0;
                rxs      <= RXS_CRC;
              end else byte_cnt <= byte_cnt + 4'd1;
            end
          end
          default: begin               // RXS_CRC: 24 CRC bits (whitened)
            wlfsr_r     <= white_next(wlfsr_r);
            crc_sh      <= {rx_db, crc_sh[22:1]};
            crc_bit_cnt <= crc_bit_cnt + 5'd1;
            if (crc_bit_cnt == 5'd23) begin
              rx_done   <= 1'b1;
              rx_crc_ok <= ({rx_db, crc_sh} == crc_r);
              rxs       <= RXS_AA;
            end
          end
        endcase
      end
    end
  end

  // ------------------------- TX engine --------------------------------------
  // Bytes are produced on the fly: [0] preamble, [1..4] AA, [5] hdr0,
  // [6] len, [7..] payload; then the 24 CRC bits. The CRC runs over the
  // header and payload bits as they are sent; whitening applies from
  // byte 5 on.
  typedef enum logic [1:0] {TK_ADV, TK_SCAN, TK_DATA} tk_t;
  typedef enum logic {TXS_IDLE, TXS_SEND} txs_t;
  txs_t        txs;
  tk_t         tk;
  logic [4:0]  t_byte;                 // byte index; 7 + len = CRC phase
  logic [2:0]  t_bit;
  logic [4:0]  t_crcbit;
  logic [23:0] t_crc;
  logic [6:0]  wlfsr_t;
  logic        t_sn, t_nesn;           // SN / NESN latched for the data PDU
  logic        txd_r;
  logic        adv_tx_req, scan_tx_req, data_tx_req; // owned by link FSM
  logic        gnt_adv, gnt_scan, gnt_data;          // pulses to link FSM

  // first byte index of the CRC phase (7 + payload length)
  function automatic logic [4:0] crc_start(input tk_t k);
    crc_start = (k == TK_DATA) ? 5'd7 : 5'd23;
  endfunction
  wire t_crcph = (t_byte == crc_start(tk));

  function automatic logic [7:0] tx_byte(input logic [4:0] i);
    logic [31:0] aa;
    aa = (tk == TK_DATA) ? conn_aa : ADV_AA;
    if (i == 5'd0)       tx_byte = aa[0] ? 8'h55 : 8'hAA;
    else if (i < 5'd5)   tx_byte = aa[8 * (i - 5'd1) +: 8];
    else if (i == 5'd5)  tx_byte = (tk == TK_DATA) ? {4'h0, t_sn, t_nesn, 2'b01}
                                 : (tk == TK_SCAN) ? {4'h0, PT_SCAN_RSP} : {4'h0, PT_ADV_IND};
    else if (i == 5'd6)  tx_byte = (tk == TK_DATA) ? 8'd0 : 8'd16;
    else if (tk == TK_ADV) tx_byte = adv_pay[4'(i - 5'd7)];
    else                 tx_byte = 8'h53 + {4'h0, 4'(i - 5'd7)};
  endfunction

  function automatic logic tx_bit(input logic [4:0] i, input logic [2:0] b);
    logic [7:0] by;
    by = tx_byte(i);
    tx_bit = by[b];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin : tx_seq
    logic cur_bit;
    if (!rst_n) begin
      txs      <= TXS_IDLE;
      tk       <= TK_ADV;
      t_byte   <= 5'd0;
      t_bit    <= 3'd0;
      t_crcbit <= 5'd0;
      t_crc    <= 24'd0;
      wlfsr_t  <= 7'd0;
      t_sn     <= 1'b0;
      t_nesn   <= 1'b0;
      txd_r    <= 1'b0;
      tx_act_r <= 1'b0;
      gnt_adv  <= 1'b0;
      gnt_scan <= 1'b0;
      gnt_data <= 1'b0;
    end else begin
      gnt_adv  <= 1'b0;
      gnt_scan <= 1'b0;
      gnt_data <= 1'b0;
      case (txs)
        TXS_IDLE: begin
          txd_r    <= 1'b0;
          tx_act_r <= 1'b0;
          t_byte   <= 5'd0;
          t_bit    <= 3'd0;
          t_crcbit <= 5'd0;
          if (data_tx_req) begin                 // empty data PDU (ack / keepalive)
            tk       <= TK_DATA;
            t_sn     <= tx_sn;
            t_nesn   <= rx_sn;
            t_crc    <= conn_crci;
            wlfsr_t  <= dseed(dch);
            gnt_data <= 1'b1;
            txs      <= TXS_SEND;
          end else if (scan_tx_req) begin        // SCAN_RSP, payload 8'h53+i
            tk       <= TK_SCAN;
            t_crc    <= ADV_CRCI;
            wlfsr_t  <= ADV_WSEED;
            gnt_scan <= 1'b1;
            txs      <= TXS_SEND;
          end else if (adv_tx_req) begin         // ADV_IND from register file
            tk       <= TK_ADV;
            t_crc    <= ADV_CRCI;
            wlfsr_t  <= ADV_WSEED;
            gnt_adv  <= 1'b1;
            txs      <= TXS_SEND;
          end
        end
        default: begin                           // TXS_SEND
          cur_bit  = t_crcph ? t_crc[t_crcbit] : tx_bit(t_byte, t_bit);
          tx_act_r <= 1'b1;                      // high exactly during the bits
          if (t_byte >= 5'd5) begin              // whitened region
            txd_r   <= cur_bit ^ wlfsr_t[6];
            wlfsr_t <= white_next(wlfsr_t);
          end else begin
            txd_r   <= cur_bit;
          end
          if (t_crcph) begin
            t_crcbit <= t_crcbit + 5'd1;
            if (t_crcbit == 5'd23) txs <= TXS_IDLE;   // tx_act_r falls next clk
          end else begin
            if (t_byte >= 5'd5) t_crc <= crc24_bit(t_crc, cur_bit);
            t_bit <= t_bit + 3'd1;
            if (t_bit == 3'd7) t_byte <= t_byte + 5'd1;
          end
        end
      endcase
    end
  end

  assign txd    = txd_r;
  assign tx_act = tx_act_r;

  // ------------------------- link layer FSM ---------------------------------
  logic err_pulse;

  // (ch + hop) mod 37, with ch < 37 and hop < 32
  function automatic logic [5:0] hop_ch(input logic [5:0] ch, input logic [4:0] hop);
    logic [6:0] s;
    s = {1'b0, ch} + {2'b00, hop};
    hop_ch = (s >= 7'd37) ? 6'(s - 7'd37) : s[5:0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ll_state       <= LS_ADV;
      conn_aa        <= 32'd0;
      conn_crci      <= 24'd0;
      conn_interval  <= 16'd1500;
      conn_latency   <= 16'd0;
      conn_timeout   <= 16'd0;
      hop_inc        <= 5'd0;
      dch            <= 6'd0;
      rx_sn          <= 1'b0;
      tx_sn          <= 1'b0;
      conn_timer     <= 16'd0;
      miss           <= 16'd0;
      rx_seen        <= 1'b0;
      adv_timer      <= '0;
      adv_tx_req     <= 1'b0;
      scan_tx_req    <= 1'b0;
      data_tx_req    <= 1'b0;
      err_pulse      <= 1'b0;
    end else begin
      err_pulse <= rx_long;                    // oversize length
      if (gnt_adv)  adv_tx_req  <= 1'b0;
      if (gnt_scan) scan_tx_req <= 1'b0;
      if (gnt_data) data_tx_req <= 1'b0;

      // advertising scheduler / connection events
      if (ll_state == LS_ADV) begin
        if (adv_timer >= ATW'(ADV_INTV)) begin
          adv_timer <= '0;
          if (adv_en) adv_tx_req <= 1'b1;
        end else adv_timer <= adv_timer + 1'b1;
      end else begin
        adv_timer <= '0;
        if (conn_timer >= conn_interval) begin  // connection event boundary
          conn_timer <= 16'd0;
          rx_seen    <= 1'b0;
          dch        <= hop_ch(dch, hop_inc);
          if (rx_seen) miss <= 16'd0;
          else if (conn_timeout != 16'd0 && miss + 16'd1 >= conn_timeout) begin
            ll_state    <= LS_ADV;             // supervision timeout
            data_tx_req <= 1'b0;
            err_pulse   <= 1'b1;
          end else begin
            miss <= miss + 16'd1;
            if (miss >= conn_latency) data_tx_req <= 1'b1;   // keepalive
          end
        end else conn_timer <= conn_timer + 16'd1;
      end

      // received packet processing
      if (rx_done) begin
        if (!rx_crc_ok) begin
          err_pulse <= 1'b1;                   // bad CRC: discard + irq
        end else if (ll_state == LS_ADV) begin
          case (hdr0_r[3:0])
            PT_SCAN_REQ: begin
              if (scan_en) scan_tx_req <= 1'b1;
            end
            PT_CONN_REQ: begin                 // simplified LLData
              if (plen_r == 5'd15) begin
                conn_aa       <= {rx_buf[3], rx_buf[2], rx_buf[1], rx_buf[0]};
                conn_crci     <= {rx_buf[6], rx_buf[5], rx_buf[4]};
                conn_interval <= {rx_buf[8], rx_buf[7]};
                conn_latency  <= {rx_buf[10], rx_buf[9]};
                conn_timeout  <= {rx_buf[12], rx_buf[11]};
                hop_inc       <= rx_buf[13][4:0];
                dch           <= (rx_buf[14][5:0] >= 6'd37) ? 6'(rx_buf[14][5:0] - 6'd37)
                                                            : rx_buf[14][5:0];
                rx_sn         <= 1'b0;
                tx_sn         <= 1'b0;
                conn_timer    <= 16'd0;
                miss          <= 16'd0;
                rx_seen       <= 1'b0;
                adv_tx_req    <= 1'b0;
                scan_tx_req   <= 1'b0;
                ll_state      <= LS_CONN;
              end else err_pulse <= 1'b1;      // wrong LLData length
            end
            PT_ADV_IND, PT_ADV_DIRECT, PT_ADV_NONC, PT_SCAN_RSP, PT_ADV_SCAN:
              ;                                 // known advertising PDUs: ignore
            default: err_pulse <= 1'b1;         // unknown PDU type: drop + irq
          endcase
        end else begin                         // LS_CONN: data channel PDU
          rx_seen <= 1'b1;
          if (hdr0_r[1:0] == 2'b00) begin
            err_pulse <= 1'b1;                 // reserved LLID
          end else begin
            if (hdr0_r[3] == rx_sn) rx_sn <= ~rx_sn;   // new packet: ack it
            if (hdr0_r[2] != tx_sn) tx_sn <= ~tx_sn;   // our last PDU acked
            data_tx_req <= 1'b1;               // empty PDU response (ack)
          end
        end
      end
    end
  end

  // ------------------------- interrupt ---------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else        irq <= err_pulse;
  end

endmodule
