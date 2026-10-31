// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// PCIe_CXL_IDE_top v1.0: Integrity and Data Encryption (IDE) for PCIe TLPs,
// CXL.io and CXL.cachemem, built on two AES_GCM_top engines (AES-256-GCM,
// one for transmit, one for receive).
// ----------------------------------------------------------------------------
// The block streams carry 128-bit blocks (byte 0 in bits 127:120) with a byte
// count; the link layer packs them into its own TLP / flit byte stream. The
// field layouts are ours (the PCIe 6.x / CXL 3.x specifications are
// member-only): they follow the public descriptions of IDE but are not
// claimed to be bit-compatible.
//
//  - Streams: NS IDE streams (0..NS-1). Each has an enable, an 8-bit Stream
//    ID, a type (0: PCIe / CXL.io TLPs, 1: CXL.cachemem flits) and the 32-bit
//    fixed field of its IVs. Per direction and stream there are two key sets
//    (K = 0 / 1) of three sub-stream keys (0 posted, 1 non-posted,
//    2 completion; cachemem streams use sub-stream 0 only), each with its own
//    IV invocation counter.
//  - Keys (IDE_KM style), commands with km_dir / km_sid / km_ks / km_sub:
//    km_prog loads the key port (or, km_sel = 1, the sideload port) into a
//    slot and sets its counter to 1; km_go makes a key set the active one of
//    a stream and the stream Secure (its sub-stream keys must be loaded);
//    km_stop clears a key set (keys, counters) and makes the stream Insecure
//    if that set was active; clr clears every key and stream and aborts both
//    directions. A key set cannot be reprogrammed while it is the active set
//    of a Secure stream.
//  - IV = {fixed field, 64-bit invocation counter}; each message takes the
//    counter of its slot and increments it; the all-ones value is never used
//    (exhausted: error, stream Insecure).
//  - TLP mode (stream type 0). Transmit input: the TLP header blocks
//    (tx_hdr = 1, all 16 bytes but the last), then the payload blocks (all
//    16 bytes but the last), tx_last on the last block; tx_ide selects
//    protection (stream tx_sid, sub-stream tx_sub), tx_ide = 0 passes the TLP
//    through unchanged. Output: the IDE prefix block (4 bytes, kind PFX), the
//    header blocks unchanged (HDR), the encrypted payload (DATA) and the
//    96-bit MAC (kind MAC, 12 bytes, last). GCM AAD = prefix || header, text
//    = payload, MAC = the first 12 bytes of the tag. Prefix (ours):
//    [31:24] 0x92, [23] M = 1, [22] K, [21:20] 0, [19:18] sub-stream,
//    [17:16] 0, [15:8] Stream ID, [7:0] 0.
//  - Cachemem mode (stream type 1, CXL.cachemem): one GCM message is a MAC
//    epoch of cm_agg + 1 flits (no AAD, every block 16 bytes, tx_last ends a
//    flit); the MAC block (txo_cm = 1) follows the last flit of the epoch.
//    An epoch is closed early (truncated, MAC sent at once) when another IDE
//    message must use the engine; bypass traffic passes while it is open.
//  - Receive input uses the transmit output format (rx_kind; rx_cm marks
//    cachemem flits of stream rx_sid and their MAC block). An IDE TLP is
//    found by its prefix (Stream ID lookup, K selects the key set and, if
//    the other set is loaded, switches to it), decrypted and checked; other
//    TLPs pass through. Output: header blocks, plaintext, then an END block
//    (kind END, last) whose rxo_bad says whether the MAC matched: the
//    plaintext must be held until then. Any error on an IDE message makes
//    the stream Insecure and ends what was output with END rxo_bad = 1.
//  - Transmit errors drop the message; if blocks were already sent it is
//    ended by a nullified MAC block (txo_bad = 1, 0 bytes).
//  - Error codes (tx_code / rx_code): 1 format, 2 stream not enabled /
//    Secure / of that type, 3 key set not loaded, 4 counter exhausted,
//    5 too long for the GCM counters (LEN_W), 6 unknown Stream ID (receive),
//    7 MAC mismatch (receive). km_code: 1 bad stream / sub-stream, 2 key set
//    incomplete at km_go, 3 sideload key not valid, 4 key set in use.
// ============================================================================
module PCIe_CXL_IDE_top #(
  parameter int NS    = 2,              // IDE streams (1..4)
  parameter int CTR_W = 64,             // IV invocation counter bits (3..64)
  parameter int LEN_W = 16              // GCM byte counters (longest message)
) (
  input  logic              clk,
  input  logic              rst_n,
  // stream configuration
  input  logic [NS-1:0]     s_en,             // stream enabled
  input  logic [NS-1:0]     s_cm,             // 0 TLP (PCIe / CXL.io), 1 CXL.cachemem
  input  logic [NS*8-1:0]   s_id,             // Stream ID of stream i in [8i+7:8i]
  input  logic [NS*32-1:0]  s_ivfix,          // IV fixed field of stream i in [32i+31:32i]
  input  logic [6:0]        cm_agg,           // cachemem epoch: cm_agg + 1 flits
  // key management
  input  logic              km_dir,           // 0 transmit, 1 receive
  input  logic [1:0]        km_sid,           // stream
  input  logic              km_ks,            // key set
  input  logic [1:0]        km_sub,           // sub-stream (km_prog)
  input  logic              km_sel,           // km_prog: 0 km_key, 1 sideload key
  input  logic [255:0]      km_key,
  input  logic [255:0]      sl_key,
  input  logic              sl_valid,
  input  logic              km_prog,
  input  logic              km_go,
  input  logic              km_stop,
  input  logic              clr,
  // status
  output logic [NS-1:0]     sec_tx,           // stream Secure (transmit)
  output logic [NS-1:0]     sec_rx,
  output logic [NS-1:0]     ks_tx,            // active key set
  output logic [NS-1:0]     ks_rx,
  output logic [NS*6-1:0]   kv_tx,            // slot 6i + 3k + sub loaded
  output logic [NS*6-1:0]   kv_rx,
  output logic              tx_busy,
  output logic              rx_busy,
  output logic              km_err,
  output logic [2:0]        km_code,
  output logic              tx_done,          // an IDE message was sent with its MAC
  output logic              tx_err,
  output logic [2:0]        tx_code,
  output logic [1:0]        tx_esid,          // stream of the last transmit error
  output logic              rx_done,          // an IDE message passed its MAC check
  output logic              rx_err,
  output logic [2:0]        rx_code,
  output logic [7:0]        rx_eid,           // Stream ID of the last receive error
  // transmit input
  input  logic              tx_valid,
  output logic              tx_ready,
  input  logic [127:0]      tx_data,
  input  logic [4:0]        tx_bytes,
  input  logic              tx_hdr,
  input  logic              tx_last,
  input  logic              tx_ide,           // first block: protect the message
  input  logic [1:0]        tx_sid,           // first block: stream
  input  logic [1:0]        tx_sub,           // first block: sub-stream (TLP)
  // transmit output
  output logic              txo_valid,
  input  logic              txo_ready,
  output logic [127:0]      txo_data,
  output logic [4:0]        txo_bytes,
  output logic [1:0]        txo_kind,         // 0 HDR, 1 DATA, 2 MAC, 3 PFX
  output logic              txo_last,
  output logic              txo_bad,
  output logic              txo_cm,
  // receive input
  input  logic              rx_valid,
  output logic              rx_ready,
  input  logic [127:0]      rx_data,
  input  logic [4:0]        rx_bytes,
  input  logic [1:0]        rx_kind,          // 0 HDR, 1 DATA, 2 MAC, 3 PFX
  input  logic              rx_last,
  input  logic              rx_cm,            // cachemem flit / MAC of stream rx_sid
  input  logic [1:0]        rx_sid,
  // receive output
  output logic              rxo_valid,
  input  logic              rxo_ready,
  output logic [127:0]      rxo_data,
  output logic [4:0]        rxo_bytes,
  output logic [1:0]        rxo_kind,         // 0 HDR, 1 DATA, 2 END
  output logic              rxo_last,
  output logic              rxo_bad,
  output logic              rxo_cm
);
  localparam int NSL = NS * 6;          // key slots per direction
  localparam logic [1:0] K_HDR = 2'd0, K_DATA = 2'd1, K_MAC = 2'd2, K_PFX = 2'd3, K_END = 2'd2;
  localparam logic [2:0] E_FMT = 3'd1, E_STATE = 3'd2, E_KEY = 3'd3, E_CTR = 3'd4,
                         E_LEN = 3'd5, E_SID = 3'd6, E_MAC = 3'd7;
  localparam logic [7:0] PFX_TYPE = 8'h92;
  localparam logic [CTR_W-1:0] C_MAX = '1;
  localparam int SLW = $clog2(NSL);     // slot index bits
  localparam int SW  = NS > 1 ? $clog2(NS) : 1;   // stream index bits

  function automatic logic [4:0] slot(input logic [1:0] s, input logic k, input logic [1:0] sub);
    slot = 5'(s) * 5'd6 + (k ? 5'd3 : 5'd0) + 5'(sub);
  endfunction
  // the AAD block of a header block behind the 4 carried bytes c, its byte
  // count, and the bytes carried on
  function automatic logic [4:0] aad_n(input logic [4:0] n);
    aad_n = n > 5'd12 ? 5'd16 : n + 5'd4;
  endfunction
  function automatic logic [2:0] carry_n(input logic [4:0] n);
    carry_n = n > 5'd12 ? 3'(n - 5'd12) : 3'd0;
  endfunction
  function automatic logic [127:0] bmask(input logic [4:0] n);
    for (int i = 0; i < 16; i++) bmask[127 - 8 * i -: 8] = 5'(i) < n ? 8'hff : 8'h00;
  endfunction

  // ---------------- key slots and stream state ----------------
  logic [NSL*256-1:0]   ktx, krx;       // slot keys
  logic [NSL*CTR_W-1:0] ctx, crx;       // slot invocation counters
  // per-stream values by a 2-bit stream number (streams past NS-1 read 0)
  function automatic logic fl(input logic [NS-1:0] v, input logic [1:0] i);
    fl = 1'b0;
    for (int j = 0; j < NS; j++) if (2'(j) == i) fl = v[j];
  endfunction
  function automatic logic [7:0] id8(input logic [NS*8-1:0] v, input logic [1:0] i);
    id8 = 8'h0;
    for (int j = 0; j < NS; j++) if (2'(j) == i) id8 = v[8 * j +: 8];
  endfunction
  function automatic logic [31:0] fix32(input logic [NS*32-1:0] v, input logic [1:0] i);
    fix32 = 32'h0;
    for (int j = 0; j < NS; j++) if (2'(j) == i) fix32 = v[32 * j +: 32];
  endfunction

  // ---------------- engines ----------------
  logic         gt_start, gt_clr, gt_iv_v, gt_ir, gt_aad, gt_last, gt_ov, gt_done, gt_err;
  logic [127:0] gt_id, gt_od;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [127:0] gt_tag;                 // the MAC is its first 96 bits
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0]   gt_ib, gt_ob;
  logic         gr_start, gr_clr, gr_iv_v, gr_ir, gr_aad, gr_last, gr_ov, gr_done, gr_err, gr_ok;
  logic [127:0] gr_id, gr_od;
  logic [4:0]   gr_ib, gr_ob;
  wire          txo_free = !txo_valid || txo_ready;
  wire          rxo_free = !rxo_valid || rxo_ready;

  // ================= transmit =================
  typedef enum logic [3:0] {T_IDLE, T_PFX, T_HDR, T_FL, T_DATA, T_END, T_WAIT, T_MAC, T_DROP, T_TERM, T_BYP} t_t;
  t_t           t;
  logic         t_fd;                   // after the flush (T_FL): 1 T_DATA, 0 T_END
  logic         t_ep, t_epm;            // cachemem epoch open; message is cachemem
  logic [SW-1:0] t_eps, t_s;            // epoch stream; stream of the message
  logic [6:0]   t_epn;                  // flits of the epoch sent
  logic         t_hs, t_hp, t_pl, t_end, t_term;  // header seen / partial; flit last pushed; input ended
  logic [31:0]  t_c;                    // AAD carry
  logic [2:0]   t_cl;
  logic [95:0]  t_mac;
  logic [7:0]   t_pid;                  // prefix Stream ID / K / sub-stream
  logic         t_pk;
  logic [1:0]   t_psub;

  // first block of a message (T_IDLE)
  wire          tc_cm   = fl(s_cm, tx_sid);
  wire          tc_ks   = fl(ks_tx, tx_sid);
  wire [4:0]    tc_sl   = slot(tx_sid, tc_ks, tc_cm ? 2'd0 : tx_sub);
  wire [CTR_W-1:0] tc_ctr = ctx[CTR_W * tc_sl +: CTR_W];
  wire          tc_cont = t_ep && tc_cm && tx_sid == 2'(t_eps);           // next flit of the open epoch
  wire          tc_ok   = fl(s_en, tx_sid) && fl(sec_tx, tx_sid);
  wire [2:0]    tc_e    = !tc_ok ? E_STATE : tc_cont ? 3'd0 : !tc_cm && tx_sub == 2'd3 ? E_FMT
                        : tc_ctr == C_MAX ? E_CTR : 3'd0;
  wire          t_idle_v = t == T_IDLE && tx_valid && !gt_err;
  wire          t_new   = t_idle_v && tx_ide && !t_ep && tc_e == 3'd0;
  assign gt_start = t_new;
  // block checks
  wire [127:0]  tx_m    = tx_data & bmask(tx_bytes);
  wire          tb_bad  = tx_bytes == 5'd0 || tx_bytes > 5'd16;
  wire          th_bad  = tx_hdr ? t_hp || tb_bad : !t_hs;                       // T_HDR
  wire          td_bad  = tx_hdr || tb_bad || tx_bytes != 5'd16 && (!tx_last || t_epm);   // T_DATA
  wire          t_ocan  = txo_free && !gt_ov;
  always_comb begin
    gt_iv_v = 1'b0; gt_id = 128'h0; gt_ib = 5'd0; gt_aad = 1'b0; gt_last = 1'b0;
    tx_ready = 1'b0;
    case (t)
      T_HDR: if (tx_valid) begin
        if (th_bad) tx_ready = 1'b1;
        else if (tx_hdr) begin
          gt_iv_v = t_ocan; gt_aad = 1'b1;
          gt_id = {t_c, tx_m[127:32]}; gt_ib = aad_n(tx_bytes);
          tx_ready = t_ocan && gt_ir;
        end
      end
      T_FL: begin
        gt_iv_v = t_cl != 3'd0; gt_aad = 1'b1; gt_id = {t_c, 96'h0}; gt_ib = {2'b00, t_cl};
      end
      T_DATA: if (tx_valid) begin
        if (td_bad) tx_ready = 1'b1;
        else begin
          gt_iv_v = 1'b1; gt_id = tx_m; gt_ib = tx_bytes; gt_last = tx_last && !t_epm;
          tx_ready = gt_ir;
        end
      end
      T_END: begin gt_iv_v = 1'b1; gt_last = 1'b1; end
      T_DROP: tx_ready = !t_end;
      T_BYP: tx_ready = t_ocan;
      default: ;
    endcase
  end
  wire t_take = tx_valid && tx_ready;
  assign tx_busy = t != T_IDLE || t_ep;

  // ================= receive =================
  typedef enum logic [3:0] {R_IDLE, R_HDR, R_FL, R_DATA, R_MAC, R_END, R_WAIT, R_ST, R_DROP, R_TERM, R_BYP} r_t;
  r_t           r;
  logic         r_fm;                   // after the flush (R_FL): 1 R_MAC, 0 R_DATA
  logic         r_ep, r_epm;
  logic [SW-1:0] r_eps, r_s;            // epoch stream; stream of the message
  logic [7:0]   r_epn;
  logic         r_hs, r_hp, r_dp, r_pl, r_end, r_term, r_ok;
  logic [31:0]  r_c;
  logic [2:0]   r_cl;
  logic [95:0]  r_mac;
  logic [7:0]   r_id;                   // Stream ID of the message
  logic [127:8] r_hd;                   // a partial last payload block (<16 bytes), held until the MAC
  logic [3:0]   r_hb;

  // first block (R_IDLE): a prefix or a cachemem block
  wire [31:0]   rp      = rx_data[127:96];
  logic [SW-1:0] rp_s;                  // stream with the prefix's Stream ID
  logic         rp_hit;
  always_comb begin
    rp_s = '0; rp_hit = 1'b0;
    for (int i = NS - 1; i >= 0; i--)
      if (s_en[i] && !s_cm[i] && s_id[8 * i +: 8] == rp[15:8]) begin rp_s = SW'(i); rp_hit = 1'b1; end
  end
  wire          rp_k    = rp[22];
  wire [1:0]    rp_sub  = rp[19:18];
  wire          rq_cm   = rx_cm;
  wire [1:0]    rq_s    = rq_cm ? rx_sid : 2'(rp_s);
  wire          rq_k    = rq_cm ? fl(ks_rx, rx_sid) : rp_k;
  wire [4:0]    rq_sl   = slot(rq_s, rq_k, rq_cm ? 2'd0 : rp_sub);
  wire [CTR_W-1:0] rq_ctr = crx[CTR_W * rq_sl +: CTR_W];
  wire          rq_kv   = kv_rx[SLW'(rq_sl)];
  wire          rq_cont = r_ep && rq_cm && rx_sid == 2'(r_eps);
  wire [2:0]    rq_e    = rq_cm
      ? (rx_kind == K_MAC ? (rq_cont ? 3'd0 : E_FMT)
         : rx_kind != K_DATA ? E_FMT
         : !(fl(s_en, rx_sid) && fl(s_cm, rx_sid) && fl(sec_rx, rx_sid)) ? E_STATE
         : rq_cont ? (r_epn == 8'(cm_agg) + 8'd1 ? E_FMT : 3'd0)
         : rq_ctr == C_MAX ? E_CTR : 3'd0)
      : (rx_bytes != 5'd4 || rx_last || rp[31:24] != PFX_TYPE || !rp[23] ? E_FMT
         : !rp_hit ? E_SID : !fl(sec_rx, 2'(rp_s)) ? E_STATE : rp_sub == 2'd3 ? E_FMT
         : !rq_kv ? E_KEY : rq_ctr == C_MAX ? E_CTR : 3'd0);
  wire          r_idle_v = r == R_IDLE && rx_valid && !gr_err;
  wire          r_ide    = rq_cm || rx_kind == K_PFX;
  wire          r_abort  = r_idle_v && r_ep && r_ide && !rq_cont;     // epoch interrupted
  wire          r_go     = r_idle_v && r_ide && !r_abort && rq_e == 3'd0;
  wire          r_new    = r_go && !rq_cont && !(rq_cm && rx_kind == K_MAC);
  assign gr_start = r_new;

  // engines; block last flags are tracked here, an encrypting engine gives no
  // tag_ok and a decrypting one no tag
  /* verilator lint_off PINCONNECTEMPTY */
  AES_GCM_top #(.LEN_W(LEN_W)) u_gtx (
    .clk, .rst_n, .key256(1'b1), .decrypt(1'b0), .key_sel(1'b0), .tag_len(4'd0),
    .key(ktx[256 * tc_sl +: 256]), .iv({fix32(s_ivfix, tx_sid), 64'(tc_ctr)}), .tag_in(128'h0),
    .sl_key(256'h0), .sl_valid(1'b0), .start(gt_start), .clr(gt_clr), .busy(),
    .in_valid(gt_iv_v), .in_ready(gt_ir), .in_data(gt_id), .in_bytes(gt_ib), .in_aad(gt_aad), .in_last(gt_last),
    .out_valid(gt_ov), .out_ready(txo_free), .out_data(gt_od), .out_bytes(gt_ob), .out_last(),
    .done(gt_done), .tag(gt_tag), .tag_ok(), .err(gt_err), .err_code());
  AES_GCM_top #(.LEN_W(LEN_W)) u_grx (
    .clk, .rst_n, .key256(1'b1), .decrypt(1'b1), .key_sel(1'b0), .tag_len(4'd12),
    .key(krx[256 * rq_sl +: 256]), .iv({fix32(s_ivfix, rq_s), 64'(rq_ctr)}), .tag_in({r_mac, 32'h0}),
    .sl_key(256'h0), .sl_valid(1'b0), .start(gr_start), .clr(gr_clr), .busy(),
    .in_valid(gr_iv_v), .in_ready(gr_ir), .in_data(gr_id), .in_bytes(gr_ib), .in_aad(gr_aad), .in_last(gr_last),
    .out_valid(gr_ov), .out_ready(rxo_free), .out_data(gr_od), .out_bytes(gr_ob), .out_last(),
    .done(gr_done), .tag(), .tag_ok(gr_ok), .err(gr_err), .err_code());
  /* verilator lint_on PINCONNECTEMPTY */
  wire [127:0]  rx_m    = rx_data & bmask(rx_bytes);
  wire          rb_bad  = rx_bytes == 5'd0 || rx_bytes > 5'd16;
  wire          rh_bad  = rx_kind == K_HDR ? r_hp || rb_bad || rx_last : rx_kind == K_PFX || !r_hs;   // R_HDR
  wire          rd_bad  = r_epm ? rx_kind != K_DATA || rx_bytes != 5'd16
                        : rx_kind == K_MAC ? 1'b0
                        : rx_kind != K_DATA || rb_bad || r_dp || rx_last;                // R_DATA
  wire          rm_bad  = rx_kind != K_MAC || rx_bytes != 5'd12 || !rx_last;          // R_MAC
  wire          r_ocan  = rxo_free && !gr_ov;
  always_comb begin
    gr_iv_v = 1'b0; gr_id = 128'h0; gr_ib = 5'd0; gr_aad = 1'b0; gr_last = 1'b0;
    rx_ready = 1'b0;
    case (r)
      R_IDLE: rx_ready = r_go && !rq_cm;                 // the prefix block
      R_HDR: if (rx_valid) begin
        if (rh_bad) rx_ready = 1'b1;
        else if (rx_kind == K_HDR) begin
          gr_iv_v = r_ocan; gr_aad = 1'b1;
          gr_id = {r_c, rx_m[127:32]}; gr_ib = aad_n(rx_bytes);
          rx_ready = r_ocan && gr_ir;
        end
      end
      R_FL: begin
        gr_iv_v = r_cl != 3'd0; gr_aad = 1'b1; gr_id = {r_c, 96'h0}; gr_ib = {2'b00, r_cl};
      end
      R_DATA: if (rx_valid) begin
        if (rd_bad || rx_kind == K_DATA && rx_bytes != 5'd16) rx_ready = 1'b1;
        else if (rx_kind == K_DATA) begin
          gr_iv_v = 1'b1; gr_id = rx_data; gr_ib = rx_bytes;
          rx_ready = gr_ir;
        end
      end
      R_MAC: rx_ready = rx_valid;
      R_END: begin gr_iv_v = 1'b1; gr_last = 1'b1; gr_id = {r_hd, 8'h0}; gr_ib = {1'b0, r_hb}; end
      R_DROP: rx_ready = !r_end;
      R_BYP: rx_ready = r_ocan;
      default: ;
    endcase
  end
  wire r_take = rx_valid && rx_ready;
  assign rx_busy = r != R_IDLE || r_ep;

  // ================= key management =================
  wire        km_bad = 32'(km_sid) >= NS;
  wire [4:0]  km_b   = slot(km_sid, km_ks, 2'd0);
  wire [4:0]  km_sl  = km_b + 5'(km_sub);
  wire [NSL-1:0] km_kv = km_dir ? kv_rx : kv_tx;
  wire        km_use = km_dir ? fl(sec_rx, km_sid) && fl(ks_rx, km_sid) == km_ks : fl(sec_tx, km_sid) && fl(ks_tx, km_sid) == km_ks;
  wire        km_full = km_kv[SLW'(km_b)] && (fl(s_cm, km_sid) || km_kv[SLW'(km_b + 5'd1)] && km_kv[SLW'(km_b + 5'd2)]);
  wire [2:0]  km_e = km_prog ? (km_bad || km_sub == 2'd3 ? 3'd1 : km_sel && !sl_valid ? 3'd3 : km_use ? 3'd4 : 3'd0)
                   : km_go ? (km_bad ? 3'd1 : !km_full ? 3'd2 : 3'd0)
                   : km_stop ? (km_bad ? 3'd1 : 3'd0) : 3'd0;

  // stream events of the engines
  wire t_ins = t_idle_v && tx_ide && !t_ep && tc_e == E_CTR;           // counter exhausted
  logic r_ins;                          // receive error on stream r_ins_s
  logic [SW-1:0] r_ins_s;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ktx <= '0; krx <= '0; ctx <= '0; crx <= '0; kv_tx <= '0; kv_rx <= '0;
      sec_tx <= '0; sec_rx <= '0; ks_tx <= '0; ks_rx <= '0;
      km_err <= 1'b0; km_code <= '0;
    end else begin
      km_err <= 1'b0;
      // engines: counters, key-set switch, Insecure on errors
      if (t_new) ctx[CTR_W * tc_sl +: CTR_W] <= tc_ctr + 1'b1;
      if (t_ins) sec_tx[SW'(tx_sid)] <= 1'b0;
      if (r_new) crx[CTR_W * rq_sl +: CTR_W] <= rq_ctr + 1'b1;
      if (r_go && !rq_cm) ks_rx[rp_s] <= rp_k;
      if (r_ins) sec_rx[r_ins_s] <= 1'b0;
      // key management
      if (km_e != 3'd0) begin
        km_err <= 1'b1; km_code <= km_e;
      end else if (km_prog) begin
        if (km_dir) begin
          krx[256 * km_sl +: 256] <= km_sel ? sl_key : km_key;
          crx[CTR_W * km_sl +: CTR_W] <= CTR_W'(1);
          kv_rx[SLW'(km_sl)] <= 1'b1;
        end else begin
          ktx[256 * km_sl +: 256] <= km_sel ? sl_key : km_key;
          ctx[CTR_W * km_sl +: CTR_W] <= CTR_W'(1);
          kv_tx[SLW'(km_sl)] <= 1'b1;
        end
      end else if (km_go) begin
        if (km_dir) begin sec_rx[SW'(km_sid)] <= 1'b1; ks_rx[SW'(km_sid)] <= km_ks; end
        else begin sec_tx[SW'(km_sid)] <= 1'b1; ks_tx[SW'(km_sid)] <= km_ks; end
      end else if (km_stop) begin
        for (int j = 0; j < 3; j++) begin
          logic [4:0] kj;
          kj = km_b + 5'(j);
          if (km_dir) begin
            krx[256 * kj +: 256] <= '0; crx[CTR_W * kj +: CTR_W] <= '0; kv_rx[SLW'(kj)] <= 1'b0;
          end else begin
            ktx[256 * kj +: 256] <= '0; ctx[CTR_W * kj +: CTR_W] <= '0; kv_tx[SLW'(kj)] <= 1'b0;
          end
        end
        if (km_use) begin
          if (km_dir) sec_rx[SW'(km_sid)] <= 1'b0;
          else sec_tx[SW'(km_sid)] <= 1'b0;
        end
      end
      if (clr) begin
        ktx <= '0; krx <= '0; ctx <= '0; crx <= '0; kv_tx <= '0; kv_rx <= '0;
        sec_tx <= '0; sec_rx <= '0; ks_tx <= '0; ks_rx <= '0;
      end
    end
  end

  // ================= transmit control =================
  // errors: at the first block (dropped, nothing sent) or later (nullified
  // MAC block)
  logic       te_v, te_term;
  logic [2:0] te_c;
  always_comb begin
    te_v = 1'b0; te_c = 3'd0; te_term = 1'b1;
    if (gt_err) begin te_v = 1'b1; te_c = E_LEN; end
    else case (t)
      T_IDLE: if (tx_valid && tx_ide && !(t_ep && !tc_cont) && tc_e != 3'd0) begin
        te_v = 1'b1; te_c = tc_e; te_term = tc_cont;
      end
      T_HDR: if (tx_valid && th_bad) begin te_v = 1'b1; te_c = E_FMT; end
      T_DATA: if (tx_valid && td_bad) begin te_v = 1'b1; te_c = E_FMT; end
      default: ;
    endcase
  end
  assign gt_clr = clr || te_v && te_term;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t <= T_IDLE; t_fd <= 1'b0; t_ep <= 1'b0; t_epm <= 1'b0; t_eps <= '0; t_s <= '0; t_epn <= '0;
      t_hs <= 1'b0; t_hp <= 1'b0; t_pl <= 1'b0; t_end <= 1'b0; t_term <= 1'b0;
      t_c <= '0; t_cl <= '0; t_mac <= '0; t_pid <= '0; t_pk <= 1'b0; t_psub <= '0;
      txo_valid <= 1'b0; txo_data <= '0; txo_bytes <= '0; txo_kind <= '0; txo_last <= 1'b0;
      txo_bad <= 1'b0; txo_cm <= 1'b0;
      tx_done <= 1'b0; tx_err <= 1'b0; tx_code <= '0; tx_esid <= '0;
    end else begin
      tx_done <= 1'b0;
      tx_err <= 1'b0;
      if (txo_valid && txo_ready) txo_valid <= 1'b0;
      if (t_take && tx_last) t_end <= 1'b1;
      // engine output
      if (gt_ov && txo_free) begin
        txo_valid <= 1'b1; txo_data <= gt_od; txo_bytes <= gt_ob; txo_kind <= K_DATA;
        txo_last <= t_pl; txo_bad <= 1'b0; txo_cm <= t_epm;
      end
      case (t)
        T_IDLE: if (t_idle_v) begin
          if (!tx_ide) begin t_end <= 1'b0; t <= T_BYP; end
          else if (t_ep && !tc_cont) t <= T_END;            // close the epoch first
          else if (tc_e == 3'd0) begin
            t_end <= 1'b0; t_hs <= 1'b0; t_hp <= 1'b0;
            if (tc_cont) t <= T_DATA;
            else begin
              t_epm <= tc_cm; t_s <= SW'(tx_sid);
              t_pid <= id8(s_id, tx_sid); t_pk <= tc_ks; t_psub <= tx_sub;
              if (tc_cm) begin
                t_ep <= 1'b1; t_eps <= SW'(tx_sid); t_epn <= '0;
                t <= T_DATA;
              end else t <= T_PFX;
            end
          end
        end
        T_PFX: if (t_ocan) begin
          txo_valid <= 1'b1;
          txo_data <= {PFX_TYPE, 1'b1, t_pk, 2'b00, t_psub, 2'b00, t_pid, 8'h00, 96'h0};
          txo_bytes <= 5'd4; txo_kind <= K_PFX; txo_last <= 1'b0; txo_bad <= 1'b0; txo_cm <= 1'b0;
          t_c <= {PFX_TYPE, 1'b1, t_pk, 2'b00, t_psub, 2'b00, t_pid, 8'h00};
          t_cl <= 3'd4;
          t <= T_HDR;
        end
        T_HDR: if (t_take && tx_hdr && !th_bad) begin
          txo_valid <= 1'b1; txo_data <= tx_m; txo_bytes <= tx_bytes; txo_kind <= K_HDR;
          txo_last <= 1'b0; txo_bad <= 1'b0; txo_cm <= 1'b0;
          t_c <= tx_m[31:0];
          t_cl <= carry_n(tx_bytes);
          t_hs <= 1'b1;
          t_hp <= tx_bytes != 5'd16;
          if (tx_last) begin t <= T_FL; t_fd <= 1'b0; end
        end else if (tx_valid && !tx_hdr && !th_bad) begin
          t <= T_FL; t_fd <= 1'b1;
        end
        T_FL: if (t_cl == 3'd0 || gt_ir) begin
          t_cl <= 3'd0; t_c <= '0;
          if (t_fd) t <= T_DATA;
          else t <= T_END;
        end
        T_DATA: if (t_take && !td_bad) begin
          t_pl <= tx_last && t_epm;
          if (tx_last) begin
            if (!t_epm) t <= T_WAIT;          // the TLP's last block ended the GCM message
            else begin
              t_epn <= t_epn + 1'b1;
              t <= t_epn == cm_agg ? T_END : T_IDLE;
            end
          end
        end
        T_END: if (gt_ir) t <= T_WAIT;
        T_WAIT: if (gt_done) begin
          t_mac <= gt_tag[127:32];
          t <= T_MAC;
        end
        T_MAC: if (t_ocan) begin
          txo_valid <= 1'b1; txo_data <= {t_mac, 32'h0}; txo_bytes <= 5'd12; txo_kind <= K_MAC;
          txo_last <= 1'b1; txo_bad <= 1'b0; txo_cm <= t_epm;
          tx_done <= 1'b1;
          t_ep <= 1'b0; t_epn <= '0; t_mac <= '0; t_pl <= 1'b0;
          t <= T_IDLE;
        end
        T_DROP: if (t_end || t_take && tx_last) t <= t_term ? T_TERM : T_IDLE;
        T_TERM: if (t_ocan) begin
          txo_valid <= 1'b1; txo_data <= '0; txo_bytes <= 5'd0; txo_kind <= K_MAC;
          txo_last <= 1'b1; txo_bad <= 1'b1; txo_cm <= t_epm;
          t <= T_IDLE;
        end
        T_BYP: if (t_take) begin
          txo_valid <= 1'b1; txo_data <= tx_data; txo_bytes <= tx_bytes; txo_kind <= tx_hdr ? K_HDR : K_DATA;
          txo_last <= tx_last; txo_bad <= 1'b0; txo_cm <= 1'b0;
          if (tx_last) t <= T_IDLE;
        end
        default: t <= T_IDLE;
      endcase
      if (te_v) begin
        tx_err <= 1'b1; tx_code <= te_c; tx_esid <= t == T_IDLE && !gt_err ? tx_sid : 2'(t_s);
        t_term <= te_term;
        t_ep <= 1'b0; t_epn <= '0; t_c <= '0; t_cl <= '0; t_pl <= 1'b0;
        // the input packet: from its first block (IDLE) or the rest of it
        t_end <= t == T_IDLE && !gt_err ? 1'b0 : t_end || t_take && tx_last;
        t <= T_DROP;
      end
      if (clr) begin
        t <= T_IDLE; t_ep <= 1'b0; t_epn <= '0; t_c <= '0; t_cl <= '0; t_mac <= '0; t_pl <= 1'b0;
        txo_valid <= 1'b0; txo_data <= '0;
      end
    end
  end

  // ================= receive control =================
  logic       re_v, re_term, re_ins;
  logic [2:0] re_c;
  logic [SW-1:0] re_s;
  logic [7:0] re_id;
  wire        rp_fmt = rx_bytes == 5'd4 && !rx_last && rp[31:24] == PFX_TYPE && rp[23];
  always_comb begin
    re_v = 1'b0; re_c = 3'd0; re_term = 1'b1; re_ins = 1'b1; re_s = r_s; re_id = r_id;
    if (gr_err) begin re_v = 1'b1; re_c = E_LEN; end
    else case (r)
      R_IDLE: if (r_abort) begin
        re_v = 1'b1; re_c = E_FMT; re_s = r_eps; re_id = id8(s_id, 2'(r_eps));
      end else if (rx_valid && r_ide && rq_e != 3'd0) begin
        re_v = 1'b1; re_c = rq_e; re_term = rq_cont;
        re_s = SW'(rq_s); re_id = rq_cm ? id8(s_id, rx_sid) : rp[15:8];
        re_ins = rq_cm ? 32'(rx_sid) < NS : rp_fmt && rp_hit;
      end
      R_HDR: if (rx_valid && rh_bad) begin re_v = 1'b1; re_c = E_FMT; end
      R_DATA: if (rx_valid && rd_bad) begin re_v = 1'b1; re_c = E_FMT; end
      R_MAC: if (rx_valid && rm_bad) begin re_v = 1'b1; re_c = E_FMT; end
      default: ;
    endcase
  end
  assign gr_clr = clr || re_v && re_term;
  always_comb begin
    r_ins = re_v && re_ins || r == R_WAIT && gr_done && !gr_ok;
    r_ins_s = re_v ? re_s : r_s;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r <= R_IDLE; r_fm <= 1'b0; r_ep <= 1'b0; r_epm <= 1'b0; r_eps <= '0; r_s <= '0; r_epn <= '0;
      r_hs <= 1'b0; r_hp <= 1'b0; r_dp <= 1'b0; r_pl <= 1'b0; r_end <= 1'b0; r_term <= 1'b0; r_ok <= 1'b0;
      r_c <= '0; r_cl <= '0; r_mac <= '0; r_id <= '0; r_hd <= '0; r_hb <= '0;
      rxo_valid <= 1'b0; rxo_data <= '0; rxo_bytes <= '0; rxo_kind <= '0; rxo_last <= 1'b0;
      rxo_bad <= 1'b0; rxo_cm <= 1'b0;
      rx_done <= 1'b0; rx_err <= 1'b0; rx_code <= '0; rx_eid <= '0;
    end else begin
      rx_done <= 1'b0;
      rx_err <= 1'b0;
      if (rxo_valid && rxo_ready) rxo_valid <= 1'b0;
      if (r_take && rx_last) r_end <= 1'b1;
      if (gr_ov && rxo_free) begin
        rxo_valid <= 1'b1; rxo_data <= gr_od; rxo_bytes <= gr_ob; rxo_kind <= K_DATA;
        rxo_last <= r_pl; rxo_bad <= 1'b0; rxo_cm <= r_epm;
      end
      case (r)
        R_IDLE: if (r_idle_v) begin
          if (!r_ide) begin r_end <= 1'b0; r <= R_BYP; end
          else if (!r_abort && rq_e == 3'd0) begin
            r_end <= 1'b0; r_dp <= 1'b0;
            if (!rq_cm) begin
              r_epm <= 1'b0; r_s <= rp_s; r_id <= rp[15:8];
              r_c <= rp; r_cl <= 3'd4; r_hs <= 1'b0; r_hp <= 1'b0;
              r <= R_HDR;
            end else if (rx_kind == K_MAC) r <= R_MAC;
            else begin
              if (!rq_cont) begin
                r_ep <= 1'b1; r_epm <= 1'b1; r_eps <= SW'(rx_sid); r_s <= SW'(rx_sid); r_epn <= '0;
                r_id <= id8(s_id, rx_sid);
              end
              r <= R_DATA;
            end
          end
        end
        R_HDR: if (r_take && rx_kind == K_HDR && !rh_bad) begin
          rxo_valid <= 1'b1; rxo_data <= rx_m; rxo_bytes <= rx_bytes; rxo_kind <= K_HDR;
          rxo_last <= 1'b0; rxo_bad <= 1'b0; rxo_cm <= 1'b0;
          r_c <= rx_m[31:0];
          r_cl <= carry_n(rx_bytes);
          r_hs <= 1'b1;
          r_hp <= rx_bytes != 5'd16;
        end else if (rx_valid && rx_kind != K_HDR && !rh_bad) begin
          r <= R_FL; r_fm <= rx_kind == K_MAC;
        end
        R_FL: if (r_cl == 3'd0 || gr_ir) begin
          r_cl <= 3'd0; r_c <= '0;
          if (r_fm) r <= R_MAC;
          else r <= R_DATA;
        end
        R_DATA: if (rx_valid && !rd_bad) begin
          if (rx_kind == K_MAC) r <= R_MAC;
          else if (r_take) begin
            r_dp <= rx_bytes != 5'd16;
            if (rx_bytes != 5'd16) begin r_hd <= rx_m[127:8]; r_hb <= 4'(rx_bytes); end
            r_pl <= rx_last && r_epm;
            if (rx_last) begin
              r_epn <= r_epn + 1'b1;
              r <= R_IDLE;
            end
          end
        end
        R_MAC: if (r_take && !rm_bad) begin
          r_mac <= rx_data[127:32];
          r <= R_END;
        end
        R_END: if (gr_ir) begin
          r_hd <= '0; r_hb <= '0; r_dp <= 1'b0;
          r <= R_WAIT;
        end
        R_WAIT: if (gr_done) begin
          r_ok <= gr_ok;
          rx_done <= gr_ok;
          if (!gr_ok) begin rx_err <= 1'b1; rx_code <= E_MAC; rx_eid <= r_id; end
          r <= R_ST;
        end
        R_ST: if (r_ocan) begin
          rxo_valid <= 1'b1; rxo_data <= '0; rxo_bytes <= 5'd0; rxo_kind <= K_END;
          rxo_last <= 1'b1; rxo_bad <= !r_ok; rxo_cm <= r_epm;
          r_ep <= 1'b0; r_epn <= '0; r_mac <= '0; r_pl <= 1'b0; r_ok <= 1'b0;
          r <= R_IDLE;
        end
        R_DROP: if (r_end || r_take && rx_last) r <= r_term ? R_TERM : R_IDLE;
        R_TERM: if (r_ocan) begin
          rxo_valid <= 1'b1; rxo_data <= '0; rxo_bytes <= 5'd0; rxo_kind <= K_END;
          rxo_last <= 1'b1; rxo_bad <= 1'b1; rxo_cm <= r_epm;
          r <= R_IDLE;
        end
        R_BYP: if (r_take) begin
          rxo_valid <= 1'b1; rxo_data <= rx_data; rxo_bytes <= rx_bytes; rxo_kind <= rx_kind == K_HDR ? K_HDR : K_DATA;
          rxo_last <= rx_last; rxo_bad <= 1'b0; rxo_cm <= 1'b0;
          if (rx_last) r <= R_IDLE;
        end
        default: r <= R_IDLE;
      endcase
      if (re_v) begin
        rx_err <= 1'b1; rx_code <= re_c; rx_eid <= re_id;
        r_term <= re_term;
        r_ep <= 1'b0; r_epn <= '0; r_c <= '0; r_cl <= '0; r_pl <= 1'b0; r_mac <= '0; r_hd <= '0; r_hb <= '0;
        if (r_abort) begin
          r_epm <= 1'b1;
          r <= R_TERM;                  // the interrupting packet is taken afterwards
        end else begin
          r_end <= r == R_IDLE && !gr_err ? 1'b0 : r_end || r_take && rx_last;
          r <= R_DROP;
        end
      end
      if (clr) begin
        r <= R_IDLE; r_ep <= 1'b0; r_epn <= '0; r_c <= '0; r_cl <= '0; r_mac <= '0; r_pl <= 1'b0; r_ok <= 1'b0;
        r_hd <= '0; r_hb <= '0;
        rxo_valid <= 1'b0; rxo_data <= '0;
      end
    end
  end

`ifdef FORMAL
  `include "PCIe_CXL_IDE_props.svh"
`endif
endmodule
