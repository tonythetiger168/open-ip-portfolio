// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Bluetooth 5 (BLE) link layer peripheral -- synthesizable baseband model
//
// Implementation scope (simplified, NOT the full BLE LL specification):
//  - Air interface: 1 bit/clk, LSB-first per byte (BLE over-the-air order).
//  - Advertising channel 37: preamble 8'hAA + AccessAddress 32'h8E89BED6 +
//    PDU header {type[3:0],rfu[3:0],len[7:0]} + payload + CRC24
//    (serial LFSR, poly 24'h00065B, init 24'h555555).
//  - Data whitening: LFSR poly x^7+x^4+1 (out = l[6], l <<= l[6]^l[3]),
//    seed = channel_index | 1 (adv ch37 -> 7'h25); applied to everything
//    after the AccessAddress (header + payload + CRC).
//  - ADV_IND transmitted every ADV_INTV clks (payload = 16x8 host-writable
//    register file).  Valid SCAN_REQ -> SCAN_RSP (payload[i] = 8'h53+i).
//  - Valid CONNECT_REQ -> parse simplified LLData (15 bytes: AA[4],
//    CRCInit[3], interval[2], latency[2], timeout[2], hop[1], chmap[1]) ->
//    stored in registers, CONNECTION state on the new AA.  Hop increment is
//    stored but channel hopping is simplified to a fixed data channel
//    (chmap mod 37), noted.
//  - Data channel PDU: LL header {llid[1:0],sn,nesn,md,rfu[2:0]} + len[4:0]
//    + payload (<=16B) + CRC24 (init = CRCInit).  NESN/SN toggle management;
//    every valid master PDU gets an empty-PDU response (ack); an empty PDU
//    keepalive is sent each connection interval without master traffic.
//  - Unknown advertising PDU type / bad CRC24 -> packet discarded + irq.
//  - llid 2'b00 reserved -> protocol error + irq.  len > 16 -> drop + irq.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module Bluetooth5_top #(
  parameter int DW = 32,             // kept for framework compatibility
  parameter int AW = 32,             // kept for framework compatibility
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
  // whitening LFSR: poly x^7+x^4+1, serial out = l[6]
  function automatic logic [6:0] white_next(input logic [6:0] l);
    white_next = {l[5:0], l[6] ^ l[3]};
  endfunction

  // CRC24 serial LFSR (poly 24'h00065B), one bit per call, LSB-first
  function automatic logic [23:0] crc24_bit(input logic [23:0] crc,
                                            input logic        b);
    logic fb;
    begin
      fb        = crc[0] ^ b;
      crc24_bit = fb ? ((crc >> 1) ^ 24'h00065B) : (crc >> 1);
    end
  endfunction

  function automatic logic [23:0] crc24_byte(input logic [23:0] crc,
                                             input logic [7:0]  d);
    logic [23:0] c;
    begin
      c = crc;
      for (int i = 0; i < 8; i++) c = crc24_bit(c, d[i]);
      crc24_byte = c;
    end
  endfunction

  // ------------------------- host config / adv payload ----------------------
  logic [7:0] adv_pay [0:15];
  logic       adv_en, scan_en;

  integer hc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      adv_en  <= 1'b1;
      scan_en <= 1'b1;
      for (hc = 0; hc < 16; hc = hc + 1) adv_pay[hc] <= 8'hB0 + hc[7:0];
    end else if (cfg_we) begin
      if (cfg_addr < 5'd16)      adv_pay[cfg_addr[3:0]] <= cfg_wdata;
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
  logic [5:0]  dch;                    // data channel index (fixed, hop stored)
  logic        rx_sn, tx_sn;           // NESN/SN state
  logic        rsp_sn, rsp_nesn;       // response PDU fields (captured)
  logic [15:0] conn_timer;
  logic        rx_seen;                // master traffic this interval
  logic [11:0] adv_timer;

  // ------------------------- RX engine --------------------------------------
  typedef enum logic [2:0] {RXS_AA, RXS_HDR, RXS_PAY, RXS_CRC} rxs_t;
  rxs_t        rxs;
  logic [31:0] aa_sh;
  logic [6:0]  wlfsr_r;
  logic [23:0] crc_r, crc_sh;
  logic [7:0]  byte_sr;
  logic [2:0]  bit_cnt;
  logic [4:0]  byte_cnt, crc_bit_cnt, plen_r;
  logic [7:0]  hdr0_r;
  logic [7:0]  rx_buf [0:15];
  logic        rx_done, rx_crc_ok;

  logic [31:0] aa_cur;
  logic [23:0] crci_cur;
  logic [6:0]  wseed_cur;
  logic        rx_en;
  logic [31:0] aa_sh_new;
  logic        rx_db;                  // de-whitened bit
  logic [7:0]  byte_new;               // completed byte (LSB-first)
  assign aa_cur    = (ll_state == LS_CONN) ? conn_aa : ADV_AA;
  assign crci_cur  = (ll_state == LS_CONN) ? conn_crci : ADV_CRCI;
  assign wseed_cur = (ll_state == LS_CONN) ? ({1'b0, dch} | 7'h01) : ADV_WSEED;
  assign rx_en     = !tx_act;
  assign aa_sh_new = {rxd, aa_sh[31:1]};
  assign rx_db     = rxd ^ wlfsr_r[6];
  assign byte_new  = {rx_db, byte_sr[7:1]};

  integer rb;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxs         <= RXS_AA;
      aa_sh       <= 32'd0;
      wlfsr_r     <= 7'd0;
      crc_r       <= 24'd0;
      crc_sh      <= 24'd0;
      byte_sr     <= 8'd0;
      bit_cnt     <= 3'd0;
      byte_cnt    <= 5'd0;
      crc_bit_cnt <= 5'd0;
      plen_r      <= 5'd0;
      hdr0_r      <= 8'd0;
      rx_done     <= 1'b0;
      rx_crc_ok   <= 1'b0;
    end else begin
      rx_done <= 1'b0;
      if (rx_en) begin
        aa_sh <= aa_sh_new;
        case (rxs)
          RXS_AA: begin
            if (aa_sh_new == aa_cur) begin
              wlfsr_r  <= wseed_cur;   // whitening starts after AA
              crc_r    <= crci_cur;
              bit_cnt  <= 3'd0;
              byte_cnt <= 5'd0;
              rxs      <= RXS_HDR;
            end
          end
          RXS_HDR: begin               // 2 header bytes (de-whitened)
            wlfsr_r <= white_next(wlfsr_r);
            crc_r   <= crc24_bit(crc_r, rx_db);
            byte_sr <= byte_new;
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              bit_cnt <= 3'd0;
              if (byte_cnt == 5'd0) begin
                hdr0_r   <= byte_new;
                byte_cnt <= 5'd1;
              end else begin
                byte_cnt <= 5'd0;
                if ((ll_state == LS_CONN) ? (byte_new[4:0] > 5'd16)
                                         : (byte_new > 8'd16)) begin
                  rxs <= RXS_AA;       // oversize len: drop packet
                end else begin
                  plen_r <= (ll_state == LS_CONN) ? byte_new[4:0]
                                                  : byte_new[4:0];
                  rxs    <= ((ll_state == LS_CONN) ? (byte_new[4:0] == 5'd0)
                                                  : (byte_new == 8'd0))
                            ? RXS_CRC : RXS_PAY;
                end
              end
            end
          end
          RXS_PAY: begin               // plen_r payload bytes
            wlfsr_r <= white_next(wlfsr_r);
            crc_r   <= crc24_bit(crc_r, rx_db);
            byte_sr <= byte_new;
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              bit_cnt          <= 3'd0;
              rx_buf[byte_cnt[3:0]] <= byte_new;
              if (byte_cnt == plen_r - 5'd1) begin
                byte_cnt    <= 5'd0;
                crc_bit_cnt <= 5'd0;
                rxs         <= RXS_CRC;
              end else byte_cnt <= byte_cnt + 5'd1;
            end
          end
          RXS_CRC: begin               // 24 CRC bits (whitened)
            wlfsr_r    <= white_next(wlfsr_r);
            crc_sh     <= {rx_db, crc_sh[23:1]};
            crc_bit_cnt <= crc_bit_cnt + 5'd1;
            if (crc_bit_cnt == 5'd23) begin
              rx_done   <= 1'b1;
              rx_crc_ok <= ({rx_db, crc_sh[23:1]} == crc_r);
              rxs       <= RXS_AA;
            end
          end
          default: rxs <= RXS_AA;
        endcase
      end
    end
  end

  // ------------------------- TX engine --------------------------------------
  // Packet layout in tx_buf: [0] preamble, [1..4] AA, [5] hdr0, [6] hdr1,
  // [7..] payload, then 3 CRC bytes.  Whitening applies from index 5 on.
  typedef enum logic {TXS_IDLE, TXS_SEND} txs_t;
  txs_t        txs;
  logic [7:0]  tx_buf [0:31];
  logic [9:0]  tx_bits, tx_cnt;
  logic [6:0]  wlfsr_t;
  logic        txd_r, tx_act_r;
  logic        adv_tx_req, scan_tx_req, data_tx_req; // owned by link FSM
  logic        gnt_adv, gnt_scan, gnt_data;          // pulses to link FSM

  logic [7:0]  cur_byte;
  logic        cur_bit;
  assign cur_byte = tx_buf[tx_cnt[7:3]];
  assign cur_bit  = cur_byte[tx_cnt[2:0]];

  logic [23:0] bc;                     // build-time CRC scratch
  integer      bi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      txs      <= TXS_IDLE;
      tx_bits  <= 10'd0;
      tx_cnt   <= 10'd0;
      wlfsr_t  <= 7'd0;
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
          if (data_tx_req) begin                 // empty data PDU (ack/keepalive)
            tx_buf[0] <= 8'hAA;
            tx_buf[1] <= conn_aa[7:0];
            tx_buf[2] <= conn_aa[15:8];
            tx_buf[3] <= conn_aa[23:16];
            tx_buf[4] <= conn_aa[31:24];
            tx_buf[5] <= {3'b000, 1'b0, rsp_nesn, rsp_sn, 2'b01};
            tx_buf[6] <= 8'd0;
            bc = crc24_byte(conn_crci, {3'b000, 1'b0, rsp_nesn, rsp_sn, 2'b01});
            bc = crc24_byte(bc, 8'd0);
            tx_buf[7] <= bc[7:0];
            tx_buf[8] <= bc[15:8];
            tx_buf[9] <= bc[23:16];
            tx_bits  <= 10'd80;                  // 10 bytes
            tx_cnt   <= 10'd0;
            wlfsr_t  <= {1'b0, dch} | 7'h01;
            gnt_data <= 1'b1;
            txs      <= TXS_SEND;
          end else if (scan_tx_req) begin        // SCAN_RSP, payload 8'h53+i
            tx_buf[0] <= 8'hAA;
            tx_buf[1] <= ADV_AA[7:0];
            tx_buf[2] <= ADV_AA[15:8];
            tx_buf[3] <= ADV_AA[23:16];
            tx_buf[4] <= ADV_AA[31:24];
            tx_buf[5] <= {4'd0, PT_SCAN_RSP};
            tx_buf[6] <= 8'd16;
            for (bi = 0; bi < 16; bi = bi + 1) tx_buf[7+bi] <= 8'h53 + bi[7:0];
            bc = crc24_byte(ADV_CRCI, {4'd0, PT_SCAN_RSP});
            bc = crc24_byte(bc, 8'd16);
            for (bi = 0; bi < 16; bi = bi + 1)
              bc = crc24_byte(bc, 8'h53 + bi[7:0]);
            tx_buf[23] <= bc[7:0];
            tx_buf[24] <= bc[15:8];
            tx_buf[25] <= bc[23:16];
            tx_bits  <= 10'd208;                 // 26 bytes
            tx_cnt   <= 10'd0;
            wlfsr_t  <= ADV_WSEED;
            gnt_scan <= 1'b1;
            txs      <= TXS_SEND;
          end else if (adv_tx_req) begin         // ADV_IND from register file
            tx_buf[0] <= 8'hAA;
            tx_buf[1] <= ADV_AA[7:0];
            tx_buf[2] <= ADV_AA[15:8];
            tx_buf[3] <= ADV_AA[23:16];
            tx_buf[4] <= ADV_AA[31:24];
            tx_buf[5] <= {4'd0, PT_ADV_IND};
            tx_buf[6] <= 8'd16;
            for (bi = 0; bi < 16; bi = bi + 1) tx_buf[7+bi] <= adv_pay[bi];
            bc = crc24_byte(ADV_CRCI, {4'd0, PT_ADV_IND});
            bc = crc24_byte(bc, 8'd16);
            for (bi = 0; bi < 16; bi = bi + 1)
              bc = crc24_byte(bc, adv_pay[bi]);
            tx_buf[23] <= bc[7:0];
            tx_buf[24] <= bc[15:8];
            tx_buf[25] <= bc[23:16];
            tx_bits  <= 10'd208;
            tx_cnt   <= 10'd0;
            wlfsr_t  <= ADV_WSEED;
            gnt_adv  <= 1'b1;
            txs      <= TXS_SEND;
          end
        end
        TXS_SEND: begin
          tx_act_r <= 1'b1;                      // high exactly during payload bits
          if (tx_cnt[7:3] >= 5'd5) begin         // whitened region
            txd_r   <= cur_bit ^ wlfsr_t[6];
            wlfsr_t <= white_next(wlfsr_t);
          end else begin
            txd_r   <= cur_bit;
          end
          if (tx_cnt == tx_bits - 10'd1) begin
            tx_cnt <= 10'd0;
            txs    <= TXS_IDLE;                  // tx_act_r falls next clk
          end else tx_cnt <= tx_cnt + 10'd1;
        end
        default: txs <= TXS_IDLE;
      endcase
    end
  end

  assign txd    = txd_r;
  assign tx_act = tx_act_r;

  // ------------------------- link layer FSM ---------------------------------
  logic        crc_err_pulse, proto_err_pulse;
  logic [15:0] crc_err_cnt;
  logic        rx_evt;                   // new data payload accepted
  logic [4:0]  rx_dlen;
  logic [15:0] rx_evt_cnt;

  integer lj;
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
      rsp_sn         <= 1'b0;
      rsp_nesn       <= 1'b0;
      conn_timer     <= 16'd0;
      rx_seen        <= 1'b0;
      adv_timer      <= 12'd0;
      adv_tx_req     <= 1'b0;
      scan_tx_req    <= 1'b0;
      data_tx_req    <= 1'b0;
      crc_err_pulse  <= 1'b0;
      proto_err_pulse<= 1'b0;
      crc_err_cnt    <= 16'd0;
      rx_evt         <= 1'b0;
      rx_dlen        <= 5'd0;
      rx_evt_cnt     <= 16'd0;
    end else begin
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      rx_evt          <= 1'b0;
      if (gnt_adv)  adv_tx_req  <= 1'b0;
      if (gnt_scan) scan_tx_req <= 1'b0;
      if (gnt_data) data_tx_req <= 1'b0;

      // advertising scheduler
      if (ll_state == LS_ADV) begin
        if (adv_timer >= ADV_INTV[11:0]) begin
          adv_timer <= 12'd0;
          if (adv_en) adv_tx_req <= 1'b1;
        end else adv_timer <= adv_timer + 12'd1;
      end else begin
        adv_timer <= 12'd0;
        // connection event timer -> empty PDU keepalive
        if (conn_timer >= conn_interval) begin
          conn_timer <= 16'd0;
          if (!rx_seen) data_tx_req <= 1'b1;
          rx_seen <= 1'b0;
        end else conn_timer <= conn_timer + 16'd1;
      end

      // received packet processing
      if (rx_done) begin
        if (!rx_crc_ok) begin
          crc_err_pulse <= 1'b1;               // bad CRC: discard + irq
          crc_err_cnt   <= crc_err_cnt + 16'd1;
        end else if (ll_state == LS_ADV) begin
          case (hdr0_r[3:0])
            PT_SCAN_REQ: begin
              if (scan_en) scan_tx_req <= 1'b1;
            end
            PT_CONN_REQ: begin                 // parse simplified LLData
              conn_aa       <= {rx_buf[3], rx_buf[2], rx_buf[1], rx_buf[0]};
              conn_crci     <= {rx_buf[6], rx_buf[5], rx_buf[4]};
              conn_interval <= {rx_buf[8], rx_buf[7]};
              conn_latency  <= {rx_buf[10], rx_buf[9]};
              conn_timeout  <= {rx_buf[12], rx_buf[11]};
              hop_inc       <= rx_buf[13][4:0];
              dch           <= (rx_buf[14][5:0] >= 6'd37) ?
                               (rx_buf[14][5:0] - 6'd37) : rx_buf[14][5:0];
              rx_sn         <= 1'b0;
              tx_sn         <= 1'b0;
              rsp_sn        <= 1'b0;
              rsp_nesn      <= 1'b0;
              conn_timer    <= 16'd0;
              rx_seen       <= 1'b0;
              adv_tx_req    <= 1'b0;
              scan_tx_req   <= 1'b0;
              ll_state      <= LS_CONN;
            end
            PT_ADV_IND, PT_ADV_DIRECT, PT_ADV_NONC, PT_SCAN_RSP, PT_ADV_SCAN:
              ;                                 // known advertising PDUs: ignore
            default: proto_err_pulse <= 1'b1;   // unknown PDU type: drop + irq
          endcase
        end else begin                         // LS_CONN: data channel PDU
          rx_seen <= 1'b1;
          if (hdr0_r[1:0] == 2'b00) begin
            proto_err_pulse <= 1'b1;           // reserved LLID
          end else begin
            // NESN/SN management: response carries ack of this packet
            // (post-toggle rx_sn) and current tx_sn (pre-toggle)
            rsp_nesn <= (hdr0_r[2] == rx_sn) ? ~rx_sn : rx_sn;
            rsp_sn   <= tx_sn;
            if (hdr0_r[2] == rx_sn) begin      // new packet
              rx_sn <= ~rx_sn;
              if (plen_r > 5'd0 && hdr0_r[1:0] != 2'b11) begin
                rx_evt     <= 1'b1;
                rx_dlen    <= plen_r;
                rx_evt_cnt <= rx_evt_cnt + 16'd1;
              end
            end
            if (hdr0_r[3] != tx_sn) tx_sn <= ~tx_sn; // peer acked our packet
            data_tx_req <= 1'b1;               // empty PDU response (ack)
          end
        end
      end
    end
  end

  // ------------------------- interrupt ---------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else        irq <= crc_err_pulse | proto_err_pulse;
  end

endmodule
