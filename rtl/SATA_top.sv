// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SATA protocol Open IP -- SATA host: OOB bring-up, link layer with frame
// handshakes, and a built-in DMA command sequencer.
// -- Apache-2.0
// Open IP design implementation v3.0
//
// Implementation scope (scaled, 1 line bit per clk, no 8b/10b):
//  * Line: tx_p/tx_n differential; electrical idle is tx_p = tx_n = 0. On
//    the receive side a clock carries signal when rx_p != rx_n; data bits
//    are taken from rx_p. Dwords are sent LSB first.
//  * OOB: a pattern is 4 bursts of 16 clk of signal, each preceded by a
//    gap of electrical idle: 48 clk for COMRESET / COMINIT, 16 clk for
//    COMWAKE. The receiver classifies each gap between two bursts of 12..20
//    clk (40..56 = INIT gap, 12..20 = WAKE gap); three equal gaps in a row
//    detect COMINIT or COMWAKE.
//  * Host PHY init: COMRESET -> wait COMINIT -> COMWAKE -> wait COMWAKE ->
//    send ALIGNp and lock the receiver on the device's ALIGNp stream (two
//    in a row) -> READY. Each wait times out after 1024 clk and restarts
//    with COMRESET. In READY a clock of electrical idle (signal lost, e.g.
//    the device starting COMINIT) is a link loss (irq) and restarts the
//    bring-up; no dword completes on an idle clock.
//  * Link layer (primitives as dword values; ALIGNp is dropped anywhere):
//    transmit X_RDY -> R_RDY -> SOF, FIS dwords, CRC32, EOF -> WTRM until
//    R_OK (done) or R_ERR (resend, at most 2 resends). Receive X_RDY ->
//    send R_RDY, R_IP during the frame, then R_OK / R_ERR (bad CRC, more
//    than 9 FIS dwords) until SYNC. Idle: SYNC (at least one SYNC dword
//    goes out between two transmitted frames). When both sides raise
//    X_RDY the host backs off and receives first. Handshake waits time out
//    after 64 dwords.
//  * CRC32: poly 32'h04C11DB7 reflected (32'hEDB88320), init all-ones, one
//    dword LSB first per step, complemented on the wire.
//  * Command sequencer (the port contract has no command bus): IDENTIFY
//    DEVICE (Register H2D 8'hEC -> Data FIS of 8 dwords, dword 1 [5:0] =
//    max LBA -> Register D2H), then forever: WRITE DMA EXT of one 8-dword
//    sector (Register H2D 8'h35 -> DMA Activate -> Data FIS -> D2H) with
//    xorshift32 data, READ DMA EXT of the same LBA (8'h25 -> Data FIS ->
//    D2H) compared against the written data, next LBA (wraps after max).
//    A D2H with ERR set or a non-zero error byte ends the command early.
//  * irq: 1-clk pulse on link loss, an illegal primitive between frames,
//    a received frame error (CRC / overflow / aborted / handshake timeout),
//    a transmit failure (resends exhausted / timeout), an unexpected or
//    malformed FIS, a status error, read data mismatch, or a command
//    response timeout (4096 clk).
//  * refclk is kept for interface compatibility; the line clock is clk.
// ============================================================================
module SATA_top (
  input  logic clk,
  input  logic rst_n,
  output logic tx_n,
  output logic tx_p,
  input  logic rx_n,
  input  logic rx_p,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic refclk,      // interface compatibility only
  /* verilator lint_on UNUSEDSIGNAL */
  output logic irq
);
  // ------------------------- primitives / FIS types -------------------------
  localparam logic [31:0] P_ALIGN = 32'h7B4A_4ABC;
  localparam logic [31:0] P_SYNC  = 32'hB5B5_957C;
  localparam logic [31:0] P_XRDY  = 32'h5757_B57C;
  localparam logic [31:0] P_RRDY  = 32'h4A4A_957C;
  localparam logic [31:0] P_RIP   = 32'h5555_B57C;
  localparam logic [31:0] P_ROK   = 32'h3535_B57C;
  localparam logic [31:0] P_RERR  = 32'h5656_B57C;
  localparam logic [31:0] P_SOF   = 32'h3737_B57C;
  localparam logic [31:0] P_EOF   = 32'hD5D5_B57C;
  localparam logic [31:0] P_WTRM  = 32'h5858_B57C;

  localparam logic [7:0] FIS_H2D  = 8'h27;
  localparam logic [7:0] FIS_D2H  = 8'h34;
  localparam logic [7:0] FIS_DACT = 8'h39;
  localparam logic [7:0] FIS_DATA = 8'h46;
  localparam logic [7:0] CMD_ID   = 8'hEC;
  localparam logic [7:0] CMD_RD   = 8'h25;
  localparam logic [7:0] CMD_WR   = 8'h35;

  function automatic logic [31:0] crc32_dw(input logic [31:0] c, input logic [31:0] d);
    logic [31:0] r;
    logic        fb;
    r = c;
    for (int k = 0; k < 32; k++) begin
      fb = r[0] ^ d[k];
      r  = r >> 1;
      if (fb) r = r ^ 32'hEDB8_8320;
    end
    crc32_dw = r;
  endfunction

  function automatic logic [31:0] xorshift(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    xorshift = y ^ (y << 5);
  endfunction

  // ------------------------- OOB detector -------------------------
  wire rx_act = rx_p ^ rx_n;
  logic       act_q;          // previous clock carried signal
  logic [5:0] orun;           // length of the current run (saturates at 63)
  logic       burst_ok;       // the last burst had a legal length
  logic       gcls;           // class of the gaps counted: 0 INIT, 1 WAKE
  logic [1:0] gcnt;           // equal gaps in a row
  logic       det_init, det_wake;

  wire gap_init = (orun >= 6'd40) && (orun <= 6'd56);
  wire gap_wake = (orun >= 6'd12) && (orun <= 6'd20);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_q <= 1'b0; orun <= 6'd0; burst_ok <= 1'b0; gcls <= 1'b0; gcnt <= 2'd0;
      det_init <= 1'b0; det_wake <= 1'b0;
    end else begin
      det_init <= 1'b0;
      det_wake <= 1'b0;
      act_q    <= rx_act;
      if (rx_act == act_q) begin
        if (orun != 6'd63) orun <= orun + 6'd1;
      end else begin
        orun <= 6'd1;
        if (act_q) begin                       // burst ended
          burst_ok <= gap_wake;                // burst length 12..20
          if (!gap_wake) gcnt <= 2'd0;
        end else if (burst_ok && (gap_init || gap_wake)) begin  // gap ended
          if (gcnt != 2'd0 && gcls == gap_wake) begin
            if (gcnt == 2'd2) begin
              gcnt     <= 2'd0;
              det_init <= !gap_wake;
              det_wake <= gap_wake;
            end else gcnt <= gcnt + 2'd1;
          end else begin
            gcls <= gap_wake;
            gcnt <= 2'd1;
          end
        end else gcnt <= 2'd0;
      end
    end
  end

  // ------------------------- PHY bring-up -------------------------
  typedef enum logic [2:0] {LK_RESET, LK_WINIT, LK_WAKE, LK_WWAKE, LK_ALIGN, LK_READY} lk_t;
  lk_t        lk;
  logic [1:0] ob_n;           // burst index of the pattern being sent
  logic       ob_gap;         // 0 burst, 1 gap
  logic [5:0] ob_cnt;
  logic [9:0] ltmr;
  logic       aln1;           // one ALIGNp received
  logic       ev_link;

  wire        dw_on   = (lk == LK_ALIGN) || (lk == LK_READY);
  logic       rx_dw_v;        // a received dword completes this clock
  logic [31:0] rdw;
  wire        loss    = !rx_act;          // READY: signal lost
  wire        ob_last = !ob_gap && (ob_cnt == 6'd15) && (ob_n == 2'd3);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lk <= LK_RESET; ob_n <= 2'd0; ob_gap <= 1'b1; ob_cnt <= 6'd0; ltmr <= 10'd0;
      aln1 <= 1'b0; ev_link <= 1'b0;
    end else begin
      ev_link <= 1'b0;
      if (lk == LK_RESET || lk == LK_WAKE) begin   // OOB pattern: gap, burst x4
        ob_cnt <= ob_cnt + 6'd1;
        if (ob_gap && ob_cnt == ((lk == LK_RESET) ? 6'd47 : 6'd15)) begin
          ob_gap <= 1'b0;
          ob_cnt <= 6'd0;
        end else if (!ob_gap && ob_cnt == 6'd15) begin
          ob_gap <= 1'b1;
          ob_cnt <= 6'd0;
          ob_n   <= ob_n + 2'd1;
        end
      end
      case (lk)
        LK_RESET: if (ob_last) begin lk <= LK_WINIT; ltmr <= 10'd0; end
        LK_WAKE:  if (ob_last) begin lk <= LK_WWAKE; ltmr <= 10'd0; end
        LK_WINIT: begin
          ltmr <= ltmr + 10'd1;
          if (det_init) lk <= LK_WAKE;
          else if (ltmr == 10'd1023) lk <= LK_RESET;
        end
        LK_WWAKE: begin
          ltmr <= ltmr + 10'd1;
          if (det_wake) begin
            lk   <= LK_ALIGN;
            ltmr <= 10'd0;
            aln1 <= 1'b0;
          end else if (ltmr == 10'd1023) lk <= LK_RESET;
        end
        LK_ALIGN: begin
          ltmr <= ltmr + 10'd1;
          if (rx_dw_v) begin
            aln1 <= (rdw == P_ALIGN);
            if (rdw == P_ALIGN && aln1) lk <= LK_READY;
          end
          if (ltmr == 10'd1023 && !(rx_dw_v && rdw == P_ALIGN && aln1)) lk <= LK_RESET;
        end
        default: begin                         // LK_READY
          if (loss) begin
            lk      <= LK_RESET;
            ev_link <= 1'b1;
          end
        end
      endcase
    end
  end

  // ------------------------- dword transmitter -------------------------
  logic [4:0]  tbit;
  logic [31:0] tsr;
  logic [31:0] tx_next;
  wire         tbnd = (lk == LK_READY) && (tbit == 5'd31);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tbit <= 5'd0; tsr <= P_ALIGN;
    end else if (!dw_on) begin
      tbit <= 5'd0; tsr <= P_ALIGN;
    end else begin
      tbit <= tbit + 5'd1;
      tsr  <= (tbit == 5'd31) ? ((lk == LK_READY) ? tx_next : P_ALIGN) : {1'b0, tsr[31:1]};
    end
  end

  wire ob_burst = (lk == LK_RESET || lk == LK_WAKE) && !ob_gap;
  wire tx_bit   = ob_burst ? ob_cnt[0] : tsr[0];
  wire tx_on    = ob_burst || dw_on;
  assign tx_p = tx_on &  tx_bit;
  assign tx_n = tx_on & !tx_bit;

  // ------------------------- dword receiver -------------------------
  logic [30:0] rsr;
  logic [4:0]  rbit;
  logic        aligned;
  assign rdw     = {rx_p, rsr};
  assign rx_dw_v = dw_on && rx_act && (aligned ? (rbit == 5'd31) : (rdw == P_ALIGN));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsr <= 31'd0; rbit <= 5'd0; aligned <= 1'b0;
    end else if (!dw_on) begin
      rsr <= 31'd0; rbit <= 5'd0; aligned <= 1'b0;
    end else begin
      rsr <= rdw[31:1];
      if (!aligned) begin
        if (rdw == P_ALIGN) begin aligned <= 1'b1; rbit <= 5'd0; end
      end else rbit <= rbit + 5'd1;
    end
  end

  // ------------------------- link layer -------------------------
  typedef enum logic [1:0] {R_IDLE, R_RDYS, R_DATA, R_STAT} rxs_t;
  typedef enum logic [2:0] {T_IDLE, T_XRDY, T_SOF, T_DATA, T_CRC, T_EOF, T_WTRM} txs_t;
  rxs_t        rxs;
  txs_t        txs;
  logic [5:0]  rx_dwt, tx_dwt;  // handshake timeouts (dwords)
  logic [3:0]  rn;              // dwords received in the frame (incl. CRC)
  logic        ovf, rok;
  logic [31:0] rc, rcp, rlast;  // running CRC, CRC before the last dword
  logic [31:0] rbuf [0:8];
  logic [3:0]  tx_idx;
  logic [31:0] tcrc;
  logic [1:0]  tretry;
  logic        fis_v;           // good FIS received (rbuf, rn-1 dwords)
  logic        tx_ok, tx_fail;
  logic        ev_rx, ev_tx;
  // from the sequencer
  logic        fis_req;
  logic        fis_last;        // tx_idx is the last FIS dword
  logic [31:0] fis_dw;          // FIS dword tx_idx

  wire rp       = (lk == LK_READY) && rx_dw_v && (rdw != P_ALIGN);
  wire rx_xrdy  = rp && (rdw == P_XRDY) && (rxs == R_IDLE) &&
                  (txs == T_IDLE || txs == T_XRDY);
  wire rx_known = (rdw == P_SYNC) || (rdw == P_XRDY) || (rdw == P_RRDY) || (rdw == P_RIP) ||
                  (rdw == P_ROK) || (rdw == P_RERR) || (rdw == P_WTRM);

  always_comb begin
    case (txs)
      T_XRDY: tx_next = P_XRDY;
      T_SOF:  tx_next = P_SOF;
      T_DATA: tx_next = fis_dw;
      T_CRC:  tx_next = ~tcrc;
      T_EOF:  tx_next = P_EOF;
      T_WTRM: tx_next = P_WTRM;
      default:
        case (rxs)
          R_RDYS:  tx_next = P_RRDY;
          R_DATA:  tx_next = P_RIP;
          R_STAT:  tx_next = rok ? P_ROK : P_RERR;
          default: tx_next = P_SYNC;
        endcase
    endcase
  end

  // receive side
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxs <= R_IDLE; rx_dwt <= 6'd0; rn <= 4'd0; ovf <= 1'b0; rok <= 1'b0;
      rc <= 32'd0; rcp <= 32'd0; rlast <= 32'd0; fis_v <= 1'b0; ev_rx <= 1'b0;
      for (int i = 0; i < 9; i++) rbuf[i] <= 32'd0;
    end else begin
      fis_v <= 1'b0;
      ev_rx <= 1'b0;
      if (lk != LK_READY) rxs <= R_IDLE;
      else if (rp)
        case (rxs)
          R_IDLE: begin
            if (rx_xrdy) begin rxs <= R_RDYS; rx_dwt <= 6'd0; end
            else if (!rx_known) ev_rx <= 1'b1;          // illegal primitive
          end
          R_RDYS: begin
            rx_dwt <= rx_dwt + 6'd1;
            if (rdw == P_SOF) begin
              rxs <= R_DATA; rn <= 4'd0; ovf <= 1'b0; rc <= 32'hFFFF_FFFF;
            end else if (rdw == P_SYNC) rxs <= R_IDLE;   // device withdrew
            else if (rx_dwt == 6'd63) begin rxs <= R_IDLE; ev_rx <= 1'b1; end
          end
          R_DATA: begin
            if (rdw == P_EOF) begin
              rxs    <= R_STAT;
              rx_dwt <= 6'd0;
              rok    <= !ovf && (rn >= 4'd2) && (rlast == ~rcp);
              if (!ovf && (rn >= 4'd2) && (rlast == ~rcp)) fis_v <= 1'b1;
              else ev_rx <= 1'b1;                        // CRC error / overflow
            end else if (rdw == P_SYNC) begin
              rxs <= R_IDLE; ev_rx <= 1'b1;              // frame aborted
            end else begin
              if (rn == 4'd10) ovf <= 1'b1;
              else rn <= rn + 4'd1;
              if (rn < 4'd9) rbuf[rn] <= rdw;
              rlast <= rdw;
              rcp   <= rc;
              rc    <= crc32_dw(rc, rdw);
            end
          end
          default: begin                                 // R_STAT
            rx_dwt <= rx_dwt + 6'd1;
            if (rdw == P_SYNC) rxs <= R_IDLE;
            else if (rx_dwt == 6'd63) begin rxs <= R_IDLE; ev_rx <= 1'b1; end
          end
        endcase
    end
  end

  // transmit side
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      txs <= T_IDLE; tx_dwt <= 6'd0; tx_idx <= 4'd0; tcrc <= 32'd0; tretry <= 2'd0;
      tx_ok <= 1'b0; tx_fail <= 1'b0; ev_tx <= 1'b0;
    end else begin
      tx_ok   <= 1'b0;
      tx_fail <= 1'b0;
      ev_tx   <= 1'b0;
      if (lk != LK_READY) begin
        txs <= T_IDLE; tretry <= 2'd0;
      end else
        case (txs)
          // leave idle on a dword boundary, so at least one SYNC goes out first
          T_IDLE: if (tbnd && fis_req && !tx_ok && !tx_fail && rxs == R_IDLE && !rx_xrdy) begin
            txs <= T_XRDY; tx_dwt <= 6'd0;
          end
          T_XRDY: begin
            if (rx_xrdy) txs <= T_IDLE;                  // collision: device first
            else if (rp && rdw == P_RRDY) txs <= T_SOF;
            else if (tbnd) begin
              tx_dwt <= tx_dwt + 6'd1;
              if (tx_dwt == 6'd63) begin
                txs <= T_IDLE; tx_fail <= 1'b1; ev_tx <= 1'b1; tretry <= 2'd0;
              end
            end
          end
          T_SOF: if (tbnd) begin
            txs <= T_DATA; tx_idx <= 4'd0; tcrc <= 32'hFFFF_FFFF;
          end
          T_DATA: if (tbnd) begin
            tcrc   <= crc32_dw(tcrc, fis_dw);
            tx_idx <= tx_idx + 4'd1;
            if (fis_last) txs <= T_CRC;
          end
          T_CRC: if (tbnd) txs <= T_EOF;
          T_EOF: if (tbnd) begin txs <= T_WTRM; tx_dwt <= 6'd0; end
          default: begin                                 // T_WTRM
            if (rp && rdw == P_ROK) begin
              txs <= T_IDLE; tx_ok <= 1'b1; tretry <= 2'd0;
            end else if (rp && rdw == P_RERR) begin
              txs <= T_IDLE;
              if (tretry == 2'd2) begin
                tx_fail <= 1'b1; ev_tx <= 1'b1; tretry <= 2'd0;
              end else tretry <= tretry + 2'd1;          // resend
            end else if (tbnd) begin
              tx_dwt <= tx_dwt + 6'd1;
              if (tx_dwt == 6'd63) begin
                txs <= T_IDLE; tx_fail <= 1'b1; ev_tx <= 1'b1; tretry <= 2'd0;
              end
            end
          end
        endcase
    end
  end

  // ------------------------- command sequencer -------------------------
  typedef enum logic [3:0] {
    Q_WAIT, Q_ID, Q_ID_DAT, Q_ID_STS, Q_FILL, Q_WR, Q_WR_ACT, Q_WR_DAT, Q_WR_STS,
    Q_RD, Q_RD_DAT, Q_RD_STS
  } q_t;
  q_t          q;
  logic [1:0]  qc;              // Register H2D command: 0 IDENTIFY, 1 WRITE, 2 READ
  logic        qdata;           // FIS to send: 0 Register H2D, 1 Data
  logic [5:0]  lba, max_lba;
  logic [31:0] xs;              // xorshift32 data generator
  logic [31:0] wbuf [0:7];
  logic [2:0]  fk;
  logic [11:0] ctmr;
  logic        ev_cmd;

  always_comb begin
    if (qdata) fis_dw = (tx_idx == 4'd0) ? {24'd0, FIS_DATA} : wbuf[tx_idx[2:0] - 3'd1];
    else
      case (tx_idx)
        4'd0:    fis_dw = {8'h00, (qc == 2'd0) ? CMD_ID : (qc == 2'd1) ? CMD_WR : CMD_RD,
                           8'h80, FIS_H2D};
        4'd1:    fis_dw = {8'h40, 18'd0, lba};
        4'd3:    fis_dw = 32'h0000_0001;            // one sector
        default: fis_dw = 32'd0;
      endcase
  end
  assign fis_last = (tx_idx == (qdata ? 4'd8 : 4'd4));

  wire [7:0] r_type = rbuf[0][7:0];
  wire       r_d2h  = r_type == FIS_D2H  && rn == 4'd6;
  wire       r_dat  = r_type == FIS_DATA && rn == 4'd10;
  wire       r_act  = r_type == FIS_DACT && rn == 4'd2;
  wire       s_ok   = !rbuf[0][16] && (rbuf[0][31:24] == 8'd0);   // ERR clear, no error
  wire       resp   = fis_v || (ctmr == 12'hFFF);                 // FIS or timeout
  wire [5:0] lba_nx = (lba == max_lba) ? 6'd0 : lba + 6'd1;
  wire       q_dev  = (q == Q_ID_DAT) || (q == Q_ID_STS) || (q == Q_WR_ACT) ||
                      (q == Q_WR_STS) || (q == Q_RD_DAT) || (q == Q_RD_STS);
  logic      rd_bad;
  always_comb begin
    rd_bad = 1'b0;
    for (int i = 0; i < 8; i++) if (rbuf[i + 1] != wbuf[i]) rd_bad = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= Q_WAIT; qc <= 2'd0; qdata <= 1'b0; lba <= 6'd0; max_lba <= 6'd0;
      xs <= 32'h2545_F491; fk <= 3'd0; ctmr <= 12'd0; fis_req <= 1'b0; ev_cmd <= 1'b0;
      for (int i = 0; i < 8; i++) wbuf[i] <= 32'd0;
    end else begin
      ev_cmd <= 1'b0;
      if (tx_ok || tx_fail) fis_req <= 1'b0;
      ctmr <= ctmr + 12'd1;
      if (lk != LK_READY) begin
        q <= Q_WAIT; fis_req <= 1'b0;
      end else begin
        if (fis_v && !q_dev) ev_cmd <= 1'b1;              // unsolicited FIS
        case (q)
          Q_WAIT: begin
            q <= Q_ID; qc <= 2'd0; qdata <= 1'b0; fis_req <= 1'b1;
          end
          Q_ID:
            if (tx_ok) begin q <= Q_ID_DAT; ctmr <= 12'd0; end
            else if (tx_fail) fis_req <= 1'b1;            // try again
          Q_ID_DAT: if (resp) begin
            if (fis_v && r_dat) begin
              q <= Q_ID_STS; ctmr <= 12'd0; max_lba <= rbuf[1][5:0];
            end else begin                                // restart IDENTIFY
              q <= Q_ID; fis_req <= 1'b1; ev_cmd <= 1'b1;
            end
          end
          Q_ID_STS: if (resp) begin
            if (fis_v && r_d2h && s_ok) begin
              q <= Q_FILL; lba <= 6'd0; fk <= 3'd0;
            end else begin
              q <= Q_ID; fis_req <= 1'b1; ev_cmd <= 1'b1;
            end
          end
          Q_FILL: begin                                   // next sector of write data
            wbuf[fk] <= xs;
            xs <= xorshift(xs);
            fk <= fk + 3'd1;
            if (fk == 3'd7) begin
              q <= Q_WR; qc <= 2'd1; qdata <= 1'b0; fis_req <= 1'b1;
            end
          end
          Q_WR:
            if (tx_ok) begin q <= Q_WR_ACT; ctmr <= 12'd0; end
            else if (tx_fail) begin q <= Q_FILL; fk <= 3'd0; lba <= lba_nx; end
          Q_WR_ACT: if (resp) begin
            if (fis_v && r_act) begin
              q <= Q_WR_DAT; qdata <= 1'b1; fis_req <= 1'b1;
            end else begin                                // error D2H, wrong FIS, timeout
              q <= Q_FILL; fk <= 3'd0; lba <= lba_nx; ev_cmd <= 1'b1;
            end
          end
          Q_WR_DAT:
            if (tx_ok) begin q <= Q_WR_STS; ctmr <= 12'd0; end
            else if (tx_fail) begin q <= Q_FILL; fk <= 3'd0; lba <= lba_nx; end
          Q_WR_STS: if (resp) begin
            if (fis_v && r_d2h && s_ok) begin
              q <= Q_RD; qc <= 2'd2; qdata <= 1'b0; fis_req <= 1'b1;
            end else begin
              q <= Q_FILL; fk <= 3'd0; lba <= lba_nx; ev_cmd <= 1'b1;
            end
          end
          Q_RD:
            if (tx_ok) begin q <= Q_RD_DAT; ctmr <= 12'd0; end
            else if (tx_fail) begin q <= Q_FILL; fk <= 3'd0; lba <= lba_nx; end
          Q_RD_DAT: if (resp) begin
            if (fis_v && r_dat) begin
              q <= Q_RD_STS; ctmr <= 12'd0;
              if (rd_bad) ev_cmd <= 1'b1;                 // data mismatch
            end else begin
              q <= Q_FILL; fk <= 3'd0; lba <= lba_nx; ev_cmd <= 1'b1;
            end
          end
          default: if (resp) begin                        // Q_RD_STS
            q <= Q_FILL; fk <= 3'd0; lba <= lba_nx;
            if (!(fis_v && r_d2h && s_ok)) ev_cmd <= 1'b1;
          end
        endcase
      end
    end
  end

  assign irq = ev_link | ev_rx | ev_tx | ev_cmd;

endmodule
