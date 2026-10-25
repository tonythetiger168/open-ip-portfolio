// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CAN 2.0A/B protocol controller (classical CAN, ISO 11898-1)
// IP design implementation v2.0 -- Apache-2.0
// ----------------------------------------------------------------------------
//  - Frames: base (11-bit ID) and extended (29-bit ID), data and remote,
//    DLC 0..15 (more than 8 sends 8 data bytes). Bit stuffing from SOF to
//    the end of the CRC sequence, CRC-15 (polynomial 0x4599).
//  - Bit timing: tq = cfg_brp+1 clocks; bit = SYNC (1 tq) + TSEG1
//    (cfg_tseg1+1 tq) + TSEG2 (cfg_tseg2+1 tq); the bus is sampled at the
//    end of TSEG1. Hard synchronisation on the SOF edge, resynchronisation
//    on recessive-to-dominant edges with jump width cfg_sjw+1 tq (at most
//    one per bit, none while this node drives dominant).
//  - Transmit: one buffer (tx_valid/tx_ready). Bitwise arbitration over the
//    ID/SRR/IDE/RTR field; losing it turns the node into a receiver and the
//    frame is retried, as after any error. tx_abort drops a buffered frame
//    when the node is not transmitting it (tx_aborted).
//  - Receive: frames that pass ((id ^ acc_code) & acc_mask) == 0 are
//    delivered on rx_valid at the 6th EOF bit. Own frames are not delivered.
//    The receiver drives the ACK slot dominant when its CRC matched.
//  - Errors: bit, stuff, CRC, form and ACK errors start an error frame
//    (6-bit active or passive error flag, wait for recessive, 8-bit
//    delimiter). Fault confinement: TEC +8 per transmit error, -1 per
//    frame sent; REC +1 per receive error, -1 per frame received (120 when
//    it was above 127). Error-passive at TEC or REC > 127 (passive flags,
//    8-bit suspend after transmitting), bus-off at TEC > 255, recovery
//    after 128 x 11 recessive bits. An error-passive transmitter's ACK
//    error and a stuff error on a recessive stuff bit in arbitration do not
//    raise TEC (ISO 11898-1 exceptions).
//  - A dominant bit in intermission is taken as SOF; a node with a pending
//    frame that sees it at the 3rd intermission bit transmits from the first
//    ID bit on (ISO 11898-1); so does a node with a pending frame that
//    synchronises to another node's SOF in bus idle.
//    Not implemented: overload frames, the +8 counter rules for dominant
//    bits around error flags, CAN FD.
// ============================================================================
module CAN_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rxd,
  output logic        txd,
  input  logic [5:0]  cfg_brp,
  input  logic [3:0]  cfg_tseg1,
  input  logic [2:0]  cfg_tseg2,
  input  logic [1:0]  cfg_sjw,
  input  logic [28:0] acc_code,
  input  logic [28:0] acc_mask,
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [28:0] tx_id,
  input  logic        tx_ide,
  input  logic        tx_rtr,
  input  logic [3:0]  tx_dlc,
  input  logic [63:0] tx_data,
  input  logic        tx_abort,
  output logic        tx_done,
  output logic        tx_aborted,
  output logic        rx_valid,
  output logic [28:0] rx_id,
  output logic        rx_ide,
  output logic        rx_rtr,
  output logic [3:0]  rx_dlc,
  output logic [63:0] rx_data,
  output logic        arb_lost,
  output logic        err_bit,
  output logic        err_stuff,
  output logic        err_crc,
  output logic        err_form,
  output logic        err_ack,
  output logic [8:0]  tec,
  output logic [7:0]  rec,
  output logic        err_passive,
  output logic        bus_off
);
  typedef enum logic [2:0] {
    M_IDLE, M_SUSPEND, M_FRAME, M_EFLAG, M_EWAIT, M_EDELIM, M_INTERM, M_BUSOFF
  } mode_t;
  mode_t mode;

  // ---------------- bus input ----------------
  logic rx_s1, rx_s, rx_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_s1 <= 1'b1; rx_s <= 1'b1; rx_d <= 1'b1; end
    else begin rx_s1 <= rxd; rx_s <= rx_s1; rx_d <= rx_s; end
  end
  wire fall = rx_d & ~rx_s;

  // ---------------- bit timing ----------------
  logic [5:0] brp_cnt;
  logic [4:0] tq_cnt;
  logic       resynced;          // one resynchronisation per bit
  logic       last_smp;          // bus value at the last sample point
  logic       drv;               // bit this node drives (1 = recessive)
  wire  [4:0] t1   = {1'b0, cfg_tseg1} + 5'd1;
  wire  [4:0] ntq  = t1 + {2'b0, cfg_tseg2} + 5'd2;
  wire  [2:0] sjw  = {1'b0, cfg_sjw} + 3'd1;
  wire        tq_tick = brp_cnt == cfg_brp;
  wire        hs_ok   = mode == M_IDLE || mode == M_SUSPEND || mode == M_INTERM;
  wire        hard_sync = fall && hs_ok;
  wire        rs_ok   = fall && !hs_ok && mode != M_BUSOFF && !resynced && last_smp && drv
                        && tq_cnt != 5'd0;
  // Phase error in whole tq, from where the next clock would fall without
  // resynchronisation (tq_n, brp_n): the correction is exactly min(e, SJW).
  wire  [4:0] tq_n    = tq_cnt + {4'b0, tq_tick};
  wire  [5:0] brp_n   = tq_tick ? 6'd0 : brp_cnt + 6'd1;
  wire        rs_late = rs_ok && tq_cnt <= t1;            // positive phase error
  wire        late_full = tq_n < {2'b0, sjw} || (tq_n == {2'b0, sjw} && tq_tick);
  wire  [4:0] early   = ntq - tq_n;                        // negative phase error
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

  // ---------------- transmit buffer ----------------
  logic        pending, abort_req;
  logic [28:0] b_id;
  logic        b_ide, b_rtr;
  logic [3:0]  b_dlc;
  logic [63:0] b_data;
  assign tx_ready = !pending;

  wire  [3:0] b_nbytes  = b_rtr ? 4'd0 : (b_dlc > 4'd8 ? 4'd8 : b_dlc);
  wire  [7:0] tx_crc_st = (b_ide ? 8'd39 : 8'd19) + {1'b0, b_nbytes, 3'b000};
  wire  [7:0] tx_crc_ls = tx_crc_st + 8'd14;

  // ---------------- frame state ----------------
  logic        is_tx;            // this node transmits the current frame
  logic [7:0]  pos;              // de-stuffed bit index, SOF = 0
  logic        run_val;
  logic [2:0]  run_len;
  logic [14:0] crc;
  logic        crc_err;
  logic [10:0] f_ida;
  logic        f_b12, f_ide, f_rtr;
  logic [17:0] f_idb;
  logic [3:0]  f_dlc;
  logic [63:0] f_data;
  logic [2:0]  cnt;              // error flag / delimiter / intermission / suspend
  logic        flag_passive;     // error flag being sent is passive
  logic [3:0]  rec_run;          // bus-off recovery: recessive run
  logic [6:0]  occ;              //                   11-bit runs seen

  wire  [3:0] f_nbytes  = (f_ide ? f_rtr : f_b12) ? 4'd0 : (f_dlc > 4'd8 ? 4'd8 : f_dlc);
  wire  [7:0] dat_st    = f_ide ? 8'd39 : 8'd19;
  wire        known     = pos > (f_ide ? 8'd38 : 8'd18);   // DLC received
  wire  [7:0] crc_st    = dat_st + {1'b0, f_nbytes, 3'b000};
  wire  [7:0] crc_ls    = known ? crc_st + 8'd14 : 8'd200;
  wire  [6:0] di        = 7'(pos - dat_st);                // data bit index
  wire        in_arb    = pos <= (b_ide ? 8'd32 : 8'd12);  // arbitration field (own frame)

  // bit to send at de-stuffed index pos of the own frame
  logic tx_bit;
  always_comb begin
    logic [6:0] i;
    i = 7'(pos - (b_ide ? 8'd39 : 8'd19));
    if (pos == 8'd0)                   tx_bit = 1'b0;                        // SOF
    else if (pos <= 8'd11)             tx_bit = b_ide ? b_id[8'd29 - pos] : b_id[8'd11 - pos];
    else if (pos == 8'd12)             tx_bit = b_ide ? 1'b1 : b_rtr;        // SRR / RTR
    else if (pos == 8'd13)             tx_bit = b_ide;
    else if (!b_ide && pos == 8'd14)   tx_bit = 1'b0;                        // r0
    else if (!b_ide && pos <= 8'd18)   tx_bit = b_dlc[8'd18 - pos];
    else if (b_ide && pos <= 8'd31)    tx_bit = b_id[8'd31 - pos];
    else if (b_ide && pos == 8'd32)    tx_bit = b_rtr;
    else if (b_ide && pos <= 8'd34)    tx_bit = 1'b0;                        // r1, r0
    else if (b_ide && pos <= 8'd38)    tx_bit = b_dlc[8'd38 - pos];
    else if (pos < tx_crc_st)          tx_bit = b_data[{i[6:3], 3'b111 - i[2:0]}];
    else                               tx_bit = crc[8'd14 - (pos - tx_crc_st)];
  end

  function automatic logic [14:0] crc_next(input logic [14:0] c, input logic b);
    crc_next = {c[13:0], 1'b0} ^ ((b ^ c[14]) ? 15'h4599 : 15'h0);
  endfunction

  wire [28:0] dec_id  = f_ide ? {f_ida, f_idb} : {18'h0, f_ida};
  wire        dec_rtr = f_ide ? f_rtr : f_b12;
  wire        accept  = ((dec_id ^ acc_code) & acc_mask) == 29'h0;

  assign txd         = drv;
  assign bus_off     = mode == M_BUSOFF;
  assign err_passive = !bus_off && (tec > 9'd127 || rec > 8'd127);

  // ---------------- frame engine ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    logic b, e_bit, e_stuff, e_form, e_ack, e_crc, no_tec, err;
    logic [7:0] k;
    if (!rst_n) begin
      mode <= M_IDLE; drv <= 1'b1; last_smp <= 1'b1;
      pending <= 1'b0; abort_req <= 1'b0;
      b_id <= '0; b_ide <= 1'b0; b_rtr <= 1'b0; b_dlc <= '0; b_data <= '0;
      is_tx <= 1'b0; pos <= '0; run_val <= 1'b0; run_len <= '0; crc <= '0; crc_err <= 1'b0;
      f_ida <= '0; f_b12 <= 1'b0; f_ide <= 1'b0; f_rtr <= 1'b0; f_idb <= '0; f_dlc <= '0;
      f_data <= '0; cnt <= '0; flag_passive <= 1'b0; rec_run <= '0; occ <= '0;
      tec <= '0; rec <= '0;
      tx_done <= 1'b0; tx_aborted <= 1'b0; rx_valid <= 1'b0;
      rx_id <= '0; rx_ide <= 1'b0; rx_rtr <= 1'b0; rx_dlc <= '0; rx_data <= '0;
      arb_lost <= 1'b0; err_bit <= 1'b0; err_stuff <= 1'b0; err_crc <= 1'b0;
      err_form <= 1'b0; err_ack <= 1'b0;
    end else begin
      tx_done <= 1'b0; tx_aborted <= 1'b0; rx_valid <= 1'b0; arb_lost <= 1'b0;
      err_bit <= 1'b0; err_stuff <= 1'b0; err_crc <= 1'b0; err_form <= 1'b0; err_ack <= 1'b0;
      e_bit = 1'b0; e_stuff = 1'b0; e_form = 1'b0; e_ack = 1'b0; e_crc = 1'b0; no_tec = 1'b0;
      b = rx_s;
      k = pos - crc_ls;

      // ---- host side
      if (tx_valid && !pending) begin
        pending <= 1'b1;
        b_id <= tx_id; b_ide <= tx_ide; b_rtr <= tx_rtr; b_dlc <= tx_dlc; b_data <= tx_data;
      end
      if (tx_abort && pending) abort_req <= 1'b1;
      if (abort_req && pending && !is_tx) begin
        pending <= 1'b0; abort_req <= 1'b0; tx_aborted <= 1'b1;
      end

      // ---- what to drive in the next bit
      if (bit_start) begin
        drv <= 1'b1;
        case (mode)
          M_IDLE: if (pending && !abort_req) begin drv <= 1'b0; is_tx <= 1'b1; end
          M_FRAME:
            if (is_tx) begin
              if (pos <= tx_crc_ls + 8'd1 && run_len == 3'd5) drv <= ~run_val;
              else if (pos <= tx_crc_ls) drv <= tx_bit;
            end else if (pos == crc_ls + 8'd2 && !crc_err) drv <= 1'b0;       // ACK
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
              mode <= M_FRAME; pos <= 8'd1; run_val <= 1'b0; run_len <= 3'd1;
              crc <= '0; crc_err <= 1'b0; f_data <= '0;
              // a pending frame joins at a dominant 3rd intermission bit
              if (mode == M_INTERM) is_tx <= cnt == 3'd2 && pending && !abort_req && !(is_tx && err_passive);
              else if (mode == M_SUSPEND) is_tx <= 1'b0;
              else is_tx <= is_tx || (pending && !abort_req);  // another node's SOF in bus idle
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
            if (pos <= crc_ls + 8'd1 && run_len == 3'd5) begin  // stuff bit
              if (b == run_val) begin
                e_stuff = 1'b1;
                no_tec  = is_tx && drv && in_arb;
              end
              run_val <= b; run_len <= 3'd1;
            end else if (pos <= crc_ls) begin
              if (b == run_val) run_len <= run_len + 3'd1;
              else begin run_val <= b; run_len <= 3'd1; end
              if (is_tx && b != drv) begin
                if (drv && in_arb) begin is_tx <= 1'b0; arb_lost <= 1'b1; end
                else e_bit = 1'b1;
              end
              if (pos <= 8'd11) f_ida <= {f_ida[9:0], b};
              else if (pos == 8'd12) f_b12 <= b;
              else if (pos == 8'd13) f_ide <= b;
              else if (f_ide && pos <= 8'd31) f_idb <= {f_idb[16:0], b};
              else if (f_ide && pos == 8'd32) f_rtr <= b;
              else if ((f_ide && pos >= 8'd35 && pos <= 8'd38) || (!f_ide && pos >= 8'd15 && pos <= 8'd18))
                f_dlc <= {f_dlc[2:0], b};
              else if (known && pos < crc_st) f_data[{di[6:3], 3'b111 - di[2:0]}] <= b;
              if (!known || pos < crc_st) crc <= crc_next(crc, b);
              else if (b != crc[8'd14 - (pos - crc_st)]) crc_err <= 1'b1;
              pos <= pos + 8'd1;
            end else begin
              pos <= pos + 8'd1;
              if (k == 8'd1 && !b) e_form = 1'b1;                       // CRC delimiter
              if (k == 8'd2 && is_tx && b) e_ack = 1'b1;                 // ACK slot
              if (k == 8'd3) begin                                       // ACK delimiter
                if (!b) e_form = 1'b1;
                else if (crc_err) e_crc = 1'b1;
              end
              if (k >= 8'd4 && k <= 8'd9 && !b) e_form = 1'b1;           // EOF 1..6
              if (k == 8'd10 && is_tx && !b) e_form = 1'b1;              // EOF 7
              if (k == 8'd9 && b && !is_tx) begin                        // frame valid (Rx)
                if (rec > 8'd127) rec <= 8'd120;
                else if (rec != 8'd0) rec <= rec - 8'd1;
                if (accept) begin
                  rx_valid <= 1'b1;
                  rx_id <= dec_id; rx_ide <= f_ide; rx_rtr <= dec_rtr;
                  rx_dlc <= f_dlc; rx_data <= f_data;
                end
              end
              if (k == 8'd10 && !(is_tx && !b)) begin                    // frame valid (Tx)
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
          if (is_tx) begin
            if (!(no_tec || (e_ack && err_passive))) begin
              tec <= tec + 9'd8;
              if (tec > 9'd247) begin mode <= M_BUSOFF; is_tx <= 1'b0; rec_run <= '0; occ <= '0; end
            end
          end else if (rec != 8'hFF) rec <= rec + 8'd1;
        end
      end
    end
  end
endmodule
