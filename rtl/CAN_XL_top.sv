// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CAN XL protocol controller (CAN XL frames + classical CAN 2.0A/B frames)
// IP design implementation v1.0 -- Apache-2.0
// ----------------------------------------------------------------------------
//  Classical frames (CC) work as in CAN_top: base and extended IDs, data and
//  remote frames, DLC 0..15 (at most 8 bytes), dynamic bit stuffing from SOF
//  to the end of the CRC, CRC-15, ACK, EOF, error frames and fault
//  confinement (TEC / REC, error passive, bus-off and its recovery).
//
//  XL frames (base priority ID, FDF = XLF = 1), de-stuffed bit index from SOF:
//     0 SOF   1..11 priority ID   12 RRS (0)   13 IDE (0)   14 FDF (1)
//    15 XLF (1)   16 resXL (0)   17 ADH (1)   18 DH1 (1)   19 DH2 (1)
//    20 DL1 (0)   21..28 SDT   29 SEC   30..40 DLC (data bytes - 1)
//    41..43 SBC   44..56 PCRC   57..64 VCID   65..96 AF   97.. data
//    (DLC + 1 bytes, MSB first), FCRC (32), FCP (1100), DAH (1),
//    ACK slot, ACK delimiter, EOF (7)
//  - Dynamic stuffing (a complement after five equal bits) up to ADH (the
//    last one can fall before FDF); SBC = the stuff count mod 4, Gray coded, and
//    its even parity. Fixed stuffing from DL1 to the last FCRC bit: after
//    every FS bits one stuff bit, the complement of the bit before.
//  - PCRC (x^13+x^12+x^11+x^8+x^7+x^6+x^5+x^2+x+1) over SOF..SBC with the
//    dynamic stuff bits; FCRC (x^32+x^31+x^30+x^29+x^28+x^26+x^23+x^21+
//    x^19+x^18+x^15+x^14+x^13+x^12+x^11+x^9+x^8+x^4+x+1) over SOF..data
//    (PCRC included) without stuff bits; both start at 0. An SBC or PCRC
//    mismatch is a CRC error signalled right after the PCRC (the length may
//    be wrong); an FCRC mismatch is signalled after the ACK delimiter.
//  - Data phase: DH1 up to the last FCP bit run at the data bit rate
//    (cfg_d*); tx_fast / rx_fast tell the transceiver (FAST TX / FAST RX
//    mode). An error in the data phase returns to the nominal rate at the
//    next bit.
//  - A frame with FDF set and XLF clear (CAN FD) or an extended frame with
//    r1 recessive is a protocol exception: the node waits for 11 recessive
//    bits (pexc pulses), without an error frame.
//  - Buffers: a TX buffer and a double-buffered RX buffer of MAX_BYTES bytes
//    (32-bit host port: hb_wen / hb_waddr / hb_wdata write the TX buffer,
//    hb_raddr reads hb_rdata from the last delivered frame). A frame is
//    queued with tx_valid; a frame longer than the buffer is refused
//    (tx_rejected). Received bytes past the buffer are dropped (rx_trunc).
//  - Bit timing as CAN_top for each rate: tq = brp + 1 clocks, bit = 1 +
//    (tseg1 + 1) + (tseg2 + 1) tq, sample at the end of TSEG1, SJW = sjw + 1.
//    The bus input has two synchroniser flops and resynchronisation acts a
//    clock after the edge: each rate needs (tseg1 + 1) * (brp + 1) >= 3
//    clocks (a transmitter samples its own bit) and (tseg2 + 1) * (brp + 1)
//    >= 2 clocks (a receiver samples about 3 clocks behind the bus).
//  Not implemented: transmitter delay compensation (the data-phase sample
//  point is the plain one), PWM coding, CAN FD frames, overload frames,
//  CANsec, and the error-signalling switch-off option. The XL field layout
//  follows the public CiA 610-1 descriptions; bit-exact conformance with
//  ISO 11898-1:2024 is not claimed.
// ============================================================================
module CAN_XL_top #(
  parameter int MAX_BYTES = 64,          // buffer size (multiple of 4, 8..2048)
  parameter int FS        = 10,          // fixed stuff period in the data phase
  localparam int BW = $clog2(MAX_BYTES),
  localparam int WW = BW - 2
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          rxd,
  output logic          txd,
  output logic          tx_fast,         // transmitting in the data phase
  output logic          rx_fast,         // receiving in the data phase
  input  logic [5:0]    cfg_brp,
  input  logic [3:0]    cfg_tseg1,
  input  logic [2:0]    cfg_tseg2,
  input  logic [1:0]    cfg_sjw,
  input  logic [5:0]    cfg_dbrp,
  input  logic [3:0]    cfg_dtseg1,
  input  logic [2:0]    cfg_dtseg2,
  input  logic [1:0]    cfg_dsjw,
  input  logic [28:0]   acc_code,
  input  logic [28:0]   acc_mask,
  // host buffer port
  input  logic          hb_wen,
  input  logic [WW-1:0] hb_waddr,
  input  logic [31:0]   hb_wdata,
  input  logic [WW-1:0] hb_raddr,
  output logic [31:0]   hb_rdata,
  // transmit
  input  logic          tx_valid,
  output logic          tx_ready,
  input  logic          tx_xl,
  input  logic [28:0]   tx_id,           // XL: priority ID in [10:0]
  input  logic          tx_ide,
  input  logic          tx_rtr,
  input  logic [10:0]   tx_dlc,          // CC: [3:0]; XL: data bytes - 1
  input  logic [7:0]    tx_sdt,
  input  logic          tx_sec,
  input  logic [7:0]    tx_vcid,
  input  logic [31:0]   tx_af,
  input  logic          tx_abort,
  output logic          tx_done,
  output logic          tx_aborted,
  output logic          tx_rejected,
  // receive
  output logic          rx_valid,
  output logic          rx_xl,
  output logic [28:0]   rx_id,
  output logic          rx_ide,
  output logic          rx_rtr,
  output logic [10:0]   rx_dlc,
  output logic [7:0]    rx_sdt,
  output logic          rx_sec,
  output logic [7:0]    rx_vcid,
  output logic [31:0]   rx_af,
  output logic          rx_trunc,
  // events and state
  output logic          arb_lost,
  output logic          err_bit,
  output logic          err_stuff,
  output logic          err_crc,
  output logic          err_form,
  output logic          err_ack,
  output logic          pexc,
  output logic [8:0]    tec,
  output logic [7:0]    rec,
  output logic          err_passive,
  output logic          bus_off
);
  typedef enum logic [3:0] {
    M_IDLE, M_SUSPEND, M_FRAME, M_EFLAG, M_EWAIT, M_EDELIM, M_INTERM, M_BUSOFF, M_PEXC
  } mode_t;
  mode_t mode;

  localparam logic [14:0] NONE = 15'h7FF0;   // position not known yet

  // ---------------- bus input ----------------
  logic rx_s1, rx_s, rx_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_s1 <= 1'b1; rx_s <= 1'b1; rx_d <= 1'b1; end
    else begin rx_s1 <= rxd; rx_s <= rx_s1; rx_d <= rx_s; end
  end
  wire fall = rx_d & ~rx_s;

  // ---------------- bit timing (nominal / data phase) ----------------
  logic       dph;               // the current bit runs at the data bit rate
  logic [5:0] brp_cnt;
  logic [4:0] tq_cnt;
  logic       resynced;
  logic       last_smp;
  logic       drv;
  wire  [5:0] brp  = dph ? cfg_dbrp : cfg_brp;
  wire  [4:0] t1   = {1'b0, dph ? cfg_dtseg1 : cfg_tseg1} + 5'd1;
  wire  [4:0] ntq  = t1 + {2'b0, dph ? cfg_dtseg2 : cfg_tseg2} + 5'd2;
  wire  [2:0] sjw  = {1'b0, dph ? cfg_dsjw : cfg_sjw} + 3'd1;
  wire        tq_tick = brp_cnt == brp;
  wire        hs_ok   = mode == M_IDLE || mode == M_SUSPEND || mode == M_INTERM;
  wire        hard_sync = fall && hs_ok;
  wire        rs_ok   = fall && !hs_ok && mode != M_BUSOFF && !resynced && last_smp && drv
                        && tq_cnt != 5'd0;
  wire  [4:0] tq_n    = tq_cnt + {4'b0, tq_tick};
  wire  [5:0] brp_n   = tq_tick ? 6'd0 : brp_cnt + 6'd1;
  wire        rs_late = rs_ok && tq_cnt <= t1;
  wire        late_full = tq_n < {2'b0, sjw} || (tq_n == {2'b0, sjw} && tq_tick);
  wire  [4:0] early   = ntq - tq_n;
  wire        rs_end  = rs_ok && tq_cnt > t1 && early <= {2'b0, sjw};
  wire        rs_skip = rs_ok && tq_cnt > t1 && early > {2'b0, sjw};
  wire        sync_any = hard_sync || rs_ok;
  wire        sample  = tq_tick && tq_cnt == t1 && !sync_any;
  wire        bit_start = (tq_tick && tq_cnt == ntq - 5'd1 && !sync_any) || rs_end;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      brp_cnt <= '0; tq_cnt <= '0; resynced <= 1'b0;
    end else begin
      if (hard_sync || rs_end || (rs_late && late_full)) begin
        brp_cnt <= '0; tq_cnt <= '0;
      end else if (rs_late) begin
        brp_cnt <= brp_n;
        tq_cnt  <= tq_n - {2'b0, sjw};
      end else if (rs_skip) begin
        brp_cnt <= brp_n;
        tq_cnt  <= tq_n + {2'b0, sjw};
      end else if (tq_tick) begin
        brp_cnt <= '0;
        tq_cnt  <= tq_cnt == ntq - 5'd1 ? 5'd0 : tq_cnt + 5'd1;
      end else brp_cnt <= brp_cnt + 6'd1;
      if (sample) resynced <= 1'b0;
      else if (rs_ok) resynced <= 1'b1;
    end
  end

  // ---------------- buffers ----------------
  logic [7:0] tbuf [0:MAX_BYTES-1];
  logic [7:0] rbuf [0:2*MAX_BYTES-1];
  logic       rbank;                     // bank the host reads
  logic          rw_en;               // a received byte to store
  logic [BW:0]   rw_addr;
  logic [7:0]    rw_data;
  always_ff @(posedge clk) begin
    if (hb_wen) begin
      tbuf[{hb_waddr, 2'd0}] <= hb_wdata[7:0];
      tbuf[{hb_waddr, 2'd1}] <= hb_wdata[15:8];
      tbuf[{hb_waddr, 2'd2}] <= hb_wdata[23:16];
      tbuf[{hb_waddr, 2'd3}] <= hb_wdata[31:24];
    end
    if (rw_en) rbuf[rw_addr] <= rw_data;
  end
  assign hb_rdata = {rbuf[{rbank, hb_raddr, 2'd3}], rbuf[{rbank, hb_raddr, 2'd2}],
                     rbuf[{rbank, hb_raddr, 2'd1}], rbuf[{rbank, hb_raddr, 2'd0}]};

  // ---------------- transmit buffer ----------------
  logic        pending, abort_req;
  logic        b_xl;
  logic [28:0] b_id;
  logic        b_ide, b_rtr;
  logic [10:0] b_dlc;
  logic [7:0]  b_sdt, b_vcid;
  logic        b_sec;
  logic [31:0] b_af;
  assign tx_ready = !pending;
  wire  [11:0] q_bytes = tx_xl ? {1'b0, tx_dlc} + 12'd1 : (tx_rtr || tx_dlc[3:0] == 4'd0) ? 12'd0 :
                         tx_dlc[3:0] > 4'd8 ? 12'd8 : {8'd0, tx_dlc[3:0]};
  wire         q_fits  = q_bytes <= 12'(MAX_BYTES);

  // own frame: CC layout
  wire  [3:0]  b_nbytes  = b_rtr ? 4'd0 : (b_dlc[3:0] > 4'd8 ? 4'd8 : b_dlc[3:0]);
  wire  [14:0] tx_crc_st = (b_ide ? 15'd39 : 15'd19) + {8'd0, b_nbytes, 3'b000};
  wire  [14:0] tx_crc_ls = tx_crc_st + 15'd14;
  // own frame: XL layout
  wire  [11:0] tx_nb     = {1'b0, b_dlc} + 12'd1;
  wire  [14:0] tx_xend   = 15'd97 + {tx_nb, 3'b000};          // first FCRC bit
  wire  [14:0] tx_last   = b_xl ? tx_xend + 15'd35 : tx_crc_ls;   // last FCP / CRC bit

  // ---------------- frame state ----------------
  logic        is_tx;
  logic [14:0] pos;              // de-stuffed bit index, SOF = 0
  logic        run_val;
  logic [2:0]  run_len;
  logic [3:0]  fs_cnt;           // bits since the last fixed stuff bit
  logic [1:0]  dsc;              // dynamic stuff bits (mod 4)
  logic [14:0] crc;              // CC CRC-15
  logic [12:0] pcrc;
  logic [31:0] fcrc;
  logic        crc_err, pcrc_err;
  logic [10:0] f_ida;
  logic        f_b12, f_ide, f_rtr, f_fdf, f_xl, f_sec;
  logic [17:0] f_idb;
  logic [3:0]  f_dlc;
  logic [10:0] f_xdlc;
  logic [2:0]  f_sbc;
  logic [7:0]  f_sdt, f_vcid, f_byte;
  logic [31:0] f_af;
  logic        f_trunc;
  logic [2:0]  cnt;
  logic        flag_passive;
  logic [3:0]  rec_run;
  logic [6:0]  occ;

  // received frame: CC layout
  wire  [3:0]  f_nbytes  = (f_ide ? f_rtr : f_b12) ? 4'd0 : (f_dlc > 4'd8 ? 4'd8 : f_dlc);
  wire  [14:0] dat_st    = f_ide ? 15'd39 : 15'd19;
  wire         known     = pos > (f_ide ? 15'd38 : 15'd18);
  wire  [14:0] crc_st    = dat_st + {8'd0, f_nbytes, 3'b000};
  // received frame: XL layout
  wire         xknown    = pos > 15'd40;
  wire  [11:0] x_nbytes  = {1'b0, f_xdlc} + 12'd1;
  wire  [14:0] x_cst     = 15'd97 + {x_nbytes, 3'b000};           // first FCRC bit
  wire  [14:0] body_last = f_xl ? (xknown ? x_cst + 15'd35 : NONE) : (known ? crc_st + 15'd14 : NONE);
  wire  [14:0] k         = pos - body_last;
  wire  [14:0] dyn_lim   = f_xl ? 15'd17 : body_last + 15'd1;      // dynamic stuffing up to here
  wire  [14:0] fix_last  = xknown ? x_cst + 15'd31 : NONE;         // last fixed-stuffed bit
  wire         dyn_due   = pos <= dyn_lim && run_len == 3'd5;
  wire         fix_due   = f_xl && pos >= 15'd21 && pos <= fix_last && fs_cnt == 4'(FS);
  wire  [6:0]  di        = 7'(pos - dat_st);
  wire  [13:0] xi        = 14'(pos - 15'd97);                       // XL data bit index
  wire         in_arb    = pos <= (b_ide ? 15'd32 : 15'd12);
  wire  [1:0]  sbc_g     = dsc ^ (dsc >> 1);
  wire  [2:0]  sbc_v     = {sbc_g, ^sbc_g};

  // bit to send at de-stuffed index pos of the own frame
  logic tx_bit;
  always_comb begin
    logic [6:0]  i;
    logic [13:0] j;
    i = 7'(pos - (b_ide ? 15'd39 : 15'd19));
    j = 14'(pos - 15'd97);
    if (pos == 15'd0)                    tx_bit = 1'b0;                        // SOF
    else if (pos <= 15'd11)              tx_bit = b_ide ? b_id[15'd29 - pos] : b_id[15'd11 - pos];
    else if (pos == 15'd12)              tx_bit = b_ide ? 1'b1 : (b_rtr && !b_xl);  // SRR / RTR / RRS
    else if (pos == 15'd13)              tx_bit = b_ide;
    else if (b_xl) begin
      if (pos == 15'd14 || pos == 15'd15) tx_bit = 1'b1;                       // FDF, XLF
      else if (pos == 15'd16)            tx_bit = 1'b0;                        // resXL
      else if (pos <= 15'd19)            tx_bit = 1'b1;                        // ADH, DH1, DH2
      else if (pos == 15'd20)            tx_bit = 1'b0;                        // DL1
      else if (pos <= 15'd28)            tx_bit = b_sdt[15'd28 - pos];
      else if (pos == 15'd29)            tx_bit = b_sec;
      else if (pos <= 15'd40)            tx_bit = b_dlc[15'd40 - pos];
      else if (pos <= 15'd43)            tx_bit = sbc_v[15'd43 - pos];
      else if (pos <= 15'd56)            tx_bit = pcrc[15'd56 - pos];
      else if (pos <= 15'd64)            tx_bit = b_vcid[15'd64 - pos];
      else if (pos <= 15'd96)            tx_bit = b_af[15'd96 - pos];
      else if (pos < tx_xend)            tx_bit = tbuf[BW'(j >> 3)][3'd7 - j[2:0]];
      else if (pos < tx_xend + 15'd32)   tx_bit = fcrc[15'd31 - (pos - tx_xend)];
      else                               tx_bit = pos < tx_xend + 15'd34;      // FCP 1100
    end
    else if (!b_ide && pos == 15'd14)    tx_bit = 1'b0;                        // r0
    else if (!b_ide && pos <= 15'd18)    tx_bit = b_dlc[15'd18 - pos];
    else if (b_ide && pos <= 15'd31)     tx_bit = b_id[15'd31 - pos];
    else if (b_ide && pos == 15'd32)     tx_bit = b_rtr;
    else if (b_ide && pos <= 15'd34)     tx_bit = 1'b0;                        // r1, r0
    else if (b_ide && pos <= 15'd38)     tx_bit = b_dlc[15'd38 - pos];
    else if (pos < tx_crc_st)            tx_bit = tbuf[BW'(i >> 3)][3'd7 - i[2:0]];
    else                                 tx_bit = crc[15'd14 - (pos - tx_crc_st)];
  end

  function automatic logic [14:0] crc_next(input logic [14:0] c, input logic b);
    crc_next = {c[13:0], 1'b0} ^ ((b ^ c[14]) ? 15'h4599 : 15'h0);
  endfunction
  function automatic logic [12:0] pcrc_next(input logic [12:0] c, input logic b);
    pcrc_next = {c[11:0], 1'b0} ^ ((b ^ c[12]) ? 13'h19E7 : 13'h0);
  endfunction
  function automatic logic [31:0] fcrc_next(input logic [31:0] c, input logic b);
    fcrc_next = {c[30:0], 1'b0} ^ ((b ^ c[31]) ? 32'hF4ACFB13 : 32'h0);
  endfunction

  wire [28:0] dec_id  = f_xl ? {18'h0, f_ida} : f_ide ? {f_ida, f_idb} : {18'h0, f_ida};
  wire        dec_rtr = !f_xl && (f_ide ? f_rtr : f_b12);
  wire        accept  = ((dec_id ^ acc_code) & acc_mask) == 29'h0;

  assign txd         = drv;
  assign bus_off     = mode == M_BUSOFF;
  assign err_passive = !bus_off && (tec > 9'd127 || rec > 8'd127);
  assign tx_fast     = dph && is_tx;
  assign rx_fast     = dph && !is_tx;

  // ---------------- frame engine ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    logic b, e_bit, e_stuff, e_form, e_ack, e_crc, no_tec, err, tec_up;
    if (!rst_n) begin
      mode <= M_IDLE; drv <= 1'b1; last_smp <= 1'b1; dph <= 1'b0; rbank <= 1'b0;
      pending <= 1'b0; abort_req <= 1'b0;
      b_xl <= 1'b0; b_id <= '0; b_ide <= 1'b0; b_rtr <= 1'b0; b_dlc <= '0;
      b_sdt <= '0; b_sec <= 1'b0; b_vcid <= '0; b_af <= '0;
      is_tx <= 1'b0; pos <= '0; run_val <= 1'b0; run_len <= '0; fs_cnt <= '0; dsc <= '0;
      crc <= '0; pcrc <= '0; fcrc <= '0; crc_err <= 1'b0; pcrc_err <= 1'b0;
      f_ida <= '0; f_b12 <= 1'b0; f_ide <= 1'b0; f_rtr <= 1'b0; f_fdf <= 1'b0; f_xl <= 1'b0;
      f_sec <= 1'b0; f_idb <= '0; f_dlc <= '0; f_xdlc <= '0; f_sbc <= '0; f_sdt <= '0;
      f_vcid <= '0; f_byte <= '0; f_af <= '0; f_trunc <= 1'b0;
      cnt <= '0; flag_passive <= 1'b0; rec_run <= '0; occ <= '0;
      tec <= '0; rec <= '0; rw_en <= 1'b0; rw_addr <= '0; rw_data <= '0;
      tx_done <= 1'b0; tx_aborted <= 1'b0; tx_rejected <= 1'b0; rx_valid <= 1'b0;
      rx_xl <= 1'b0; rx_id <= '0; rx_ide <= 1'b0; rx_rtr <= 1'b0; rx_dlc <= '0;
      rx_sdt <= '0; rx_sec <= 1'b0; rx_vcid <= '0; rx_af <= '0; rx_trunc <= 1'b0;
      arb_lost <= 1'b0; err_bit <= 1'b0; err_stuff <= 1'b0; err_crc <= 1'b0;
      err_form <= 1'b0; err_ack <= 1'b0; pexc <= 1'b0;
    end else begin
      tx_done <= 1'b0; tx_aborted <= 1'b0; tx_rejected <= 1'b0; rx_valid <= 1'b0; arb_lost <= 1'b0;
      err_bit <= 1'b0; err_stuff <= 1'b0; err_crc <= 1'b0; err_form <= 1'b0; err_ack <= 1'b0;
      pexc <= 1'b0; rw_en <= 1'b0;
      e_bit = 1'b0; e_stuff = 1'b0; e_form = 1'b0; e_ack = 1'b0; e_crc = 1'b0; no_tec = 1'b0;
      b = rx_s;

      // ---- host side
      if (tx_valid && !pending) begin
        if (q_fits) begin
          pending <= 1'b1;
          b_xl <= tx_xl; b_id <= tx_id; b_ide <= tx_ide && !tx_xl; b_rtr <= tx_rtr && !tx_xl;
          b_dlc <= tx_dlc; b_sdt <= tx_sdt; b_sec <= tx_sec; b_vcid <= tx_vcid; b_af <= tx_af;
        end else tx_rejected <= 1'b1;
      end
      if (tx_abort && pending) abort_req <= 1'b1;
      if (abort_req && pending && !is_tx) begin
        pending <= 1'b0; abort_req <= 1'b0; tx_aborted <= 1'b1;
      end

      // ---- what to drive in the next bit, and at which rate
      if (bit_start) begin
        drv <= 1'b1;
        dph <= mode == M_FRAME && f_xl && pos >= 15'd18 && pos <= body_last;
        case (mode)
          M_IDLE: if (pending && !abort_req) begin drv <= 1'b0; is_tx <= 1'b1; end
          M_FRAME:
            if (is_tx) begin
              if (dyn_due || fix_due) drv <= ~run_val;
              else if (pos <= tx_last) drv <= tx_bit;
            end else if (k == 15'd2 && !crc_err) drv <= 1'b0;                  // ACK
          M_EFLAG: drv <= flag_passive;
          default: ;
        endcase
      end

      // ---- sample point
      if (sample) begin
        last_smp <= b;
        case (mode)
          M_IDLE, M_SUSPEND, M_INTERM: begin
            if (!b) begin                                  // SOF
              mode <= M_FRAME; pos <= 15'd1; run_val <= 1'b0; run_len <= 3'd1;
              fs_cnt <= '0; dsc <= '0;
              crc <= '0; pcrc <= '0; fcrc <= '0; crc_err <= 1'b0; pcrc_err <= 1'b0;
              f_xl <= 1'b0; f_fdf <= 1'b0; f_ide <= 1'b0; f_trunc <= 1'b0;
              if (mode == M_INTERM) is_tx <= cnt == 3'd2 && pending && !abort_req && !(is_tx && err_passive);
              else if (mode == M_SUSPEND) is_tx <= 1'b0;
              else is_tx <= is_tx || (pending && !abort_req);
            end else if (mode == M_INTERM) begin
              cnt <= cnt + 3'd1;
              if (cnt == 3'd2) begin
                is_tx <= 1'b0; cnt <= '0;
                mode <= (is_tx && err_passive) ? M_SUSPEND : M_IDLE;
              end
            end else if (mode == M_SUSPEND) begin
              cnt <= cnt + 3'd1;
              if (cnt == 3'd7) begin cnt <= '0; mode <= M_IDLE; end
            end
          end

          M_FRAME: begin
            if (dyn_due) begin                                       // dynamic stuff bit
              if (b == run_val) begin
                e_stuff = 1'b1;
                no_tec  = is_tx && drv && in_arb;
              end
              run_val <= b; run_len <= 3'd1;
              dsc <= dsc + 2'd1;
              pcrc <= pcrc_next(pcrc, b);
            end else if (fix_due) begin                              // fixed stuff bit
              if (b == run_val) e_stuff = 1'b1;
              run_val <= b; run_len <= 3'd1; fs_cnt <= '0;
            end else if (pos <= body_last) begin
              if (b == run_val) run_len <= run_len == 3'd7 ? 3'd7 : run_len + 3'd1;
              else begin run_val <= b; run_len <= 3'd1; end
              if (is_tx && b != drv) begin
                if (drv && in_arb) begin is_tx <= 1'b0; arb_lost <= 1'b1; end
                else e_bit = 1'b1;
              end
              // header fields
              if (pos <= 15'd11) f_ida <= {f_ida[9:0], b};
              else if (pos == 15'd12) f_b12 <= b;
              else if (pos == 15'd13) f_ide <= b;
              else if (!f_ide && pos == 15'd14) f_fdf <= b;
              else if (!f_ide && pos == 15'd15 && f_fdf) begin
                if (b) f_xl <= 1'b1;
                else begin mode <= M_PEXC; pexc <= 1'b1; rec_run <= '0; is_tx <= 1'b0; end
              end else if (f_xl) begin
                if (pos == 15'd16 || pos == 15'd20) begin if (b) e_form = 1'b1; end     // resXL, DL1
                else if (pos >= 15'd17 && pos <= 15'd19) begin if (!b) e_form = 1'b1; end // ADH, DH1, DH2
                else if (pos <= 15'd28) f_sdt <= {f_sdt[6:0], b};
                else if (pos == 15'd29) f_sec <= b;
                else if (pos <= 15'd40) f_xdlc <= {f_xdlc[9:0], b};
                else if (pos <= 15'd43) f_sbc <= {f_sbc[1:0], b};
                else if (pos <= 15'd56) begin
                  if (b != pcrc[15'd56 - pos]) pcrc_err <= 1'b1;
                  if (pos == 15'd56 && (pcrc_err || b != pcrc[0] || f_sbc != sbc_v)) e_crc = 1'b1;
                end
                else if (pos <= 15'd64) f_vcid <= {f_vcid[6:0], b};
                else if (pos <= 15'd96) f_af <= {f_af[30:0], b};
                else if (pos < x_cst) begin
                  f_byte <= {f_byte[6:0], b};
                  if (xi[2:0] == 3'd7) begin
                    if ({1'b0, xi[13:3]} < 12'(MAX_BYTES)) begin
                      rw_en <= 1'b1; rw_addr <= {!rbank, BW'(xi[13:3])}; rw_data <= {f_byte[6:0], b};
                    end else f_trunc <= 1'b1;
                  end
                end
                else if (pos < x_cst + 15'd32) begin
                  if (b != fcrc[15'd31 - (pos - x_cst)]) crc_err <= 1'b1;
                end
                else if (b != (pos < x_cst + 15'd34)) e_form = 1'b1;   // FCP
                if (pos >= 15'd20 && pos <= fix_last) fs_cnt <= fs_cnt + 4'd1;
              end else if (f_ide && pos == 15'd33 && b) begin       // r1 recessive: FD
                mode <= M_PEXC; pexc <= 1'b1; rec_run <= '0; is_tx <= 1'b0;
              end else if (f_ide && pos <= 15'd31) f_idb <= {f_idb[16:0], b};
              else if (f_ide && pos == 15'd32) f_rtr <= b;
              else if ((f_ide && pos >= 15'd35 && pos <= 15'd38) || (!f_ide && pos >= 15'd15 && pos <= 15'd18))
                f_dlc <= {f_dlc[2:0], b};
              else if (known && pos < crc_st) begin
                f_byte <= {f_byte[6:0], b};
                if (di[2:0] == 3'd7) begin
                  rw_en <= 1'b1; rw_addr <= {!rbank, BW'(di[6:3])}; rw_data <= {f_byte[6:0], b};
                end
              end
              if (pos <= 15'd43) pcrc <= pcrc_next(pcrc, b);
              if (!(f_xl && xknown) || pos < x_cst) fcrc <= fcrc_next(fcrc, b);
              if (!f_xl) begin
                if (!known || pos < crc_st) crc <= crc_next(crc, b);
                else if (b != crc[15'd14 - (pos - crc_st)]) crc_err <= 1'b1;
              end
              pos <= pos + 15'd1;
            end else begin
              pos <= pos + 15'd1;
              if (k == 15'd1 && !b) e_form = 1'b1;                     // CRC delimiter / DAH
              if (k == 15'd2 && is_tx && b) e_ack = 1'b1;              // ACK slot
              if (k == 15'd3) begin                                    // ACK delimiter
                if (!b) e_form = 1'b1;
                else if (crc_err) e_crc = 1'b1;
              end
              if (k >= 15'd4 && k <= 15'd9 && !b) e_form = 1'b1;       // EOF 1..6
              if (k == 15'd10 && is_tx && !b) e_form = 1'b1;           // EOF 7
              if (k == 15'd9 && b && !is_tx) begin                     // frame valid (Rx)
                if (rec > 8'd127) rec <= 8'd120;
                else if (rec != 8'd0) rec <= rec - 8'd1;
                if (accept) begin
                  rx_valid <= 1'b1; rbank <= !rbank;
                  rx_xl <= f_xl; rx_id <= dec_id; rx_ide <= f_ide && !f_xl; rx_rtr <= dec_rtr;
                  rx_dlc <= f_xl ? f_xdlc : {7'd0, f_dlc};
                  rx_sdt <= f_xl ? f_sdt : 8'd0; rx_sec <= f_xl && f_sec;
                  rx_vcid <= f_xl ? f_vcid : 8'd0; rx_af <= f_xl ? f_af : 32'd0;
                  rx_trunc <= f_xl && f_trunc;
                end
              end
              if (k == 15'd10 && !(is_tx && !b)) begin                 // frame valid (Tx)
                mode <= M_INTERM; cnt <= '0;
                if (is_tx) begin
                  pending <= 1'b0; abort_req <= 1'b0; tx_done <= 1'b1;
                  if (tec != 9'd0) tec <= tec - 9'd1;
                end
              end
            end
          end

          M_EFLAG: begin
            cnt <= cnt + 3'd1;
            if (cnt == 3'd5) begin cnt <= '0; mode <= M_EWAIT; end
          end
          M_EWAIT: if (b) begin cnt <= 3'd1; mode <= M_EDELIM; end
          M_EDELIM: begin
            if (!b) e_form = 1'b1;
            else begin
              cnt <= cnt + 3'd1;
              if (cnt == 3'd7) begin cnt <= '0; mode <= M_INTERM; end
            end
          end
          M_PEXC: begin                                      // wait for 11 recessive bits
            if (!b) rec_run <= '0;
            else if (rec_run == 4'd10) begin rec_run <= '0; mode <= M_IDLE; end
            else rec_run <= rec_run + 4'd1;
          end
          default: begin                                     // M_BUSOFF
            if (!b) rec_run <= '0;
            else if (rec_run == 4'd10) begin
              rec_run <= '0;
              occ <= occ + 7'd1;
              if (occ == 7'd127) begin
                occ <= '0; tec <= '0; rec <= '0; mode <= M_IDLE;
              end
            end else rec_run <= rec_run + 4'd1;
          end
        endcase

        // ---- error handling
        err = e_bit | e_stuff | e_form | e_ack | e_crc;
        if (err) begin
          err_bit <= e_bit; err_stuff <= e_stuff; err_form <= e_form;
          err_ack <= e_ack; err_crc <= e_crc;
          cnt <= '0;
          flag_passive <= err_passive;
          mode <= M_EFLAG;
          tec_up = !(no_tec || (e_ack && err_passive));
          if (is_tx) begin
            if (tec_up) begin
              tec <= tec + 9'd8;
              if (tec > 9'd247) begin mode <= M_BUSOFF; is_tx <= 1'b0; rec_run <= '0; occ <= '0; end
            end
          end else if (rec != 8'hFF) rec <= rec + 8'd1;
        end
      end
    end
  end
endmodule
