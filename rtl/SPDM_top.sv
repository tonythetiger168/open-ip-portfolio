// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SPDM_top v1.0: hardware SPDM 1.2 responder (DMTF DSP0274 Security Protocol
// and Data Model): device attestation with a post-quantum ML-DSA identity
// key, built on three SHA3_top engines (SHA3-384 transcripts) and one
// ML_DSA_top engine (KeyGen and Sign).
// ----------------------------------------------------------------------------
// Message formats follow the public DSP0274 1.2 text; the asymmetric
// algorithm is selected through an ExtAsym entry whose 32-bit value is a
// configuration input (asym_id), since SPDM 1.2 has no ML-DSA code point.
// Not claimed to be interoperable with a given requester stack.
//
//  - Transport: one request at a time on a byte stream (rq_*, rq_last on
//    the last byte; from a DOE mailbox or an MCTP / SPDM-over-x binding),
//    the response on a byte stream (rs_*, rs_last). rq_ready is low while a
//    request is answered. Requests of more than RQ_MAX = 128 bytes are
//    drained and answered with ERROR InvalidRequest.
//  - Requests: GET_VERSION (VERSION 1.2), GET_CAPABILITIES (CERT_CAP,
//    CHAL_CAP, MEAS_CAP with signature), NEGOTIATE_ALGORITHMS (BaseHash
//    SHA3-384, ExtAsym asym_id, DMTF measurements with SHA3-384), and after
//    them GET_DIGESTS, GET_CERTIFICATE, CHALLENGE and GET_MEASUREMENTS. Any
//    other code gets ERROR UnsupportedRequest. Errors: InvalidRequest (0x01,
//    bad length or field), UnexpectedRequest (0x04, out of order, or no
//    common hash / asymmetric algorithm), UnsupportedRequest (0x07, data =
//    request code), ResponseTooLarge (0x0D, more than the requester's
//    DataTransferSize), VersionMismatch (0x41). An ERROR leaves the
//    connection state and the transcripts unchanged.
//  - Slot 0 only: the certificate chain (the DSP0274 format: length,
//    reserved, root hash, DER certificates) is written by the host into the
//    chain store (st_sel = 0) and has cc_len bytes; slot 0 is provisioned
//    when cc_len != 0 and a key pair is present. DIGESTS returns SHA3-384 of
//    the chain, computed by the third SHA3 engine at every GET_DIGESTS and
//    CHALLENGE.
//  - Measurements: NM indices (1..NM); index i + 1 is present when m_en[i];
//    its value is a 48-byte digest written by the host into the measurement
//    store (st_sel = 1, words 12 i .. 12 i + 11) with the DMTF value type
//    m_type[8i +: 8]; m_tcb[i] puts it into the TCB measurement summary hash.
//    A measurement block is 55 bytes: index, 0x01, size 51, type, size 48,
//    digest.
//  - Transcripts (DSP0274 1.2, SHA3-384): M1 = VCA || GET_DIGESTS, DIGESTS,
//    GET_CERTIFICATE, CERTIFICATE ... || CHALLENGE || CHALLENGE_AUTH up to
//    the signature; L1 = VCA || GET_MEASUREMENTS, MEASUREMENTS ... up to the
//    signature. VCA (GET_VERSION .. ALGORITHMS, at most 256 bytes) is kept
//    so that each transcript restarts with it after it has been signed.
//  - Signature: ML-DSA (FIPS 204, pure, empty context) of the combined SPDM
//    prefix ("dmtf-spdm-v1.2.*" four times, zero padding, the context string
//    "responder-challenge_auth signing" or "responder-measurements signing")
//    followed by the transcript hash; the signing randomness rnd and the
//    responder nonces come from the random word stream (rn_*, e.g. a TRNG).
//  - Key: kg_start runs ML-DSA KeyGen (parameter set pset) from a 32-byte
//    seed (kg_sel = 0 the seed input, 1 the sideload port, e.g. a DICE CDI
//    from Root_of_Trust); the seed is wiped from the engine afterwards. The
//    private key never leaves ML_DSA_top; pk_open streams the public key out
//    (pk_*) for a certificate request. clr aborts what is running (after the
//    ML-DSA operation in progress), wipes the private key, the seed and the
//    nonces, ends the connection, and drops the rest of a request being
//    received.
//  Not implemented: sessions (KEY_EXCHANGE, PSK, secured messages, so IDE
//  key programming over a session needs firmware), mutual authentication,
//  slots 1-7, chunking (CHUNK_SEND / CHUNK_GET), SPDM 1.0 / 1.1 / 1.3,
//  RESPOND_IF_READY, opaque data, raw bit-stream measurements.
// ============================================================================
module SPDM_top #(
  parameter int NM    = 4,              // measurement indices (1..8)
  parameter int CC_AW = 14              // certificate chain store: 2^CC_AW bytes
) (
  input  logic              clk,
  input  logic              rst_n,
  // configuration
  input  logic [7:0]        ct_exp,     // CAPABILITIES CTExponent
  input  logic [31:0]       asym_id,    // ExtAsym entry of the ML-DSA key
  input  logic [1:0]        pset,       // KeyGen: 0 ML-DSA-44, 1 -65, 2 -87
  input  logic [CC_AW:0]    cc_len,     // certificate chain bytes (0: slot 0 empty)
  input  logic [NM-1:0]     m_en,       // measurement index i + 1 present
  input  logic [NM-1:0]     m_tcb,      // ... and part of the TCB summary
  input  logic [NM*8-1:0]   m_type,     // DMTF measurement value type of index i + 1
  // store write port: certificate chain (st_sel 0) and measurement words (1)
  input  logic              st_we,
  input  logic              st_sel,
  input  logic [CC_AW-3:0]  st_addr,
  input  logic [31:0]       st_data,
  // key commands
  input  logic              kg_start,
  input  logic              kg_sel,     // 0 seed, 1 sideload sl_seed
  input  logic [255:0]      seed,
  input  logic [255:0]      sl_seed,
  input  logic              sl_valid,
  input  logic              pk_open,
  input  logic              clr,
  // public key out
  output logic              pk_valid,
  output logic [31:0]       pk_data,
  output logic              pk_last,
  input  logic              pk_ready,
  // random words (nonces, signing randomness)
  input  logic              rn_valid,
  input  logic [31:0]       rn_data,
  output logic              rn_ready,
  // request in
  input  logic              rq_valid,
  input  logic [7:0]        rq_data,
  input  logic              rq_last,
  output logic              rq_ready,
  // response out
  output logic              rs_valid,
  output logic [7:0]        rs_data,
  output logic              rs_last,
  input  logic              rs_ready,
  // status
  output logic              busy,
  output logic [1:0]        conn,       // 0 none, 1 VERSION, 2 CAPABILITIES, 3 ALGORITHMS
  output logic              key_ok,
  output logic [1:0]        key_pset,
  output logic              rsp_done,   // a response was sent
  output logic              rsp_err,    // ... and it was an ERROR
  output logic [7:0]        err_code,   // code of the last ERROR sent
  output logic              kg_done,
  output logic              cmd_err     // kg_start / pk_open refused
);
  localparam int RQ_MAX = 128;
  localparam int SW     = $clog2(NM + 1);   // measurement slot index, NM = none
  localparam int NMW    = NM * 12;      // measurement store words
  localparam int CCW    = 1 << (CC_AW - 2);
  localparam int MAW    = $clog2(NMW);   // measurement store word address
  localparam int MIW    = NM > 1 ? $clog2(NM) : 1;   // measurement index
  // the largest response: MEASUREMENTS of all indices or CHALLENGE_AUTH, ML-DSA-87
  localparam int DTS_M  = 8 + 55 * NM + 34 + 4627;
  localparam int DTS    = DTS_M > 4761 ? DTS_M : 4761;
  localparam logic [12:0] DTS13 = 13'(DTS);
  // response kinds
  localparam logic [2:0] R_ERR = 3'd0, R_VER = 3'd1, R_CAP = 3'd2, R_ALG = 3'd3, R_DIG = 3'd4,
                         R_CRT = 3'd5, R_CHAL = 3'd6, R_MEAS = 3'd7;
  // request / response codes
  localparam logic [7:0] C_GVER = 8'h84, C_GCAP = 8'hE1, C_NEG = 8'hE3, C_GDIG = 8'h81,
                         C_GCRT = 8'h82, C_CHAL = 8'h83, C_GMEAS = 8'hE0;
  localparam logic [7:0] E_INV = 8'h01, E_UNEXP = 8'h04, E_UNSUP = 8'h07, E_BIG = 8'h0D, E_VER = 8'h41;
  localparam logic [7:0] V10 = 8'h10, V12 = 8'h12;
  // ML-DSA buffer word addresses
  localparam logic [12:0] W_PK = 13'h0000, W_SK = 13'h0288, W_SIG = 13'h0750, W_XI = 13'h0BD8,
                          W_RND = 13'h0BE8, W_MSG = 13'h1000;
  localparam logic [11:0] N_WIPE = 12'd2408;   // words 0x288 .. 0xBEF: SK, SIG, XI, KC, RND
  localparam logic [14:0] MP_LEN = 15'd150;    // M' = 0, 0, prefix (100), hash (48)
  // response segments, in response order
  /* verilator lint_off UNUSEDPARAM */  // G_OPQ: the default segment (and the formal properties)
  localparam int G_HB = 0, G_D0 = 1, G_CC = 2, G_MB = 3, G_NON = 4, G_D1 = 5, G_OPQ = 6;
  /* verilator lint_on UNUSEDPARAM */
  // transcript targets
  localparam int T_M = 0, T_L = 1, T_V = 2;

  function automatic logic [12:0] sig_len(input logic [1:0] p);
    sig_len = p == 2'd0 ? 13'd2420 : p == 2'd1 ? 13'd3309 : 13'd4627;
  endfunction
  function automatic logic [11:0] pk_words(input logic [1:0] p);
    pk_words = p == 2'd0 ? 12'd328 : p == 2'd1 ? 12'd488 : 12'd648;
  endfunction
  function automatic logic [SW-1:0] popc(input logic [NM-1:0] m);
    popc = '0;
    for (int i = 0; i < NM; i++) popc = popc + SW'(m[i]);
  endfunction
  // lowest set bit of m at or above i (NM when none)
  function automatic logic [SW-1:0] next_set(input logic [NM-1:0] m, input logic [SW-1:0] i);
    next_set = SW'(NM);
    for (int j = NM - 1; j >= 0; j--) if (m[j] && SW'(j) >= i) next_set = SW'(j);
  endfunction
  // the signed message M' = 0, 0 (pure ML-DSA, empty context) || prefix || hash
  function automatic logic [7:0] prefix_byte(input logic [3:0] j);   // byte j of the 16-byte string
    logic [127:0] s;
    s = "dmtf-spdm-v1.2.*";
    prefix_byte = s[127 - 8 * j -: 8];
  endfunction
  function automatic logic [7:0] ctx_byte(input logic cm, input logic [5:0] j);  // j < 36
    logic [255:0] sc;
    logic [239:0] sm;
    logic [4:0]   jo;
    logic [7:0]   bi;
    sc = "responder-challenge_auth signing";   // 32 bytes behind 4 zero bytes
    sm = "responder-measurements signing";     // 30 bytes behind 6 zero bytes
    jo = 5'(j - (cm ? 6'd6 : 6'd4));
    bi = (cm ? 8'd239 : 8'd255) - {jo, 3'b000};
    if (!cm) ctx_byte = j < 6'd4 ? 8'h00 : sc[bi -: 8];
    else     ctx_byte = j < 6'd6 ? 8'h00 : sm[bi -: 8];
  endfunction
  function automatic logic [7:0] mp_byte(input logic cm, input logic [383:0] h, input logic [7:0] k);
    if (k < 8'd2)        mp_byte = 8'h00;
    else if (k < 8'd66)  mp_byte = prefix_byte(4'(k - 8'd2));
    else if (k < 8'd102) mp_byte = ctx_byte(cm, 6'(k - 8'd66));
    else if (k < 8'd150) mp_byte = h[8 * (k - 8'd102) +: 8];
    else                 mp_byte = 8'h00;
  endfunction

  // ---------------- stores ----------------
  logic [31:0] ccm [0:CCW-1];
  logic [31:0] mvm [0:NMW-1];
  logic [3:0]  st_slot;
  logic [3:0]  st_word;
  assign st_slot = 4'(st_addr >> 4);
  assign st_word = st_addr[3:0];
  wire st_mv = (st_addr >> 4) < (CC_AW - 2)'(NM) && st_word < 4'd12;
  always_ff @(posedge clk) begin
    if (st_we && !st_sel) ccm[st_addr] <= st_data;
    if (st_we && st_sel && st_mv) mvm[MAW'(8'(st_slot) * 8'd12 + 8'(st_word))] <= st_data;
  end

  // ---------------- engines ----------------
  logic [2:0]   th_start, th_wipe, th_fin, th_bv, th_br, th_done;
  logic [7:0]   th_bd;
  logic [383:0] th_dig [0:2];          // 0 M, 1 L, 2 aux
`ifdef FORMAL
  // the formal run cuts the engines: their outputs are free values each clock
  // (the control properties do not depend on them; the engines are checked
  // bit-exact in simulation)
  (* anyseq *) logic [2:0]   f_th_br, f_th_done;
  (* anyseq *) logic [383:0] f_th_dig0, f_th_dig1, f_th_dig2;
  assign th_br = f_th_br;
  assign th_done = f_th_done;
  assign th_dig[0] = f_th_dig0;
  assign th_dig[1] = f_th_dig1;
  assign th_dig[2] = f_th_dig2;
`else
  for (genvar e = 0; e < 3; e++) begin : g_th
    SPDM_th u_th (.clk(clk), .rst_n(rst_n), .start(th_start[e]), .wipe(th_wipe[e]),
                  .b_valid(th_bv[e]), .b_data(th_bd), .b_ready(th_br[e]),
                  .fin(th_fin[e]), .dig(th_dig[e]), .done(th_done[e]));
  end
`endif

  logic        ml_start, ml_done;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        ml_busy;                 // read by the coverage checker only
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ml_kg;                   // the operation started is KeyGen
  logic        hp_load, hw_valid, hw_ready, hr_en, hr_valid, hr_ready;
  logic [12:0] hp_addr;
  logic [31:0] hw_data, hr_data;
  // KeyGen in S_KGW, Sign otherwise; err (reserved op / pset / mlen), fail
  // (Verify) and tries are never used
`ifdef FORMAL
  (* anyseq *) logic        f_ml_busy, f_ml_done, f_hw_ready, f_hr_valid;
  (* anyseq *) logic [31:0] f_hr_data;
  assign ml_busy = f_ml_busy;
  assign ml_done = f_ml_done;
  assign hw_ready = f_hw_ready;
  assign hr_valid = f_hr_valid;
  assign hr_data = f_hr_data;
`else
  /* verilator lint_off PINCONNECTEMPTY */
  ML_DSA_top u_mldsa (.clk(clk), .rst_n(rst_n), .start(ml_start), .op({1'b0, !ml_kg}), .pset(key_pset),
                      .ext_mu(1'b0), .mlen(MP_LEN), .busy(ml_busy), .done(ml_done), .err(),
                      .fail(), .tries(), .hp_load(hp_load), .hp_addr(hp_addr),
                      .hw_valid(hw_valid), .hw_data(hw_data), .hw_ready(hw_ready), .hr_en(hr_en),
                      .hr_valid(hr_valid), .hr_data(hr_data), .hr_ready(hr_ready));
  /* verilator lint_on PINCONNECTEMPTY */
`endif

  // ---------------- state ----------------
  typedef enum logic [4:0] {S_IDLE, S_RX, S_DEC, S_AX, S_RN, S_FRQ, S_OUT, S_FIN, S_MW, S_SG,
                            S_SIGO, S_RPL, S_KG, S_KGW, S_KGZ, S_PK, S_CLR} st_t;
  st_t          st;
  logic         ph;                    // sub-step: 0 load the ML-DSA pointer
  logic [7:0]   rqb [0:RQ_MAX-1];
  logic [7:0]   rq_n;                  // bytes received (saturates at 255)
  logic         rq_ovf, drain;
  logic [7:0]   vca [0:255];
  logic [7:0]   vca_n;                 // VCA is at most 220 bytes
  logic [2:0]   rt;                    // response kind
  logic [6:0]   seg_en;
  logic [2:0]   seg;
  logic [15:0]  k;                     // byte of the segment / words written
  logic [CC_AW-1:0] cc_off;
  logic [CC_AW:0]   cc_cnt;
  logic [NM-1:0] mb_mask, ms_mask;
  logic [SW-1:0] mb_slot;
  logic [5:0]   mb_j;
  logic [2:0]   tgt;                   // transcripts fed: M, L, VCA
  logic         sgn, sg_cm;            // signed response; 0 CHALLENGE_AUTH, 1 MEASUREMENTS context
  logic         need_ms, need_rn, ax_ms;
  logic         is_err, e_v10;
  logic [7:0]   e_code;
  logic [255:0] nonce;
  logic [383:0] cc_dig;
  logic         hash_ok, asym_ok, meas_ok;
  logic [12:0]  dts;                   // min(requester DataTransferSize, DTS)
  logic         clr_p;
  logic [255:0] kseed;

  // ---------------- request decode ----------------
  // header fields
  wire [7:0]  q_ver = rqb[0];
  wire [7:0]  q_code = rqb[1];
  wire [7:0]  q_p1 = rqb[2];
  wire [7:0]  q_p2 = rqb[3];
  wire        slot_ok = cc_len != '0 && key_ok;
  wire        cr_ok = conn == 2'd3 && hash_ok && asym_ok;
  // GET_CAPABILITIES
  wire [31:0] q_dts = {rqb[15], rqb[14], rqb[13], rqb[12]};
  wire [31:0] q_msz = {rqb[19], rqb[18], rqb[17], rqb[16]};
  // NEGOTIATE_ALGORITHMS
  wire [15:0] q_alen = {rqb[5], rqb[4]};
  wire [7:0]  q_na = rqb[28], q_ne = rqb[29];
  wire [8:0]  q_nae = 9'(q_na) + 9'(q_ne);
  logic       q_asym;
  always_comb begin
    q_asym = 1'b0;
    for (int i = 0; i < 20; i++)
      if (8'(i) < q_na && {rqb[35 + 4 * i], rqb[34 + 4 * i], rqb[33 + 4 * i], rqb[32 + 4 * i]} == asym_id) q_asym = 1'b1;
  end
  // GET_CERTIFICATE
  wire [15:0] q_off = {rqb[5], rqb[4]};
  wire [15:0] q_len = {rqb[7], rqb[6]};
  // bytes after the offset, and the portion sent (clipped to the request and to DataTransferSize)
  function automatic logic [12:0] c_por(input logic [CC_AW:0] av, input logic [15:0] ln, input logic [12:0] d);
    logic [CC_AW:0] p;
    p = 17'(ln) < 17'(av) ? (CC_AW + 1)'(ln) : av;
    c_por = 17'(p) < 17'(d - 13'd8) ? 13'(p) : d - 13'd8;
  endfunction
  wire [CC_AW:0] c_av = cc_len - (CC_AW + 1)'(q_off);
  wire [12:0]    c_pn = c_por(c_av, q_len, dts);   // below DTS
  // GET_MEASUREMENTS
  wire        q_sig = q_p1[0];
  wire [NM-1:0] q_mask = q_p2 == 8'hFF ? m_en : q_p2 == 8'h00 ? '0 : NM'(1) << (q_p2 - 8'd1);
  wire        q_idx_ok = q_p2 == 8'hFF || q_p2 == 8'h00 || (q_p2 <= 8'(NM) && m_en[MIW'(q_p2 - 8'd1)]);
  wire [SW-1:0] q_nb = popc(q_mask);

  // the decision for a request: error code (0: none) and what to do
  logic [7:0] d_err;
  always_comb begin
    d_err = 8'h00;
    if (rq_ovf || rq_n < 8'd4) d_err = E_INV;
    else if (q_code == C_GVER) d_err = q_ver != V10 ? E_VER : rq_n != 8'd4 ? E_INV : 8'h00;
    else if (!(q_code == C_GCAP || q_code == C_NEG || q_code == C_GDIG || q_code == C_GCRT ||
               q_code == C_CHAL || q_code == C_GMEAS)) d_err = E_UNSUP;
    else if (conn == 2'd0) d_err = E_UNEXP;
    else if (q_ver != V12) d_err = E_VER;
    else begin
      case (q_code)
        C_GCAP: d_err = conn != 2'd1 ? E_UNEXP :
                        rq_n != 8'd20 || q_dts < 32'd42 || q_msz < q_dts ? E_INV : 8'h00;
        C_NEG:  d_err = conn != 2'd2 ? E_UNEXP :
                        16'(rq_n) != q_alen || rq_n < 8'd32 || q_nae > 9'd20 ||
                        q_alen < 16'd32 + 16'd4 * 16'(q_nae) ? E_INV : 8'h00;
        C_GDIG: d_err = !cr_ok ? E_UNEXP : rq_n != 8'd4 ? E_INV : slot_ok && dts < 13'd52 ? E_BIG : 8'h00;
        C_GCRT: d_err = !cr_ok ? E_UNEXP :
                        rq_n != 8'd8 || q_p1[3:0] != 4'd0 || !slot_ok || 17'(q_off) >= 17'(cc_len) ? E_INV : 8'h00;
        C_CHAL: d_err = !cr_ok ? E_UNEXP :
                        rq_n != 8'd36 || q_p1 != 8'h00 || !slot_ok ||
                        !(q_p2 == 8'h00 || q_p2 == 8'h01 || q_p2 == 8'hFF) ? E_INV :
                        13'd86 + (q_p2 != 8'h00 ? 13'd48 : 13'd0) + sig_len(key_pset) > dts ? E_BIG : 8'h00;
        default: d_err = !cr_ok ? E_UNEXP : !meas_ok ? E_UNSUP :
                        rq_n != (q_sig ? 8'd37 : 8'd4) || !q_idx_ok || (q_sig && (rqb[36] != 8'h00 || !slot_ok)) ? E_INV :
                        13'd42 + 13'd55 * 13'(q_nb) + (q_sig ? sig_len(key_pset) : 13'd0) > dts ? E_BIG : 8'h00;
      endcase
    end
  end

  // ---------------- response byte generator ----------------
  wire [CC_AW-1:0] cc_a = cc_off + CC_AW'(k);
  wire [31:0] cc_w = ccm[cc_a[CC_AW-1:2]];
  wire [5:0]  mj7 = mb_j - 6'd7;
  wire [31:0] mv_w = mvm[MAW'(8'(mb_slot) * 8'd12 + 8'(mj7[5:2]))];
  logic [7:0] mb_byte;
  always_comb
    case (mb_j)
      6'd0:    mb_byte = 8'(mb_slot) + 8'd1;
      6'd1:    mb_byte = 8'h01;
      6'd2:    mb_byte = 8'd51;
      6'd3:    mb_byte = 8'h00;
      6'd4:    mb_byte = m_type[8 * mb_slot +: 8];
      6'd5:    mb_byte = 8'd48;
      6'd6:    mb_byte = 8'h00;
      default: mb_byte = mv_w[8 * mj7[1:0] +: 8];
    endcase
  // the response header, formed from the request (still in rqb) and the state
  logic [7:0]  hb;
  logic [3:0]  hb_w;                   // header length in 32-bit words
  always_comb begin
    hb = 8'h00;
    case (rt)
      R_ERR: hb_w = 4'd1;
      R_CAP: hb_w = 4'd5;
      R_ALG: hb_w = asym_ok ? 4'd10 : 4'd9;
      R_DIG, R_CHAL: hb_w = 4'd1;
      default: hb_w = 4'd2;            // VERSION, CERTIFICATE, MEASUREMENTS
    endcase
    case (k[5:0])
      6'd0: hb = rt == R_ERR ? (e_v10 ? V10 : V12) : rt == R_VER ? V10 : V12;
      6'd1: hb = rt == R_ERR ? 8'h7F : q_code & 8'h7F;
      6'd2: hb = rt == R_ERR ? e_code : rt == R_MEAS && q_p2 == 8'h00 ? 8'(popc(m_en)) : 8'h00;
      6'd3: hb = rt == R_ERR ? (e_code == E_UNSUP ? q_code : 8'h00) : rt == R_DIG ? {7'd0, slot_ok} :
                 rt == R_CHAL ? 8'h01 : 8'h00;
      6'd4: hb = rt == R_ALG ? (asym_ok ? 8'd40 : 8'd36) : rt == R_CRT ? 8'(cc_cnt) :
                 rt == R_MEAS ? 8'(popc(mb_mask)) : 8'h00;
      6'd5: hb = rt == R_VER ? 8'd1 : rt == R_CAP ? ct_exp : rt == R_CRT ? 8'(cc_cnt >> 8) :
                 rt == R_MEAS ? 8'(13'd55 * 13'(popc(mb_mask))) : 8'h00;
      6'd6: hb = rt == R_ALG ? {7'd0, meas_ok} : rt == R_CRT ? 8'(c_av - cc_cnt) :
                 rt == R_MEAS ? 8'((13'd55 * 13'(popc(mb_mask))) >> 8) : 8'h00;
      6'd7: hb = rt == R_VER ? 8'h12 : rt == R_CRT ? 8'((c_av - cc_cnt) >> 8) : 8'h00;
      6'd8: hb = rt == R_CAP ? 8'h16 : rt == R_ALG && meas_ok ? 8'h20 : 8'h00;
      6'd12, 6'd16: hb = rt == R_CAP ? DTS13[7:0] : rt == R_ALG && k[4] && hash_ok ? 8'h10 : 8'h00;
      6'd13, 6'd17: hb = rt == R_CAP ? 8'(DTS13 >> 8) : 8'h00;
      6'd32: hb = {7'd0, asym_ok};
      6'd36: hb = asym_id[7:0];
      6'd37: hb = asym_id[15:8];
      6'd38: hb = asym_id[23:16];
      6'd39: hb = asym_id[31:24];
      default: ;
    endcase
  end
  logic [7:0]  g_byte;
  logic [CC_AW:0] g_len;
  always_comb begin
    g_byte = 8'h00;
    g_len = (CC_AW + 1)'(2);
    case (seg)
      3'(G_HB):  begin g_byte = hb;                       g_len = (CC_AW + 1)'({hb_w, 2'b00}); end
      3'(G_D0):  begin g_byte = cc_dig[8 * k[5:0] +: 8];  g_len = (CC_AW + 1)'(48); end
      3'(G_CC):  begin g_byte = cc_w[8 * cc_a[1:0] +: 8]; g_len = cc_cnt; end
      3'(G_MB):  begin g_byte = mb_byte;                  g_len = (CC_AW + 1)'(9'd55 * 9'(popc(mb_mask))); end
      3'(G_NON): begin g_byte = nonce[8 * k[4:0] +: 8];   g_len = (CC_AW + 1)'(32); end
      3'(G_D1):  begin g_byte = th_dig[2][8 * k[5:0] +: 8]; g_len = (CC_AW + 1)'(48); end
      default:   ;                                        // G_OPQ: OpaqueDataLength 0
    endcase
  end
  // the next enabled segment after s (7: none)
  function automatic logic [2:0] next_seg(input logic [6:0] en, input logic [2:0] s);
    next_seg = 3'd7;
    for (int i = 6; i >= 0; i--) if (en[i] && 3'(i) > s) next_seg = 3'(i);
  endfunction
  wire        g_end = k[CC_AW:0] == g_len - (CC_AW + 1)'(1);
  wire [2:0]  seg_nx = next_seg(seg_en, seg);

  // ---------------- handshakes ----------------
  wire        tg_rdy = (!tgt[T_M] || th_br[0]) && (!tgt[T_L] || th_br[1]);
  wire [12:0] slen = sig_len(key_pset);
  assign rq_ready = st == S_RX || (st == S_IDLE && (drain || !(clr_p || clr || kg_start || pk_open)));
  assign rs_valid = (st == S_OUT && tg_rdy) || (st == S_SIGO && ph && hr_valid);
  assign rs_data  = st == S_SIGO ? hr_data[8 * k[1:0] +: 8] : g_byte;
  assign rs_last  = st == S_SIGO ? k[12:0] == slen - 13'd1 : g_end && seg_nx == 3'd7 && !sgn;
  wire        rs_go = rs_valid && rs_ready;
  wire        ax_go = st == S_AX && ph && k < 16'hFFFE && th_br[2];
  wire        frq_go = st == S_FRQ && tg_rdy;
  wire        rpl_go = st == S_RPL && ph && k[7:0] != vca_n && th_br[{1'b0, sg_cm}];
  assign th_bd = st == S_FRQ ? rqb[k[6:0]] : st == S_RPL ? vca[k[7:0]] : g_byte;
  assign th_bv[0] = (st == S_OUT && rs_go || frq_go) && tgt[T_M] || rpl_go && !sg_cm;
  assign th_bv[1] = (st == S_OUT && rs_go || frq_go) && tgt[T_L] || rpl_go && sg_cm;
  assign th_bv[2] = ax_go;
  assign pk_valid = st == S_PK && ph && hr_valid;
  assign pk_data  = hr_data;
  assign pk_last  = k[11:0] == pk_words(key_pset) - 12'd1;
  assign rn_ready = st == S_RN && (k[3] ? ph && hw_ready : 1'b1);
  wire        rn_go = rn_valid && rn_ready;

  // ML-DSA host port
  always_comb begin
    hp_load = 1'b0; hp_addr = '0; hw_valid = 1'b0; hw_data = '0; hr_en = 1'b0; hr_ready = 1'b0;
    ml_start = 1'b0; ml_kg = 1'b0;
    case (st)
      S_RN:   begin hp_load = k[3] && !ph; hp_addr = W_RND;
                    hw_valid = k[3] && ph && rn_valid; hw_data = rn_data; end
      S_MW:   begin hp_load = !ph; hp_addr = W_MSG; hw_valid = ph;
                    for (int i = 0; i < 4; i++) hw_data[8 * i +: 8] = mp_byte(sg_cm, th_dig[{1'b0, sg_cm}], 8'({k[5:0], 2'(i)})); end
      S_SG:   ml_start = !ph;
      S_SIGO: begin hp_load = !ph; hp_addr = W_SIG; hr_en = ph;
                    hr_ready = ph && rs_ready && (k[1:0] == 2'd3 || k[12:0] == slen - 13'd1); end
      S_KG:   begin hp_load = !ph; hp_addr = W_XI; hw_valid = ph; hw_data = kseed[32 * k[2:0] +: 32]; end
      S_KGW:  begin ml_start = !ph; ml_kg = 1'b1; end
      S_KGZ:  begin hp_load = !ph; hp_addr = W_XI; hw_valid = ph; end
      S_PK:   begin hp_load = !ph; hp_addr = W_PK; hr_en = ph; hr_ready = ph && pk_ready; end
      S_CLR:  begin hp_load = !ph; hp_addr = W_SK; hw_valid = ph; end
      default: ;
    endcase
  end

  // engine controls
  always_comb begin
    th_start = '0; th_wipe = '0; th_fin = '0;
    if (st == S_DEC && d_err == 8'h00 && q_code == C_GVER) th_start[1:0] = 2'b11;
    if (st == S_AX && !ph) th_start[2] = 1'b1;
    if (st == S_AX && ph && k == 16'hFFFE) th_fin[2] = 1'b1;
    if (st == S_FIN && !ph) th_fin[{1'b0, sg_cm}] = 1'b1;
    if (st == S_RPL && !ph) th_start[{1'b0, sg_cm}] = 1'b1;
    if (st == S_CLR && !ph) th_wipe = 3'b111;
  end

  wire        busy_ml = st == S_KGW || st == S_SG;   // an ML-DSA operation runs
  assign busy = st != S_IDLE;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; ph <= 1'b0; rq_n <= '0; rq_ovf <= 1'b0; drain <= 1'b0; vca_n <= '0;
      rt <= R_ERR; e_v10 <= 1'b0; seg_en <= '0; seg <= '0; k <= '0; cc_off <= '0; cc_cnt <= '0;
      mb_mask <= '0; ms_mask <= '0; mb_slot <= '0; mb_j <= '0; tgt <= '0; sgn <= 1'b0; sg_cm <= 1'b0;
      need_ms <= 1'b0; need_rn <= 1'b0; ax_ms <= 1'b0; is_err <= 1'b0;
      e_code <= '0; nonce <= '0; cc_dig <= '0; hash_ok <= 1'b0; asym_ok <= 1'b0; meas_ok <= 1'b0;
      dts <= '0; clr_p <= 1'b0; kseed <= '0;
      conn <= '0; key_ok <= 1'b0; key_pset <= '0; rsp_done <= 1'b0; rsp_err <= 1'b0; err_code <= '0;
      kg_done <= 1'b0; cmd_err <= 1'b0;
    end else begin
      rsp_done <= 1'b0; rsp_err <= 1'b0; kg_done <= 1'b0; cmd_err <= 1'b0;
      if (clr) clr_p <= 1'b1;
      if ((kg_start || pk_open) && st != S_IDLE) cmd_err <= 1'b1;
      // drop the rest of a request cut by clr
      if (st == S_IDLE && drain && rq_valid && rq_last) drain <= 1'b0;
      if ((clr || clr_p) && !busy_ml && st != S_CLR) begin
        st <= S_CLR; ph <= 1'b0; k <= '0;
        if (st == S_RX) drain <= !(rq_valid && rq_last);
      end else begin
        case (st)
          S_IDLE: begin
            ph <= 1'b0; k <= '0;
            if (kg_start) begin
              if (drain || pset == 2'd3 || (kg_sel && !sl_valid)) cmd_err <= 1'b1;
              else begin
                st <= S_KG; key_pset <= pset; key_ok <= 1'b0; kseed <= kg_sel ? sl_seed : seed;
              end
            end else if (pk_open) begin
              if (drain || !key_ok) cmd_err <= 1'b1;
              else st <= S_PK;
            end else if (rq_valid && !drain) begin
              rqb[0] <= rq_data; rq_n <= 8'd1; rq_ovf <= 1'b0;
              st <= rq_last ? S_DEC : S_RX;
            end
          end
          S_RX: if (rq_valid) begin
            if (rq_n < 8'(RQ_MAX)) rqb[rq_n[6:0]] <= rq_data;
            if (rq_n == 8'(RQ_MAX)) rq_ovf <= 1'b1;
            if (rq_n != 8'hFF) rq_n <= rq_n + 8'd1;
            if (rq_last) st <= S_DEC;
          end
          S_DEC: begin
            // defaults: an ERROR response
            is_err <= d_err != 8'h00; e_code <= d_err; rt <= R_ERR;
            e_v10 <= conn == 2'd0 || q_code == C_GVER || rq_n < 8'd2;
            seg_en <= 7'b0000001; tgt <= '0; sgn <= 1'b0; need_ms <= 1'b0;
            need_rn <= 1'b0; cc_off <= '0; cc_cnt <= '0;
            mb_mask <= '0; ms_mask <= '0; seg <= '0; k <= '0;
            st <= S_FRQ;
            if (d_err != 8'h00) st <= S_OUT;
            else case (q_code)
              C_GVER: begin
                rt <= R_VER; tgt <= 3'b111; conn <= 2'd1; vca_n <= '0;
                hash_ok <= 1'b0; asym_ok <= 1'b0; meas_ok <= 1'b0;
              end
              C_GCAP: begin
                rt <= R_CAP; tgt <= 3'b111; conn <= 2'd2;
                dts <= q_dts < 32'(DTS) ? q_dts[12:0] : DTS13;
              end
              C_NEG: begin
                rt <= R_ALG; tgt <= 3'b111; conn <= 2'd3;
                hash_ok <= rqb[12][4]; asym_ok <= q_asym; meas_ok <= rqb[6][0];
              end
              C_GDIG: begin
                rt <= R_DIG; seg_en <= {5'd0, slot_ok, 1'b1}; tgt <= 3'b001;
              end
              C_GCRT: begin
                rt <= R_CRT; cc_off <= CC_AW'(q_off); cc_cnt <= (CC_AW + 1)'(c_pn);
                seg_en <= {4'd0, c_pn != '0, 2'b01}; tgt <= 3'b001;
              end
              C_CHAL: begin
                rt <= R_CHAL; seg_en <= {1'b1, q_p2 != 8'h00, 1'b1, 2'b00, 2'b11};
                need_ms <= q_p2 != 8'h00; ms_mask <= q_p2 == 8'h01 ? m_en & m_tcb : m_en;
                need_rn <= 1'b1; sgn <= 1'b1; sg_cm <= 1'b0; tgt <= 3'b001;
              end
              default: begin           // GET_MEASUREMENTS
                rt <= R_MEAS; mb_mask <= q_mask;
                seg_en <= {1'b1, 1'b0, 1'b1, q_nb != '0, 3'b001};
                need_rn <= 1'b1; sgn <= q_sig; sg_cm <= 1'b1; tgt <= 3'b010;
              end
            endcase
            if (d_err == 8'h00 && (q_code == C_GDIG && slot_ok || q_code == C_CHAL)) begin
              st <= S_AX; ax_ms <= 1'b0; mb_mask <= '0;
            end else if (d_err == 8'h00 && q_code == C_GMEAS) st <= S_RN;
          end
          // aux hash: the certificate chain (ax_ms 0), then the measurement summary
          S_AX: begin
            if (!ph) begin
              ph <= 1'b1; k <= '0; seg <= ax_ms ? 3'(G_MB) : 3'(G_CC);
              cc_off <= '0; cc_cnt <= cc_len; mb_mask <= ms_mask; mb_slot <= next_set(ms_mask, '0); mb_j <= '0;
              // an empty summary: close at once
              if (ax_ms && ms_mask == '0) k <= 16'hFFFE;
            end else if (k == 16'hFFFE) k <= 16'hFFFF;
            else if (k == 16'hFFFF) begin
              if (th_done[2]) begin
                ph <= 1'b0;
                if (!ax_ms) cc_dig <= th_dig[2];
                if (!ax_ms && need_ms) ax_ms <= 1'b1;
                else begin
                  st <= need_rn ? S_RN : S_FRQ; k <= '0; seg <= '0;
                  cc_off <= '0; cc_cnt <= '0; mb_mask <= '0;
                end
              end
            end else if (ax_go) begin
              k <= g_end ? 16'hFFFE : k + 16'd1;
              if (seg == 3'(G_MB)) begin
                mb_j <= mb_j == 6'd54 ? 6'd0 : mb_j + 6'd1;
                if (mb_j == 6'd54) mb_slot <= next_set(mb_mask, mb_slot + SW'(1));
              end
            end
          end
          // nonce (8 words), then rnd into the ML-DSA buffer (8 words) when signing
          S_RN: begin
            if (k[3] && !ph) ph <= 1'b1;
            else if (rn_go) begin
              if (!k[3]) nonce[32 * k[2:0] +: 32] <= rn_data;
              k <= k + 16'd1;
              if (k[2:0] == 3'd7 && (k[3] || !sgn)) begin st <= S_FRQ; k <= '0; ph <= 1'b0; end
            end
          end
          // the request into the transcripts
          S_FRQ: begin
            if (frq_go) begin
              if (tgt[T_V]) begin vca[vca_n] <= rqb[k[6:0]]; vca_n <= vca_n + 8'd1; end
              k <= k + 16'd1;
              if (k[7:0] == rq_n - 8'd1) begin
                st <= S_OUT; k <= '0; seg <= '0;
                mb_slot <= next_set(mb_mask, '0); mb_j <= '0;
              end
            end
          end
          S_OUT: if (rs_go) begin
            if (tgt[T_V]) begin vca[vca_n] <= g_byte; vca_n <= vca_n + 8'd1; end
            if (seg == 3'(G_MB)) begin
              mb_j <= mb_j == 6'd54 ? 6'd0 : mb_j + 6'd1;
              if (mb_j == 6'd54) mb_slot <= next_set(mb_mask, mb_slot + SW'(1));
            end
            if (!g_end) k <= k + 16'd1;
            else begin
              k <= '0;
              if (seg_nx != 3'd7) begin
                seg <= seg_nx;
                if (seg_nx == 3'(G_MB)) begin mb_slot <= next_set(mb_mask, '0); mb_j <= '0; end
              end else if (sgn) begin st <= S_FIN; ph <= 1'b0; end
              else begin
                st <= S_IDLE; rsp_done <= 1'b1; rsp_err <= is_err;
                if (is_err) err_code <= e_code;
              end
            end
          end
          S_FIN: begin
            ph <= 1'b1;
            if (ph && th_done[{1'b0, sg_cm}]) begin st <= S_MW; ph <= 1'b0; k <= '0; end
          end
          S_MW: begin
            if (!ph) ph <= 1'b1;
            else begin                  // the ML-DSA engine is idle: hw_ready
              k <= k + 16'd1;
              if (k[5:0] == 6'd37) begin st <= S_SG; ph <= 1'b0; k <= '0; end
            end
          end
          S_SG: begin
            ph <= 1'b1;
            if (ph && ml_done) begin st <= S_SIGO; ph <= 1'b0; k <= '0; end
          end
          S_SIGO: begin
            if (!ph) ph <= 1'b1;
            else if (rs_go) begin
              k <= k + 16'd1;
              if (k[12:0] == slen - 13'd1) begin st <= S_RPL; ph <= 1'b0; k <= '0; end
            end
          end
          // restart the signed transcript with VCA
          S_RPL: begin
            if (!ph) ph <= 1'b1;
            else if (k[7:0] == vca_n) begin st <= S_IDLE; rsp_done <= 1'b1; end
            else if (rpl_go) k <= k + 16'd1;
          end
          // KeyGen: seed into XI, run, wipe XI
          S_KG: begin
            if (!ph) ph <= 1'b1;
            else begin
              k <= k + 16'd1;
              if (k[2:0] == 3'd7) begin st <= S_KGW; ph <= 1'b0; k <= '0; kseed <= '0; end
            end
          end
          S_KGW: begin
            ph <= 1'b1;
            if (ph && ml_done) begin st <= S_KGZ; ph <= 1'b0; k <= '0; end
          end
          S_KGZ: begin
            if (!ph) ph <= 1'b1;
            else begin
              k <= k + 16'd1;
              if (k[2:0] == 3'd7) begin st <= S_IDLE; key_ok <= 1'b1; kg_done <= 1'b1; end
            end
          end
          S_PK: begin
            if (!ph) ph <= 1'b1;
            else if (pk_valid && pk_ready) begin
              k <= k + 16'd1;
              if (pk_last) st <= S_IDLE;
            end
          end
          default: begin               // S_CLR: wipe the key area of the ML-DSA buffer
            clr_p <= 1'b0;
            if (!ph) begin
              ph <= 1'b1; key_ok <= 1'b0; conn <= 2'd0; vca_n <= '0; nonce <= '0; cc_dig <= '0;
              kseed <= '0; hash_ok <= 1'b0; asym_ok <= 1'b0; meas_ok <= 1'b0;
            end else begin
              k <= k + 16'd1;
              if (k[11:0] == N_WIPE - 12'd1) st <= S_IDLE;
            end
          end
        endcase
      end
    end
  end

`ifdef FORMAL
  `include "SPDM_props.svh"
`endif
endmodule

// ----------------------------------------------------------------------------
// SPDM_th: a SHA3-384 hash over a byte stream (a transcript or the aux hash):
// start opens a message, bytes are packed into 64-bit lanes, fin closes the
// message and the 48-byte digest is held in dig (byte i in [8i +: 8]) with a
// done pulse. wipe clears the SHA3 state (a start with a reserved mode).
// ----------------------------------------------------------------------------
/* verilator lint_off DECLFILENAME */
module SPDM_th (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          start,
  input  logic          wipe,
  input  logic          b_valid,
  input  logic [7:0]    b_data,
  output logic          b_ready,
  input  logic          fin,
  output logic [383:0]  dig,
  output logic          done
);
  logic [63:0] lane;
  logic [3:0]  nb;
  logic        finp, rd;
  logic [2:0]  wi;
  logic        in_ready, out_valid, out_last;
  logic [63:0] out_data;
  wire         full = nb == 4'd8;
  wire         in_valid = full || finp;
  /* verilator lint_off PINCONNECTEMPTY */
  SHA3_top u_sha3 (.clk(clk), .rst_n(rst_n), .start(start || wipe), .mode(wipe ? 3'd7 : 3'd2),
                   .in_valid(in_valid), .in_data(lane), .in_bytes(nb), .in_last(finp && !full),
                   .in_ready(in_ready), .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
                   .out_ready(rd), .busy(), .done(), .err());
  /* verilator lint_on PINCONNECTEMPTY */
  assign b_ready = !full && !finp && !rd && !start && !wipe;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lane <= '0; nb <= '0; finp <= 1'b0; rd <= 1'b0; wi <= '0; dig <= '0; done <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start || wipe) begin
        lane <= '0; nb <= '0; finp <= 1'b0; rd <= 1'b0; wi <= '0;
      end else begin
        if (b_valid && b_ready) begin
          lane[8 * nb[2:0] +: 8] <= b_data;
          nb <= nb + 4'd1;
        end
        if (fin) finp <= 1'b1;
        if (in_valid && in_ready) begin
          nb <= '0; lane <= '0;
          if (!full) begin finp <= 1'b0; rd <= 1'b1; wi <= '0; end
        end
        if (rd && out_valid) begin
          dig[64 * wi +: 64] <= out_data;
          wi <= wi + 3'd1;
          if (out_last) begin rd <= 1'b0; done <= 1'b1; end
        end
      end
    end
  end
endmodule
