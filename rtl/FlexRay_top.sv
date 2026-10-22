// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// FlexRay_top v2.0: FlexRay 3.0.1 communication controller, single channel,
// static segment
// ----------------------------------------------------------------------------
//  - Coding (spec ch. 3): TSS (cfg_tss LOW bits), FSS (HIGH), every byte as
//    BSS (HIGH, LOW) + 8 bits MSB first, FES (LOW, HIGH). txd/tx_en drive
//    the transceiver (tx_en = 1 while sending); idle bus reads HIGH.
//  - Decoding: 8 samples per bit (cfg_spc+1 clocks per sample), majority
//    vote over the last 5 samples, bit strobe at sample 5; the sample counter
//    is set to 2 at the falling edge of the voted signal at the start of the
//    TSS and in every BSS. Channel idle: 11 consecutive HIGH bits. Accepted
//    TSS: 1 .. cfg_tss+1 LOW bits; a LOW pulse shorter than a bit is ignored.
//  - Frame (spec ch. 4): 40-bit header {reserved, payload preamble, null
//    frame indicator (0 = null frame), sync, startup, frame ID[10:0],
//    payload length[6:0] (2-byte words), header CRC[10:0], cycle count[5:0]},
//    payload, 24-bit frame CRC. Header CRC x^11+x^9+x^8+x^7+x^2+1, init
//    0x01A, over sync, startup, ID and length. Frame CRC 0x5D6DCB, init
//    0xFEDCBA (channel A) or 0xABCDEF (cfg_chan_b), over header and payload.
//  - Timing: macrotick = 1 bit. Cycle = cfg_nslots static slots of cfg_slot
//    bits, then cfg_nit bits network idle time; cycle count 0..63. A node
//    sends one frame per cycle in slot cfg_my_slot, starting cfg_ap bits
//    into the slot: the queued tx_data (null frame indicator 1) or, with
//    nothing queued, a null frame. Payload length cfg_plen words; bytes past
//    tx_data[127:0] are sent as 0.
//  - Synchronisation: a coldstart node (cfg_cold) runs its own schedule from
//    reset and is the time master. Any other node integrates on the first
//    valid sync frame (ID 1..cfg_nslots): it takes slot = ID and the cycle
//    count, and sets its slot timer from the time of the frame's first BSS
//    edge. Every later sync frame re-phases it the same way (offset
//    correction); a correction beyond cfg_corr clocks, or a cycle without a
//    sync frame, loses synchronisation (err_sync).
//  - Received frames (own transmissions are ignored): rx_valid with the
//    header fields (rx_id: ID[5:0], always the slot number) and the first
//    16 payload bytes (byte 0 in bits 7:0) when synchronised and the frame
//    carries this slot's ID and cycle count;
//    otherwise err_slot. err_coding: a bit not as the coding requires;
//    err_hcrc / err_fcrc: header / frame CRC. Before integration only sync
//    frames are used.
//  Not implemented: dynamic segment, symbol window (CAS/MTS, WUS), wakeup,
//  startup with several coldstart nodes, rate correction, second channel,
//  bus guardian.
// ============================================================================
module FlexRay_top (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         rxd,
  output logic         txd,
  output logic         tx_en,
  // configuration (static while the cluster runs)
  input  logic [3:0]   cfg_spc,       // clocks per sample - 1 (bit = 8 samples)
  input  logic [3:0]   cfg_tss,       // TSS length in bits (3..15)
  input  logic [9:0]   cfg_slot,      // static slot length in bits
  input  logic [5:0]   cfg_ap,        // action point offset in bits
  input  logic [5:0]   cfg_nslots,    // static slots per cycle (1..63)
  input  logic [9:0]   cfg_nit,       // network idle time in bits
  input  logic [3:0]   cfg_plen,      // payload length of own frames, words
  input  logic [5:0]   cfg_my_slot,   // own slot, 0 = none
  input  logic         cfg_sync,      // own frames are sync frames
  input  logic         cfg_cold,      // coldstart node / time master
  input  logic         cfg_chan_b,    // frame CRC init of channel B
  input  logic [7:0]   cfg_corr,      // largest offset correction, clocks
  // transmit buffer
  input  logic         tx_valid,
  output logic         tx_ready,
  input  logic [127:0] tx_data,
  output logic         tx_done,
  // received frames
  output logic         rx_valid,
  output logic [5:0]   rx_id,
  output logic [5:0]   rx_cycle,
  output logic [6:0]   rx_len,
  output logic         rx_null,
  output logic         rx_sync,
  output logic         rx_startup,
  output logic [127:0] rx_data,
  // status
  output logic         synced,
  output logic [5:0]   cycle,
  output logic [5:0]   slot,          // 0 = network idle time
  output logic         cycle_start,
  output logic         err_coding,
  output logic         err_hcrc,
  output logic         err_fcrc,
  output logic         err_slot,
  output logic         err_sync
);
  function automatic logic [10:0] hcrc_of(input logic [19:0] d);
    logic [10:0] c;
    c = 11'h01A;
    for (int i = 19; i >= 0; i--)
      c = {c[9:0], 1'b0} ^ ((d[i] ^ c[10]) ? 11'h385 : 11'h000);
    hcrc_of = c;
  endfunction
  function automatic logic [23:0] fcrc_next(input logic [23:0] c, input logic b);
    fcrc_next = {c[22:0], 1'b0} ^ ((b ^ c[23]) ? 24'h5D6DCB : 24'h000000);
  endfunction

  wire [4:0]  spc1 = {1'b0, cfg_spc} + 5'd1;           // clocks per sample

  // ---------------- input synchroniser, sampling, voting ----------------
  logic       rx_m, rx_s;
  logic [3:0] pre;
  logic [3:0] vsh;                     // previous four samples
  logic       v_q;                     // voted value
  logic [2:0] scnt;                    // sample number in the bit - 1
  wire        tick = pre == cfg_spc;
  wire        v_n  = (vsh[0] & vsh[1] & (vsh[2] | vsh[3] | rx_s)) | (vsh[0] & vsh[2] & (vsh[3] | rx_s))
                   | (vsh[0] & vsh[3] & rx_s) | (vsh[1] & vsh[2] & (vsh[3] | rx_s)) | (vsh[1] & vsh[3] & rx_s)
                   | (vsh[2] & vsh[3] & rx_s);          // 3 of 5
  wire        v_fall = tick && v_q && !v_n;
  logic       rs_en;                   // resynchronise at a falling edge
  wire [2:0]  scnt_n = (v_fall && rs_en) ? 3'd1 : scnt + 3'd1;
  wire        strobe = tick && scnt_n == 3'd4;          // sample 5
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rx_m <= 1'b1; rx_s <= 1'b1; pre <= '0; vsh <= 4'hF; v_q <= 1'b1; scnt <= '0;
    end else begin
      rx_m <= rxd; rx_s <= rx_m;
      pre  <= tick ? 4'd0 : pre + 4'd1;
      if (tick) begin vsh <= {vsh[2:0], rx_s}; v_q <= v_n; scnt <= scnt_n; end
    end

  // ---------------- time base ----------------
  logic [16:0] sc;                      // clocks into the slot / NIT
  // lengths in samples (x8 = clocks)
  wire  [13:0] seg_s   = (slot == 6'd0 ? {4'd0, cfg_nit} : {4'd0, cfg_slot}) * {9'd0, spc1};
  wire         seg_end = {1'b0, sc} + 18'd1 >= {1'b0, seg_s, 3'b000};
  wire  [9:0]  ap_s    = cfg_ap * {5'd0, spc1};
  logic        got_sync;                // a sync frame used in this cycle

  // ---------------- decoder ----------------
  typedef enum logic [2:0] {D_WIDLE, D_IDLE, D_TSS, D_BSS1, D_BSS2, D_DATA, D_FES1, D_FES2} dst_t;
  dst_t        dst;
  logic [3:0]  idle_cnt;                // HIGH bits towards channel idle
  logic [4:0]  tss_cnt;
  logic [8:0]  bi;                      // byte index
  logic [2:0]  bk;                      // bit in the byte
  logic [6:0]  sh8;
  logic [37:0] hdr;                     // header without reserved and preamble bits
  logic [127:0] rdat;
  logic [23:0] rcrc, rcrc_rx;
  logic        own;                     // our own transmission
  logic [5:0]  slot_s, cyc_s;           // slot and cycle at frame start
  logic [16:0] e_cnt;                   // clocks since the first BSS edge (saturates)
  wire  [6:0]  hlen   = hdr[23:17];
  wire  [7:0]  byte_n = {sh8[6:0], v_n};
  wire  [10:0] f_id   = hdr[34:24];
  // expected slot timer at the first BSS edge of a frame sent at the action
  // point: TSS + FSS + 1st BSS bit, plus the receive path (2 flops, 3 samples)
  wire  [10:0] exp_s    = {1'b0, ap_s} + ({6'd0, cfg_tss} + 11'd2) * {6'd0, spc1};
  wire  [13:0] exp_edge = {exp_s, 3'b000} + 14'd3 + {8'd0, spc1, 1'b0} + {11'd0, cfg_spc[3:1]};
  wire  [17:0] sc_new   = {4'd0, exp_edge} + {1'b0, e_cnt} + 18'd1;
  wire  [17:0] corr     = sc_new >= {1'b0, sc} + 18'd1 ? sc_new - {1'b0, sc} - 18'd1
                                                       : {1'b0, sc} + 18'd1 - sc_new;
  always_comb begin
    rs_en = dst == D_IDLE || dst == D_BSS2;
  end

  // ---------------- encoder ----------------
  typedef enum logic [2:0] {T_IDLE, T_TSS, T_FSS, T_BSS1, T_BSS2, T_DATA, T_FES1, T_FES2} tst_t;
  tst_t        tst;
  logic [6:0]  t_bc;                    // clocks in the bit
  logic [3:0]  t_k;                     // TSS bit / data bit
  logic [5:0]  t_i;                     // byte index
  logic [28:0] f_hdr;                   // {sync, startup, slot, length, header CRC, cycle}
  logic [127:0] f_data;
  logic        f_nfi;
  logic [23:0] t_crc;
  logic        tb_full;
  logic [127:0] tb_data;
  wire         t_end  = {1'b0, t_bc} == {spc1, 3'b000} - 8'd1;
  wire  [4:0]  t_ph   = {1'b0, cfg_plen} + 5'd2;          // {t_ph, 1}: first byte after the payload
  logic [7:0]  t_byte;
  always_comb begin
    case (t_i)
      6'd0: t_byte = {2'b00, f_nfi, f_hdr[28:27], 3'b000};          // reserved, preamble, ID[10:8]
      6'd1: t_byte = {2'b00, f_hdr[26:21]};                         // ID[7:0]
      6'd2: t_byte = {3'b000, f_hdr[20:17], f_hdr[16]};             // length, header CRC[10]
      6'd3: t_byte = f_hdr[15:8];
      6'd4: t_byte = {f_hdr[7:6], f_hdr[5:0]};
      default:
        if (t_i < {t_ph, 1'b1}) t_byte = (t_i < 6'd21) ? f_data[{t_i[3:0] - 4'd5, 3'b000} +: 8] : 8'h00;
        else if (t_i == {t_ph, 1'b1}) t_byte = t_crc[23:16];
        else if (t_i == {t_ph, 1'b1} + 6'd1) t_byte = t_crc[15:8];
        else t_byte = t_crc[7:0];
    endcase
  end
  wire         t_start = synced && slot != 6'd0 && slot == cfg_my_slot && sc == {4'd0, ap_s, 3'b000}
                         && tst == T_IDLE;
  wire [10:0]  t_hcrc = hcrc_of({cfg_sync, cfg_sync & cfg_cold, 5'd0, cfg_my_slot, 3'd0, cfg_plen});

  assign tx_ready = !tb_full;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sc <= '0; slot <= '0; cycle <= '0; synced <= 1'b0; got_sync <= 1'b0; cycle_start <= 1'b0;
      dst <= D_WIDLE; idle_cnt <= '0; tss_cnt <= '0; bi <= '0; bk <= '0; sh8 <= '0; hdr <= '0;
      rdat <= '0; rcrc <= '0; rcrc_rx <= '0; own <= 1'b0; slot_s <= '0; cyc_s <= '0; e_cnt <= '0;
      rx_valid <= 1'b0; rx_id <= '0; rx_cycle <= '0; rx_len <= '0; rx_null <= 1'b0; rx_sync <= 1'b0;
      rx_startup <= 1'b0; rx_data <= '0;
      err_coding <= 1'b0; err_hcrc <= 1'b0; err_fcrc <= 1'b0; err_slot <= 1'b0; err_sync <= 1'b0;
      tst <= T_IDLE; t_bc <= '0; t_k <= '0; t_i <= '0; f_hdr <= '0; f_data <= '0; f_nfi <= 1'b0;
      t_crc <= '0; tb_full <= 1'b0; tb_data <= '0; txd <= 1'b1; tx_en <= 1'b0; tx_done <= 1'b0;
    end else begin
      cycle_start <= 1'b0; rx_valid <= 1'b0; tx_done <= 1'b0;
      err_coding <= 1'b0; err_hcrc <= 1'b0; err_fcrc <= 1'b0; err_slot <= 1'b0; err_sync <= 1'b0;
      if (e_cnt != 17'h1FFFF) e_cnt <= e_cnt + 17'd1;

      // ---------------- time base
      if (cfg_cold && !synced) begin                       // time master: start at once
        synced <= 1'b1; slot <= 6'd1; cycle <= '0; sc <= '0; cycle_start <= 1'b1;
      end else if (synced) begin
        if (seg_end) begin
          sc <= '0;
          if (slot == 6'd0) begin
            slot <= 6'd1; cycle <= cycle + 6'd1; cycle_start <= 1'b1; got_sync <= 1'b0;
            if (!cfg_cold && !got_sync) begin synced <= 1'b0; err_sync <= 1'b1; end
          end else if (slot >= cfg_nslots) slot <= 6'd0;
          else slot <= slot + 6'd1;
        end else sc <= sc + 17'd1;
      end

      // ---------------- decoder
      if (tick) begin
        case (dst)
          D_WIDLE: if (strobe) begin
            if (!v_n) idle_cnt <= '0;
            else if (idle_cnt == 4'd10) begin idle_cnt <= '0; dst <= D_IDLE; end
            else idle_cnt <= idle_cnt + 4'd1;
          end
          D_IDLE: if (v_fall) begin
            dst <= D_TSS; tss_cnt <= '0; own <= tx_en; slot_s <= slot; cyc_s <= cycle;
          end
          D_TSS: if (strobe) begin
            if (v_n) begin
              if (tss_cnt == 5'd0) dst <= D_IDLE;                 // glitch: no TSS
              else begin dst <= D_BSS1; bi <= '0; rcrc <= cfg_chan_b ? 24'hABCDEF : 24'hFEDCBA; end   // FSS
            end else if (tss_cnt == {1'b0, cfg_tss} + 5'd1) begin dst <= D_WIDLE; err_coding <= !own; end
            else tss_cnt <= tss_cnt + 5'd1;
          end
          D_BSS1: if (strobe) begin
            if (v_n) dst <= D_BSS2;
            else begin dst <= D_WIDLE; err_coding <= !own; end
          end
          D_BSS2: begin
            if (v_fall && bi == 9'd0) e_cnt <= '0;
            if (strobe) begin
              if (!v_n) begin dst <= D_DATA; bk <= '0; end
              else begin dst <= D_WIDLE; err_coding <= !own; end
            end
          end
          D_DATA: if (strobe) begin
            sh8 <= byte_n[6:0];
            bk  <= bk + 3'd1;
            if (bi < 9'd5 + {1'b0, hlen, 1'b0}) rcrc <= fcrc_next(rcrc, v_n);
            if (bk == 3'd7) begin
              if (bi < 9'd5) hdr <= {hdr[29:0], byte_n};
              else if (bi < 9'd5 + {1'b0, hlen, 1'b0}) begin
                if (bi < 9'd21) rdat[{bi[3:0] - 4'd5, 3'b000} +: 8] <= byte_n;
              end else rcrc_rx <= {rcrc_rx[15:0], byte_n};
              bi  <= bi + 9'd1;
              dst <= (bi >= 9'd7 && bi == {8'(hlen) + 8'd3, 1'b1}) ? D_FES1 : D_BSS1;   // 7 + 2 x length
            end
          end
          D_FES1: if (strobe) begin
            if (!v_n) dst <= D_FES2;
            else begin dst <= D_WIDLE; err_coding <= !own; end
          end
          default: if (strobe) begin                          // D_FES2
            dst <= D_WIDLE;
            if (!v_n) err_coding <= !own;
            else if (!own) begin
              if (hcrc_of({hdr[36:24], hdr[23:17]}) != hdr[16:6]) err_hcrc <= 1'b1;
              else if (rcrc != rcrc_rx) err_fcrc <= 1'b1;
              else if (synced) begin
                if (f_id != {5'd0, slot_s} || hdr[5:0] != cyc_s) err_slot <= 1'b1;
                else begin
                  rx_valid <= 1'b1;
                  if (hdr[36] && !cfg_cold) begin              // sync frame: re-phase
                    got_sync <= 1'b1;
                    if (corr > {10'd0, cfg_corr}) begin synced <= 1'b0; err_sync <= 1'b1; end
                    else sc <= sc_new[16:0];
                  end
                end
              end else if (hdr[36] && f_id != 11'd0 && f_id <= {5'd0, cfg_nslots}) begin
                rx_valid <= 1'b1;                              // integrate
                synced <= 1'b1; got_sync <= 1'b1; slot <= f_id[5:0]; cycle <= hdr[5:0];
                sc <= sc_new[16:0];
              end
            end
          end
        endcase
      end
      rx_id <= f_id[5:0]; rx_cycle <= hdr[5:0]; rx_len <= hlen; rx_null <= !hdr[37];
      rx_sync <= hdr[36]; rx_startup <= hdr[35]; rx_data <= rdat;
      if (dst == D_TSS && strobe && v_n) rdat <= '0;         // new frame

      // ---------------- transmit buffer and encoder
      if (tx_valid && !tb_full) begin tb_full <= 1'b1; tb_data <= tx_data; end
      case (tst)
        T_IDLE: if (t_start) begin
          tst <= T_TSS; t_bc <= '0; t_k <= 4'd1; txd <= 1'b0; tx_en <= 1'b1;
          f_nfi  <= tb_full;
          f_hdr  <= {cfg_sync, cfg_sync & cfg_cold, cfg_my_slot, cfg_plen, t_hcrc, cycle};
          f_data <= tb_full ? tb_data : 128'h0;
          if (tb_full) tb_full <= 1'b0;
        end
        default: begin
          t_bc <= t_end ? 7'd0 : t_bc + 7'd1;
          if (t_end) begin
            case (tst)
              T_TSS: if (t_k == cfg_tss) begin tst <= T_FSS; txd <= 1'b1; end
                     else t_k <= t_k + 4'd1;
              T_FSS:  begin tst <= T_BSS1; t_i <= '0; t_crc <= cfg_chan_b ? 24'hABCDEF : 24'hFEDCBA; end
              T_BSS1: begin tst <= T_BSS2; txd <= 1'b0; end
              T_BSS2: begin tst <= T_DATA; t_k <= '0; txd <= t_byte[7]; end
              T_DATA: begin
                if (t_i < {t_ph, 1'b1}) t_crc <= fcrc_next(t_crc, txd);
                if (t_k == 4'd7) begin
                  t_i <= t_i + 6'd1;
                  if (t_i == {t_ph, 1'b1} + 6'd2) begin tst <= T_FES1; txd <= 1'b0; end
                  else begin tst <= T_BSS1; txd <= 1'b1; end
                end else begin
                  t_k <= t_k + 4'd1;
                  txd <= t_byte[3'd6 - t_k[2:0]];
                end
              end
              T_FES1: begin tst <= T_FES2; txd <= 1'b1; end
              default: begin                                    // T_FES2
                tst <= T_IDLE; tx_en <= 1'b0;
                if (f_nfi) tx_done <= 1'b1;
              end
            endcase
          end
        end
      endcase
    end
  end
endmodule
