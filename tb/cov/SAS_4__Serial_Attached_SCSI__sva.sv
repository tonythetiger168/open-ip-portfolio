// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// SAS-4 block-coded link: a cycle-level model fed only by the pins predicts
// tx_p, tx_n, link_up and irq on every clock. The OOB side is a phase /
// timer pair with a run-length burst detector. The transmitter is modelled
// per block: whole frames (SOF, header, payload, CRC, EOF, idle) are built
// when they are chosen and each block is pre-scrambled into its 130 line
// bits. The receiver hunts and decodes blocks bit by bit, and the initiator
// sequencer runs write + read-verify with the xorshift32 data stream.
`include "cov_macros.svh"
module SAS_4__Serial_Attached_SCSI__sva (
  input logic clk, rst_n, rx_p, tx_p, tx_n, link_up, irq
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [1:0]  SHD = 2'b01, SHC = 2'b10;
  localparam logic [31:0] IDLE = 32'hA5C3_0000, SOF = 32'hA5C3_0001, EOF = 32'hA5C3_0002;
  localparam logic [15:0] SEED = 16'hACE1;
  // sequencer steps
  localparam int Q_INIT = 0, Q_WR = 1, Q_WRW = 2, Q_RD = 3, Q_RDW = 4, Q_GAP = 5;
  // receive frame steps
  localparam int R_SOF = 0, R_HDR = 1, R_PAY = 2, R_CRC = 3, R_EOF = 4;

  function automatic logic [31:0] crc_blk(input logic [31:0] c, input logic [127:0] b);
    for (int k = 127; k >= 0; k -= 32)
      for (int y = 0; y < 32; y += 8)          // bytes MSB first, bits LSB first
        for (int i = 0; i < 8; i++)
          c = (c >> 1) ^ ((c[0] ^ b[k - 31 + (24 - y) + i]) ? 32'hEDB8_8320 : 32'h0);
    crc_blk = c;
  endfunction
  function automatic logic [31:0] xsh(input logic [31:0] x);
    x = x ^ (x << 13); x = x ^ (x >> 17); xsh = x ^ (x << 5);
  endfunction
  // scramble one block: returns {scrambler state after, 130 line bits}
  function automatic logic [145:0] enc(input logic [1:0] sh, input logic [127:0] p,
                                       input logic [15:0] s);
    logic [129:0] l;
    l[129:128] = sh;
    for (int i = 127; i >= 0; i--) begin
      l[i] = p[i] ^ s[15] ^ s[4];
      s = {s[14:0], l[i]};
    end
    enc = {s, l};
  endfunction

  // ------------------------------------------------------------------ OOB
  logic [6:0] run;
  logic       det, ready, loss;
  int         ph, tmr;
  bit         seen;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin run <= 0; det <= 0; end
    else begin
      det <= !rx_p && run >= 64;
      run <= !rx_p ? 7'd0 : (run == 7'd127) ? run : run + 7'd1;
    end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n || loss) begin                 // loss of sync restarts the handshake
      ph <= 0; tmr <= 0; seen <= 0; ready <= 0;
    end else if (ph == 0 || ph == 2) begin    // own burst
      tmr <= (tmr == 105) ? 0 : tmr + 1;
      if (tmr == 105) begin ph <= ph + 1; seen <= 0; end
    end else if (ph != 4) begin               // answer window
      if (det) seen <= 1;
      tmr <= (tmr == 317) ? 0 : tmr + 1;
      if (tmr == 317) begin
        ph <= !seen ? ph - 1 : ph + 1;
        if (seen && ph == 3) ready <= 1;
      end
    end
  wire drive = ph == 0 || ph == 2;

  // ------------------------------------------------------------ receiver
  logic [7:0]   rc;                           // bit in block
  logic [1:0]   rsh;
  logic [126:0] rp;
  logic [15:0]  ds;
  int           bad;                          // consecutive bad headers (locked)
  int           good;                         // good headers while hunting (sat. 3)
  bit           code, locked;
  int           fs;
  logic [7:0]   f_ty, f_dst, f_src;
  logic [3:0]   f_len;
  logic [31:0]  f_crc, f_d0;
  bit           f_two, f_ok;
  logic [31:0]  rf [0:15];
  // events
  bit           e_wr, e_rsp, e_rq, e_crc, e_proto;
  logic [31:0]  rsp_val, rq_data;
  logic [7:0]   rq_dst;
  logic [3:0]   rq_src;
  // coverage flags
  bit v_slip, v_lock_wait_code, v_hdr_ctrl, v_len_big, v_pay_ctrl, v_two_blk, v_crc_ctrl, v_crc_bad,
      v_eof_bad, v_wr0, v_wr_dst, v_rd_dst, v_rsp0, v_type, v_viol_recover, v_wr_ok, v_rq_ok, v_rsp_in;

  wire          db  = rx_p ^ ds[15] ^ ds[4];
  wire [127:0]  b   = {rp, db};
  wire [1:0]    hdr = {rsh[1], rx_p};
  wire          hok = hdr == SHD || hdr == SHC;
  wire          ctl = rsh == SHC;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rc <= 0; rsh <= 0; rp <= 0; ds <= SEED; bad <= 0; good <= 0; code <= 0; locked <= 0;
      loss <= 0; fs <= R_SOF; f_ty <= 0; f_dst <= 0; f_src <= 0; f_len <= 0; f_crc <= 0;
      f_d0 <= 0; f_two <= 0; f_ok <= 0; rsp_val <= 0; rq_data <= 0; rq_dst <= 0; rq_src <= 0;
      {e_wr, e_rsp, e_rq, e_crc, e_proto} <= '0;
      for (int i = 0; i < 16; i++) rf[i] <= 0;
    end else if (!ready) begin
      rc <= 0; rsh <= 0; ds <= SEED; bad <= 0; good <= 0; code <= 0; locked <= 0;
      loss <= 0; fs <= R_SOF;
      {e_wr, e_rsp, e_rq, e_crc, e_proto} <= '0;
    end else begin
      {e_wr, e_rsp, e_rq, e_crc, e_proto} <= '0;
      {v_slip, v_lock_wait_code, v_hdr_ctrl, v_len_big, v_pay_ctrl, v_two_blk, v_crc_ctrl,
       v_crc_bad, v_eof_bad, v_wr0, v_wr_dst, v_rd_dst, v_rsp0, v_type, v_viol_recover,
       v_wr_ok, v_rq_ok, v_rsp_in} = '0;
      loss <= 0;
      if (rc == 0) begin rsh[1] <= rx_p; rc <= 1; end
      else if (rc == 1) begin
        rsh[0] <= rx_p;
        if (!hok && !locked) begin            // hunting: slip one bit
          v_slip = 1;
          rsh[1] <= rx_p; good <= 0; code <= 0;
        end else begin
          rc <= 2;
          bad <= hok ? 0 : bad + 1;
          v_viol_recover = hok && bad != 0;
          if (!hok && bad == 7) begin loss <= 1; locked <= 0; end
          if (hok && !locked) begin
            v_lock_wait_code = good == 3 && !code;
            if (good == 3 && code) locked <= 1;
            else if (good != 3) good <= good + 1;
          end
        end
      end else begin
        ds <= {ds[14:0], rx_p};
        rp <= {rp[125:0], db};
        rc <= (rc == 129) ? 8'd0 : rc + 8'd1;
        if (rc == 129 && !locked && ctl && (b[127:96] == IDLE || b[127:96] == SOF ||
                                            b[127:96] == EOF))
          code <= 1;
        if (rc == 129 && locked && (rsh == SHD || ctl))
          case (fs)
            R_SOF: if (ctl && b[127:96] == SOF) fs <= R_HDR;
            R_HDR: if (ctl || b[7:0] > 8) begin
                     e_proto <= 1; fs <= R_SOF; v_hdr_ctrl = ctl; v_len_big = !ctl;
                   end else begin
                     f_ty <= b[103:96]; f_dst <= b[71:64]; f_src <= b[39:32]; f_len <= b[3:0];
                     f_crc <= crc_blk(32'hFFFF_FFFF, b); f_two <= 0;
                     fs <= (b[3:0] == 0) ? R_CRC : R_PAY;
                   end
            R_PAY: if (ctl) begin e_proto <= 1; fs <= R_SOF; v_pay_ctrl = 1; end
                   else begin
                     if (!f_two) f_d0 <= b[127:96];
                     f_crc <= crc_blk(f_crc, b);
                     if (f_len > 4 && !f_two) f_two <= 1;
                     else fs <= R_CRC;
                     v_two_blk = f_two;
                   end
            R_CRC: begin
              fs <= R_EOF; f_ok <= 0;
              if (ctl) begin e_proto <= 1; v_crc_ctrl = 1; end
              else if (b[127:96] != ~f_crc) begin e_crc <= 1; v_crc_bad = 1; end
              else f_ok <= 1;
            end
            default: begin
              fs <= R_SOF;
              if (!(ctl && b[127:96] == EOF)) begin e_proto <= 1; v_eof_bad = 1; end
              else if (!f_ok) ;
              else if (f_ty == 8'h01) begin
                if (f_len == 0 || f_dst > 15) begin
                  e_proto <= 1; v_wr0 = f_len == 0; v_wr_dst = f_dst > 15;
                end else begin rf[f_dst[3:0]] <= f_d0; e_wr <= 1; v_wr_ok = 1; end
              end else if (f_ty == 8'h02) begin
                if (f_dst > 15) begin e_proto <= 1; v_rd_dst = 1; end
                else begin
                  e_rq <= 1; rq_dst <= f_src; rq_src <= f_dst[3:0]; rq_data <= rf[f_dst[3:0]];
                  v_rq_ok = 1;
                end
              end else if (f_ty == 8'h83) begin
                if (f_len == 0) begin e_proto <= 1; v_rsp0 = 1; end
                else begin e_rsp <= 1; rsp_val <= f_d0; v_rsp_in = 1; end
              end else begin e_proto <= 1; v_type = 1; end
            end
          endcase
      end
    end

  // ------------------------------------------------------------ sequencer
  int          q, qt, gap;
  logic [3:0]  qa;
  logic [31:0] qd;
  bit          ack, e_tmo, e_mm;
  bit          v_tmo_wr, v_tmo_rd, v_mm;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      q <= Q_INIT; qt <= 0; gap <= 0; qa <= 0; qd <= 32'h5A5A_0001; e_tmo <= 0; e_mm <= 0;
    end else if (!ready) begin
      q <= Q_INIT; qt <= 0; gap <= 0; e_tmo <= 0; e_mm <= 0;
    end else begin
      e_tmo <= 0; e_mm <= 0;
      {v_tmo_wr, v_tmo_rd, v_mm} = '0;
      case (q)
        Q_INIT: begin
          gap <= (!locked || gap == 63) ? 0 : gap + 1;
          if (locked && gap == 63) q <= Q_WR;
        end
        Q_WR, Q_RD: begin qt <= 0; if (ack) q <= q + 1; end
        Q_WRW: if (e_wr || qt == 4095) begin
                 q <= Q_RD; e_tmo <= !e_wr; v_tmo_wr = !e_wr;
               end else qt <= qt + 1;
        Q_RDW: if (e_rsp || qt == 4095) begin
                 e_tmo <= !e_rsp; e_mm <= e_rsp && rsp_val != qd;
                 v_tmo_rd = !e_rsp; v_mm = e_rsp && rsp_val != qd;
                 qd <= xsh(qd); qa <= qa + 1; gap <= 0; q <= Q_GAP;
               end else qt <= qt + 1;
        default: begin
          gap <= (gap == 31) ? 0 : gap + 1;
          if (gap == 31) q <= Q_WR;
        end
      endcase
    end

  // ---------------------------------------------------------- transmitter
  logic [129:0] line;                         // block on the wire
  logic [15:0]  sc;                           // scrambler state after it
  logic [7:0]   tc;
  logic         tb;
  logic [129:0] fq [0:4];                     // rest of the current frame (sync + payload)
  int           fn, fi;
  bit           pend;
  bit           v_pend, v_rsp_peer;

  function automatic logic [129:0] blk(input logic [1:0] sh, input logic [127:0] p);
    blk = {sh, p};
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n || !ready) begin
      {sc, line} <= enc(SHC, {IDLE, 96'd0}, SEED);
      tc <= 0; tb <= 0; fn <= 0; fi <= 0; ack <= 0; pend <= 0;
    end else begin : tx
      logic [129:0] nb;
      logic [7:0] ty, dst;
      logic [3:0] src;
      logic [31:0] d, c;
      bit one, go, rsp;
      {v_pend, v_rsp_peer} = '0;
      ack <= 0;
      if (e_rq) pend <= 1;
      tb <= line[129 - tc];
      tc <= (tc == 129) ? 8'd0 : tc + 8'd1;
      if (tc == 129) begin
        rsp = pend || e_rq;
        go  = rsp || q == Q_WR || q == Q_RD;
        nb  = blk(SHC, {IDLE, 96'd0});
        if (fi < fn) begin nb = fq[fi]; fi <= fi + 1; end
        else if (go) begin
          ty  = rsp ? 8'h83 : (q == Q_RD) ? 8'h02 : 8'h01;
          dst = rsp ? rq_dst : {4'd0, qa};
          src = rsp ? rq_src : 4'd1;
          d   = rsp ? rq_data : qd;
          one = ty != 8'h02;
          fq[0] = blk(SHD, {24'd0, ty, 24'd0, dst, 28'd0, src, 31'd0, one});
          c = crc_blk(32'hFFFF_FFFF, fq[0][127:0]);
          if (one) begin
            fq[1] = blk(SHD, {d, 96'd0});
            c = crc_blk(c, fq[1][127:0]);
          end
          fq[1 + one] = blk(SHD, {~c, 96'd0});
          fq[2 + one] = blk(SHC, {EOF, 96'd0});
          fq[3 + one] = blk(SHC, {IDLE, 96'd0});
          fn <= 4 + one; fi <= 0;
          nb = blk(SHC, {SOF, 96'd0});
          if (rsp) begin
            pend <= 0; v_pend = pend; v_rsp_peer = rq_dst != 1;
          end else ack <= 1;
        end
        {sc, line} <= enc(nb[129:128], nb[127:0], sc);
      end
    end

  logic m_irq;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) m_irq <= 0;
    else m_irq <= e_crc | e_proto | e_tmo | e_mm | loss;

  wire m_tx = ready ? tb : drive;

  `SVA_RST(a_reset_outputs, !rst_n, !tx_p && tx_n && !link_up && !irq)
  `SVA_INV(a_tx_p, tx_p == m_tx)
  `SVA_INV(a_tx_n, tx_n == !tx_p)
  `SVA_INV(a_link_up, link_up == ready)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_NXT(a_link_drop_irq, link_up && loss, !link_up && irq)

  `FC(oob_comreset_unanswered, ph == 1 && tmr == 317 && !seen)
  `FC(oob_cominit_unanswered, ph == 3 && tmr == 317 && !seen)
  `FC(oob_long_burst, run == 127)
  `FC(link_up, $rose(ready))
  `FC(hunt_bit_slip, v_slip)
  `FC(lock_waits_for_control_code, v_lock_wait_code)
  `FC(rx_header_is_control, v_hdr_ctrl)
  `FC(rx_len_over_8, v_len_big)
  `FC(rx_payload_is_control, v_pay_ctrl)
  `FC(rx_two_payload_blocks, v_two_blk)
  `FC(rx_crc_is_control, v_crc_ctrl)
  `FC(rx_crc_error, v_crc_bad)
  `FC(rx_eof_missing, v_eof_bad)
  `FC(rx_write_len0, v_wr0)
  `FC(rx_write_dst_out_of_range, v_wr_dst)
  `FC(rx_read_dst_out_of_range, v_rd_dst)
  `FC(rx_response_len0, v_rsp0)
  `FC(rx_unknown_type, v_type)
  `FC(rx_write, v_wr_ok)
  `FC(rx_read_request, v_rq_ok)
  `FC(rx_read_response, v_rsp_in)
  `FC(sync_violation_recovered, v_viol_recover)
  `FC(loss_of_sync, loss)
  `FC(response_queued_behind_frame, v_pend)
  `FC(response_request_replaced, ready && e_rq && pend)
  `FC(response_to_other_sas_address, v_rsp_peer)
  `FC(sequencer_write_timeout, v_tmo_wr)
  `FC(sequencer_read_timeout, v_tmo_rd)
  `FC(read_verify_mismatch, v_mm)
  `FC(sequencer_gap_ends_on_block_boundary, ready && q == Q_GAP && gap == 31 && tc == 129)
  `FC(sequencer_address_wrap, q == Q_RDW && e_rsp && qa == 4'hF)
  `FC_RST(reset_with_link_up, link_up ##1 !rst_n)
endmodule

bind SAS_4__Serial_Attached_SCSI__top SAS_4__Serial_Attached_SCSI__sva u_sva (.*);
