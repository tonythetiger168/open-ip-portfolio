// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SAS-4 (Serial Attached SCSI, 24G) -- 128b/150b-style block-coded link layer
// initiator IP.  Distinct from SAS_top (NRZ + dword link): this core
// implements a 128b/150b-style block code and a self-synchronous scrambler.
//
// Implementation scope (simplified, NOT the full SPL specification):
//  - Block code: 2-bit sync header (2'b01 = data block, 2'b10 = control
//    block) + 128-bit payload block = 130 bits/block, MSB first, 1 bit/clk.
//    Sync header bits are never scrambled (64b/66b-style); payloads are.
//  - Scrambler: self-synchronous.  SAS-4 specifies x^58+x^39+1; simplified
//    here to x^16+x^5+1 (noted): obit = dbit ^ s[15] ^ s[4], s <<= obit.
//    The same LFSR stream runs continuously across all block payloads
//    (idle blocks included), so the line never carries plaintext.
//  - Frame format: SOF control block + header data block {type,dst,src,len}
//    (one 32-bit dword per field, value in low 8 bits) + payload data
//    block(s) (len <= 8 dwords, zero padded to 4-dword blocks) + CRC32 data
//    block (dword0 = CRC, poly 0x04C11DB7 reflected, init/xorout all-ones,
//    covering header + padded payload blocks) + EOF control block.
//    Idle control blocks are sent between frames.  A received frame takes
//    effect only once its EOF block arrives.  The transmitter only
//    sends len 0 / 1 frames; the receiver accepts len 0..8.
//  - OOB: SNW-style burst/idle handshake (106 clk burst, 318 clk idle,
//    >=64 clk run detect) -> PHY READY (link_up).  No burst answered in an
//    idle window repeats the previous burst.
//  - Block lock: 4 consecutive valid sync headers plus one legal control
//    code while hunting; an invalid header while hunting slips one bit.
//  - Loss of sync: 8 consecutive invalid sync headers (2'b00/2'b11) while
//    locked -> loss_sync: irq pulse, link_down and full re-OOB.
//  - Functional unit: 16x32 register file.  type 8'h01 = write (payload[0]),
//    8'h02 = read request (answered with a read response to the sender),
//    8'h83 = read response (payload[0] = reg value).  One read response
//    can wait for the transmitter; a newer request replaces it.  A built-in initiator
//    sequencer runs write + read-verify transactions with xorshift32 data
//    against a looped-back (reflecting) link partner. It takes only the
//    write of its own register and the read response from it; anything
//    else (a late frame of a timed-out transaction, another node's) is
//    ignored.
//  - irq: 1-clk pulse on CRC error, protocol violation, sequencer timeout,
//    read-verify mismatch or loss of sync.
//  NOTE: clk is used as the line bit clock (1 bit/clk).  rx_n is the
//  inverted companion of rx_p and is unused by this single-ended model.
// IP design implementation v2.0 -- Apache-2.0
// ============================================================================
module SAS_4__Serial_Attached_SCSI__top (
  input  logic           clk,
  input  logic           rst_n,
  output logic           tx_p,
  output logic           tx_n,
  input  logic           rx_p,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic           rx_n,         // differential companion, unused
  /* verilator lint_on UNUSEDSIGNAL */
  output logic           link_up,
  output logic           irq
);

  // ------------------------- constants -------------------------------------
  localparam logic [1:0]  SH_DATA   = 2'b01;        // data block sync header
  localparam logic [1:0]  SH_CTRL   = 2'b10;        // control block sync header
  localparam logic [31:0] CODE_IDLE = 32'hA5C3_0000; // idle control block code
  localparam logic [31:0] CODE_SOF  = 32'hA5C3_0001; // SOF control block code
  localparam logic [31:0] CODE_EOF  = 32'hA5C3_0002; // EOF control block code
  localparam logic [15:0] SCR_SEED  = 16'hACE1;      // scrambler seed
  localparam int          OOB_BURST   = 106;         // OOB burst length (clks)
  localparam int          OOB_IDLE    = 318;         // OOB idle length (clks)
  localparam int          OOB_DET_MIN = 64;          // min burst run to detect
  localparam logic [11:0] SQ_TMO      = 12'hFFF;     // sequencer response timeout
  localparam logic [7:0]  T_WRITE     = 8'h01;       // register write
  localparam logic [7:0]  T_RDREQ     = 8'h02;       // register read request
  localparam logic [7:0]  T_RDRSP     = 8'h83;       // register read response

  // ------------------------- CRC32 (poly 04C11DB7 reflected) ----------------
  function automatic logic [31:0] crc32_dw(input logic [31:0] crc,
                                           input logic [31:0] dw);
    logic [31:0] c;
    begin
      c = crc;
      for (int b = 3; b >= 0; b--) begin          // dword bytes, MSB byte first
        for (int i = 0; i < 8; i++) begin         // LSB-first within byte
          if (c[0] ^ dw[b*8+i]) c = (c >> 1) ^ 32'hEDB88320;
          else                  c = (c >> 1);
        end
      end
      crc32_dw = c;
    end
  endfunction

  // CRC step over one 128-bit data-block payload (4 dwords)
  function automatic logic [31:0] crc4(input logic [31:0] crc,
                                       input logic [31:0] d0,
                                       input logic [31:0] d1,
                                       input logic [31:0] d2,
                                       input logic [31:0] d3);
    crc4 = crc32_dw(crc32_dw(crc32_dw(crc32_dw(crc, d0), d1), d2), d3);
  endfunction

  function automatic logic [31:0] xorshift32(input logic [31:0] x);
    logic [31:0] y;
    begin
      y = x ^ (x << 13);
      y = y ^ (y >> 17);
      xorshift32 = y ^ (y << 5);
    end
  endfunction

  // ------------------------- OOB FSM ----------------------------------------
  typedef enum logic [2:0] {
    OB_CR_BURST, OB_CR_IDLE, OB_CI_BURST, OB_CI_IDLE, OB_DONE
  } oob_t;
  oob_t        oob_state;
  logic [8:0]  oob_cnt;
  logic        oob_seen;            // answer burst seen in this idle window
  logic        phy_ready;
  logic        loss_sync;             // from RX: 8 bad sync headers

  // RX burst-run monitor (used during OOB)
  logic [6:0]  brun;
  logic        oob_det;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      brun    <= 7'd0;
      oob_det <= 1'b0;
    end else begin
      oob_det <= 1'b0;
      if (rx_p) begin
        if (brun != 7'h7F) brun <= brun + 7'd1;
      end else begin
        if (brun >= 7'(OOB_DET_MIN)) oob_det <= 1'b1;
        brun <= 7'd0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      oob_state <= OB_CR_BURST;
      oob_cnt   <= 9'd0;
      oob_seen  <= 1'b0;
      phy_ready <= 1'b0;
    end else if (loss_sync) begin      // loss of sync -> full re-OOB
      oob_state <= OB_CR_BURST;
      oob_cnt   <= 9'd0;
      oob_seen  <= 1'b0;
      phy_ready <= 1'b0;
    end else begin
      case (oob_state)
        OB_CR_BURST: begin                    // transmit COMRESET burst
          if (oob_cnt == 9'(OOB_BURST-1)) begin
            oob_cnt   <= 9'd0;
            oob_seen  <= 1'b0;
            oob_state <= OB_CR_IDLE;
          end else oob_cnt <= oob_cnt + 9'd1;
        end
        OB_CR_IDLE: begin                     // idle, watch for COMINIT
          if (oob_det) oob_seen <= 1'b1;
          if (oob_cnt == 9'(OOB_IDLE-1)) begin
            oob_cnt <= 9'd0;
            if (oob_seen) oob_state <= OB_CI_BURST;
            else         oob_state <= OB_CR_BURST;
          end else oob_cnt <= oob_cnt + 9'd1;
        end
        OB_CI_BURST: begin                    // transmit COMINIT burst
          if (oob_cnt == 9'(OOB_BURST-1)) begin
            oob_cnt   <= 9'd0;
            oob_seen  <= 1'b0;
            oob_state <= OB_CI_IDLE;
          end else oob_cnt <= oob_cnt + 9'd1;
        end
        OB_CI_IDLE: begin                     // idle, watch for COMINIT ack
          if (oob_det) oob_seen <= 1'b1;
          if (oob_cnt == 9'(OOB_IDLE-1)) begin
            oob_cnt <= 9'd0;
            if (oob_seen) begin
              oob_state <= OB_DONE;
              phy_ready <= 1'b1;
            end else oob_state <= OB_CI_BURST;
          end else oob_cnt <= oob_cnt + 9'd1;
        end
        default: ;                            // OB_DONE: link up
      endcase
    end
  end

  // OOB line drive: constant burst pattern, idle otherwise
  wire oob_drive = (oob_state == OB_CR_BURST) || (oob_state == OB_CI_BURST);

  // ------------------------- shared state -----------------------------------
  typedef enum logic [2:0] {
    SQ_INIT, SQ_WR, SQ_WR_WAIT, SQ_RD, SQ_RD_WAIT, SQ_GAP
  } sq_t;
  sq_t         sq_state;
  logic [3:0]  sq_addr;
  logic [31:0] sq_wdata;
  logic        app_ack;               // TX took the sequencer's frame

  typedef enum logic {RX_HUNT, RX_LOCK} rxl_t;
  rxl_t        rx_lock;
  // read-response request from the RX target handler
  logic        rsp_req_set, rsp_pending;
  logic [7:0]  rsp_dst;
  logic [3:0]  rsp_src;
  logic [31:0] rsp_data;

  // ------------------------- TX block engine --------------------------------
  typedef enum logic [2:0] {
    TX_IDLE, TX_SOF, TX_HDR, TX_PAY, TX_CRC, TX_EOF
  } tx_t;
  localparam logic [1:0] K_WR = 2'd0, K_RD = 2'd1, K_RSP = 2'd2;
  tx_t         tx_state;
  logic [7:0]  tx_cnt;                // bit position in block (0..129)
  logic [1:0]  tx_sync;
  logic [127:0] tx_pld;               // payload shift register (MSB first)
  logic [15:0] scr;                   // self-synchronous scrambler state
  logic        tx_bit;
  logic [31:0] crc_acc;
  logic [1:0]  f_kind;                // frame being sent: write / rdreq / rdrsp
  logic [7:0]  f_dst;
  logic [3:0]  f_src;
  logic [31:0] f_data;

  // header type / len dwords (kept as expressions: mostly constant bits)
  function automatic logic [31:0] f_type(input logic [1:0] k);
    f_type = {24'd0, (k == K_RSP) ? T_RDRSP : (k == K_RD) ? T_RDREQ : T_WRITE};
  endfunction
  wire        f_len1 = (f_kind != K_RD);  // write / response carry one dword
  wire        scr_obit = tx_pld[127] ^ scr[15] ^ scr[4];
  wire        sq_req = (sq_state == SQ_WR) || (sq_state == SQ_RD);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state <= TX_IDLE;
      tx_cnt   <= 8'd0;
      tx_sync  <= SH_CTRL;
      tx_pld   <= {CODE_IDLE, 96'd0};
      scr      <= SCR_SEED;
      tx_bit   <= 1'b0;
      crc_acc  <= 32'd0;
      f_kind   <= K_WR;
      f_dst    <= 8'd0;
      f_src    <= 4'd0;
      f_data   <= 32'd0;
      app_ack  <= 1'b0;
      rsp_pending <= 1'b0;
    end else if (!phy_ready) begin
      tx_state <= TX_IDLE;
      tx_cnt   <= 8'd0;
      tx_sync  <= SH_CTRL;
      tx_pld   <= {CODE_IDLE, 96'd0};
      scr      <= SCR_SEED;
      tx_bit   <= 1'b0;
      app_ack  <= 1'b0;
      rsp_pending <= 1'b0;
    end else begin
      app_ack <= 1'b0;
      if (rsp_req_set) rsp_pending <= 1'b1;
      if (tx_cnt == 8'd0) begin
        tx_bit <= tx_sync[1];               // sync header MSB first, clear
        tx_cnt <= 8'd1;
      end else if (tx_cnt == 8'd1) begin
        tx_bit <= tx_sync[0];
        tx_cnt <= 8'd2;
      end else begin
        tx_bit <= scr_obit;                 // scrambled payload bit
        scr    <= {scr[14:0], scr_obit};
        tx_pld <= {tx_pld[126:0], 1'b0};
        if (tx_cnt == 8'd129) begin
          tx_cnt <= 8'd0;
          case (tx_state)                   // load next block
            TX_IDLE: begin
              tx_sync <= SH_CTRL;
              if (rsp_pending || rsp_req_set) begin
                f_kind <= K_RSP;
                f_dst  <= rsp_dst;
                f_src  <= rsp_src;
                f_data <= rsp_data;
                rsp_pending <= 1'b0;
                tx_pld   <= {CODE_SOF, 96'd0};
                tx_state <= TX_SOF;
              end else if (sq_req) begin
                f_kind <= (sq_state == SQ_RD) ? K_RD : K_WR;
                f_dst  <= {4'd0, sq_addr};
                f_src  <= 4'd1;             // initiator SAS address
                f_data <= sq_wdata;
                app_ack  <= 1'b1;
                tx_pld   <= {CODE_SOF, 96'd0};
                tx_state <= TX_SOF;
              end else begin
                tx_pld  <= {CODE_IDLE, 96'd0};
              end
            end
            TX_SOF: begin                   // SOF on wire -> header block
              tx_pld   <= {f_type(f_kind), 24'd0, f_dst, 28'd0, f_src, 31'd0, f_len1};
              tx_sync  <= SH_DATA;
              crc_acc  <= crc4(32'hFFFF_FFFF, f_type(f_kind), {24'd0, f_dst},
                               {28'd0, f_src}, {31'd0, f_len1});
              tx_state <= TX_HDR;
            end
            TX_HDR: begin                   // header on wire
              tx_sync <= SH_DATA;
              if (!f_len1) begin
                tx_pld   <= {crc_acc ^ 32'hFFFF_FFFF, 96'd0};
                tx_state <= TX_CRC;
              end else begin
                tx_pld   <= {f_data, 96'd0};
                crc_acc  <= crc4(crc_acc, f_data, 32'd0, 32'd0, 32'd0);
                tx_state <= TX_PAY;
              end
            end
            TX_PAY: begin                   // payload block on wire
              tx_sync  <= SH_DATA;
              tx_pld   <= {crc_acc ^ 32'hFFFF_FFFF, 96'd0};
              tx_state <= TX_CRC;
            end
            TX_CRC: begin                   // CRC on wire -> EOF
              tx_pld   <= {CODE_EOF, 96'd0};
              tx_sync  <= SH_CTRL;
              tx_state <= TX_EOF;
            end
            default: begin                  // TX_EOF: EOF on wire -> idle
              tx_pld   <= {CODE_IDLE, 96'd0};
              tx_sync  <= SH_CTRL;
              tx_state <= TX_IDLE;
            end
          endcase
        end else begin
          tx_cnt <= tx_cnt + 8'd1;
        end
      end
    end
  end

  // serial line drive
  assign tx_p = rst_n && (phy_ready ? tx_bit : oob_drive);
  assign tx_n = ~tx_p;

  // ------------------------- RX block engine --------------------------------
  logic [7:0]  rx_cnt;                // bit position in block (0..129)
  logic [1:0]  rx_sync_r;             // captured sync header
  logic [126:0] rx_pld;               // descrambled payload bits so far
  logic [15:0] dscr;                  // descrambler state
  logic [3:0]  viol_cnt;              // consecutive bad sync headers
  logic [1:0]  hunt_good;             // consecutive good syncs while hunting (sat.)
  logic        hunt_code;             // legal control code seen while hunting

  // block frame FSM
  typedef enum logic [2:0] {RF_SOF, RF_HDR, RF_PAY, RF_CRC, RF_EOF} rf_t;
  rf_t         rf_state;
  logic [7:0]  r_type, r_dst, r_src;
  logic [3:0]  r_len;
  logic [31:0] rcrc;
  logic [31:0] r_d0;                  // payload dword 0
  logic        pay_blk;
  logic        r_good;              // CRC block checked out

  // functional unit: 16x32-bit register file
  logic [31:0] regs [0:15];

  // events to the sequencer / irq
  logic        wr_evt, rsp_evt;
  logic [31:0] rsp_val;
  logic        crc_err_pulse, proto_err_pulse;

  // current line bit / descrambled bit / completed block
  wire         rx_db = rx_p ^ dscr[15] ^ dscr[4];
  wire [127:0] blk   = {rx_pld, rx_db};
  wire [1:0]   rx_sh = {rx_sync_r[1], rx_p};
  wire         sh_ok = (rx_sh == SH_DATA) || (rx_sh == SH_CTRL);
  wire         is_ctrl = (rx_sync_r == SH_CTRL);
  wire         c_idle = blk[127:96] == CODE_IDLE;
  wire         c_sof  = blk[127:96] == CODE_SOF;
  wire         c_eof  = blk[127:96] == CODE_EOF;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_lock    <= RX_HUNT;
      rx_cnt     <= 8'd0;
      rx_sync_r  <= 2'b00;
      rx_pld     <= 127'd0;
      dscr       <= SCR_SEED;
      viol_cnt   <= 4'd0;
      hunt_good  <= 2'd0;
      hunt_code  <= 1'b0;
      loss_sync  <= 1'b0;
      rf_state   <= RF_SOF;
      r_type     <= 8'd0;
      r_dst      <= 8'd0;
      r_src      <= 8'd0;
      r_len      <= 4'd0;
      rcrc       <= 32'd0;
      r_d0       <= 32'd0;
      pay_blk    <= 1'b0;
      r_good     <= 1'b0;
      wr_evt     <= 1'b0;
      rsp_evt    <= 1'b0;
      rsp_val    <= 32'd0;
      rsp_req_set<= 1'b0;
      rsp_dst    <= 8'd0;
      rsp_src    <= 4'd0;
      rsp_data   <= 32'd0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      for (int k = 0; k < 16; k++) regs[k] <= 32'd0;
    end else if (!phy_ready) begin
      rx_lock    <= RX_HUNT;
      rx_cnt     <= 8'd0;
      rx_sync_r  <= 2'b00;
      dscr       <= SCR_SEED;
      viol_cnt   <= 4'd0;
      hunt_good  <= 2'd0;
      hunt_code  <= 1'b0;
      loss_sync  <= 1'b0;
      rf_state   <= RF_SOF;
      wr_evt     <= 1'b0;
      rsp_evt    <= 1'b0;
      rsp_req_set<= 1'b0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
    end else begin
      wr_evt          <= 1'b0;
      rsp_evt         <= 1'b0;
      rsp_req_set     <= 1'b0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      loss_sync       <= 1'b0;
      if (rx_cnt == 8'd0) begin
        rx_sync_r[1] <= rx_p;               // sync header MSB
        rx_cnt       <= 8'd1;
      end else if (rx_cnt == 8'd1) begin
        rx_sync_r[0] <= rx_p;               // sync header LSB
        if (sh_ok) begin
          rx_cnt <= 8'd2;                   // valid sync: capture payload
          viol_cnt <= 4'd0;
          if (rx_lock == RX_HUNT) begin
            // lock after 4 consecutive good syncs AND a legal control code
            // (protects against false lock on scrambled idle payload bits)
            if (hunt_good == 2'd3 && hunt_code) rx_lock <= RX_LOCK;
            else if (hunt_good != 2'd3)         hunt_good <= hunt_good + 2'd1;
          end
        end else if (rx_lock == RX_HUNT) begin
          hunt_good    <= 2'd0;
          hunt_code    <= 1'b0;
          rx_sync_r[1] <= rx_p;             // bit slip: retry at +1 offset
          rx_cnt       <= 8'd1;
        end else begin
          rx_cnt   <= 8'd2;                 // stay aligned, drop this block
          viol_cnt <= viol_cnt + 4'd1;
          if (viol_cnt == 4'd7) begin       // 8 consecutive violations
            loss_sync <= 1'b1;
            rx_lock   <= RX_HUNT;
          end
        end
      end else begin
        dscr   <= {dscr[14:0], rx_p};       // self-synchronous descrambler
        rx_pld <= {rx_pld[125:0], rx_db};
        if (rx_cnt != 8'd129) rx_cnt <= rx_cnt + 8'd1;
        else begin
          rx_cnt <= 8'd0;
          if (rx_lock == RX_HUNT) begin
            // descrambled control code check (block-alignment evidence)
            if (is_ctrl && (c_idle || c_sof || c_eof)) hunt_code <= 1'b1;
          end else if (rx_sync_r == SH_DATA || is_ctrl) begin  // valid header
            case (rf_state)
              RF_SOF: begin                 // wait for SOF control block
                if (is_ctrl && c_sof) begin
                  rcrc     <= 32'hFFFF_FFFF;
                  rf_state <= RF_HDR;
                end
              end
              RF_HDR: begin                 // header data block
                if (is_ctrl || blk[7:0] > 8'd8) begin
                  proto_err_pulse <= 1'b1;
                  rf_state        <= RF_SOF;
                end else begin
                  r_type <= blk[103:96];
                  r_dst  <= blk[71:64];
                  r_src  <= blk[39:32];
                  r_len  <= blk[3:0];
                  rcrc   <= crc4(32'hFFFF_FFFF, blk[127:96], blk[95:64],
                                 blk[63:32], blk[31:0]);
                  pay_blk <= 1'b0;
                  if (blk[3:0] == 4'd0) rf_state <= RF_CRC;
                  else                  rf_state <= RF_PAY;
                end
              end
              RF_PAY: begin                 // payload data block(s)
                if (is_ctrl) begin
                  proto_err_pulse <= 1'b1;
                  rf_state        <= RF_SOF;
                end else begin
                  if (!pay_blk) r_d0 <= blk[127:96];
                  rcrc <= crc4(rcrc, blk[127:96], blk[95:64],
                               blk[63:32], blk[31:0]);
                  if (r_len <= 4'd4 || pay_blk) rf_state <= RF_CRC;
                  else pay_blk <= 1'b1;
                end
              end
              RF_CRC: begin                 // CRC data block
                rf_state <= RF_EOF;
                r_good   <= 1'b0;
                if (is_ctrl) proto_err_pulse <= 1'b1;
                else if (blk[127:96] != ~rcrc) crc_err_pulse <= 1'b1;
                else r_good <= 1'b1;
              end
              default: begin                // RF_EOF: frame accepted only here
                rf_state <= RF_SOF;
                if (!(is_ctrl && c_eof)) proto_err_pulse <= 1'b1;
                else if (r_good)
                  case (r_type)
                    T_WRITE: begin          // register write
                      if (r_len != 4'd0 && r_dst < 8'd16) begin
                        regs[r_dst[3:0]] <= r_d0;
                        wr_evt           <= 1'b1;
                      end else proto_err_pulse <= 1'b1;
                    end
                    T_RDREQ: begin          // register read request
                      if (r_dst < 8'd16) begin
                        rsp_req_set <= 1'b1;
                        rsp_dst     <= r_src;
                        rsp_src     <= r_dst[3:0];
                        rsp_data    <= regs[r_dst[3:0]];
                      end else proto_err_pulse <= 1'b1;
                    end
                    T_RDRSP: begin          // read response
                      if (r_len != 4'd0) begin
                        rsp_evt <= 1'b1;
                        rsp_val <= r_d0;
                      end else proto_err_pulse <= 1'b1;
                    end
                    default: proto_err_pulse <= 1'b1; // unknown frame type
                  endcase
              end
            endcase
          end
        end
      end
    end
  end

  // ------------------------- initiator sequencer -----------------------------
  logic [11:0] sq_tmo;
  logic [5:0]  gap_cnt;               // inter-transaction gap (clks)
  logic        tmo_err_pulse, mm_err_pulse;
  // only the events of the current transaction count: a late write or
  // response of an earlier (timed-out) one, or another node's, is ignored,
  // so the sequencer cannot stay one transaction out of step (the frame
  // fields still hold the frame that raised the event)
  wire         wr_ok  = wr_evt && r_dst[3:0] == sq_addr;
  wire         rsp_ok = rsp_evt && r_src == {4'd0, sq_addr};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sq_state      <= SQ_INIT;
      sq_tmo        <= 12'd0;
      gap_cnt       <= 6'd0;
      sq_addr       <= 4'd0;
      sq_wdata      <= 32'h5A5A_0001;
      tmo_err_pulse <= 1'b0;
      mm_err_pulse  <= 1'b0;
    end else if (!phy_ready) begin
      sq_state      <= SQ_INIT;
      sq_tmo        <= 12'd0;
      gap_cnt       <= 6'd0;
      tmo_err_pulse <= 1'b0;
      mm_err_pulse  <= 1'b0;
    end else begin
      tmo_err_pulse <= 1'b0;
      mm_err_pulse  <= 1'b0;
      case (sq_state)
        SQ_INIT: begin                        // RX block-locked before traffic
          if (rx_lock != RX_LOCK) gap_cnt <= 6'd0;
          else if (gap_cnt == 6'd63) begin
            gap_cnt  <= 6'd0;
            sq_state <= SQ_WR;
          end else gap_cnt <= gap_cnt + 6'd1;
        end
        SQ_WR: begin                          // register write frame queued
          sq_tmo <= 12'd0;
          if (app_ack) sq_state <= SQ_WR_WAIT;
        end
        SQ_WR_WAIT: begin                     // wait for the looped-back write
          if (wr_ok) sq_state <= SQ_RD;
          else if (sq_tmo == SQ_TMO) begin
            tmo_err_pulse <= 1'b1;
            sq_state      <= SQ_RD;
          end else sq_tmo <= sq_tmo + 12'd1;
        end
        SQ_RD: begin                          // register read request queued
          sq_tmo <= 12'd0;
          if (app_ack) sq_state <= SQ_RD_WAIT;
        end
        SQ_RD_WAIT: begin                     // verify the read response
          if (rsp_ok || sq_tmo == SQ_TMO) begin
            if (!rsp_ok)                 tmo_err_pulse <= 1'b1;
            else if (rsp_val != sq_wdata) mm_err_pulse <= 1'b1;
            sq_wdata <= xorshift32(sq_wdata);
            sq_addr  <= sq_addr + 4'd1;
            gap_cnt  <= 6'd0;
            sq_state <= SQ_GAP;
          end else sq_tmo <= sq_tmo + 12'd1;
        end
        default: begin                        // SQ_GAP: inter-transaction gap
          if (gap_cnt == 6'd31) begin
            gap_cnt  <= 6'd0;
            sq_state <= SQ_WR;
          end else gap_cnt <= gap_cnt + 6'd1;
        end
      endcase
    end
  end

  // ------------------------- outputs -----------------------------------------
  assign link_up = phy_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else irq <= crc_err_pulse | proto_err_pulse | tmo_err_pulse | mm_err_pulse | loss_sync;
  end

endmodule
