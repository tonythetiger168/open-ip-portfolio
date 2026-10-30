// SPDX-License-Identifier: Apache-2.0
// Root of Trust: concurrent SVA against a model built from the ports alone,
// plus functional coverage. The model
//  * learns the OTP from the words the core reads (acknowledged reads only)
//    and decodes the lifecycle from the first three reads after reset;
//  * hashes the accepted image words with its own SHA-256 (the textbook
//    64-word message schedule; the round constants and the initial value are
//    computed from the cube and square roots of the first primes, as FIPS
//    180-4 defines them) and decides whether the boot must pass;
//  * computes the expected key, HMAC(UDS, digest || lifecycle word), with
//    the UDS words the core read;
//  * hashes each transition token and compares it with the stored hash, and
//    from that and the lifecycle rules decides every OTP program, cmd_err
//    and alert the command must produce.
`include "cov_macros.svh"
module Root_of_Trust_sva (
  input logic         clk, rst_n,
  input logic         otp_req, otp_we, otp_ack,
  input logic [5:0]   otp_addr,
  input logic [31:0]  otp_wdata, otp_rdata,
  input logic         cmd_start, cmd_busy, cmd_done, cmd_err,
  input logic [1:0]   cmd_op,
  input logic [5:0]   cmd_addr,
  input logic [31:0]  cmd_data, cmd_rdata,
  input logic [127:0] token,
  input logic         img_valid, img_last, img_ready,
  input logic [31:0]  img_data,
  input logic         init_done, boot_done, boot_ok, cpu_en, dbg_en, key_valid, alert, esc,
  input logic [2:0]   lc_state, alert_code,
  input logic [255:0] key_out,
  // internal: the hash block register, which must be clear whenever the core is idle
  input logic [511:0] blk
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [2:0] RAW = 0, TEST = 1, DEV = 2, PROD = 3, RMA = 4, SCRAP = 5, INVALID = 6, ESC = 7;

  // ---------------- SHA-256 from its definition ----------------
  logic [31:0] k [0:63];
  logic [255:0] iv;
  function automatic logic [31:0] frac32(input real x);
    real f;
    f = x - $floor(x);
    frac32 = 32'($floor(f * 4294967296.0));
  endfunction
  initial begin
    int p, n;
    n = 0; p = 2;
    while (n < 64) begin
      bit pr;
      pr = 1;
      for (int d = 2; d * d <= p; d++) if (p % d == 0) pr = 0;
      if (pr) begin
        k[n] = frac32($pow(real'(p), 1.0 / 3.0));
        if (n < 8) iv[32 * (7 - n) +: 32] = frac32($sqrt(real'(p)));
        n++;
      end
      p++;
    end
  end
  function automatic logic [31:0] rr(input logic [31:0] x, input int n);
    rr = (x >> n) | (x << (32 - n));
  endfunction
  function automatic logic [255:0] compress(input logic [255:0] h, input logic [511:0] m);
    logic [31:0] w [0:63];
    logic [31:0] a, b, c, d, e, f, g, hh, x, y;
    for (int t = 0; t < 16; t++) w[t] = m[32 * (15 - t) +: 32];
    for (int t = 16; t < 64; t++)
      w[t] = (rr(w[t - 2], 17) ^ rr(w[t - 2], 19) ^ (w[t - 2] >> 10)) + w[t - 7]
             + (rr(w[t - 15], 7) ^ rr(w[t - 15], 18) ^ (w[t - 15] >> 3)) + w[t - 16];
    {a, b, c, d, e, f, g, hh} = h;
    for (int t = 0; t < 64; t++) begin
      x = hh + (rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)) + ((e & f) ^ (~e & g)) + k[t] + w[t];
      y = (rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hh = g; g = f; f = e; e = d + x; d = c; c = b; b = a; a = x + y;
    end
    for (int i = 0; i < 8; i++) compress[32 * (7 - i) +: 32] = h[32 * (7 - i) +: 32] + {a, b, c, d, e, f, g, hh}[32 * (7 - i) +: 32];
  endfunction
  // SHA-256 of a message of n 32-bit words held in msg
  logic [31:0] msg [0:16399];
  function automatic logic [255:0] sha_msg(input int n);
    logic [255:0] h;
    logic [511:0] b;
    int nb, i;
    h = iv;
    nb = (n * 4 + 8) / 64 + 1;                           // blocks with the padding
    for (int j = 0; j < nb; j++) begin
      for (int t = 0; t < 16; t++) begin
        i = 16 * j + t;
        b[32 * (15 - t) +: 32] = i < n ? msg[i] : i == n ? 32'h8000_0000 : 32'h0;
      end
      if (j == nb - 1) b[63:0] = 64'(n) * 64'd32;
      h = compress(h, b);
    end
    sha_msg = h;
  endfunction
  function automatic logic [255:0] hmac(input logic [255:0] key, input logic [255:0] dig, input logic [31:0] lw);
    logic [255:0] inr;
    for (int i = 0; i < 8; i++) msg[i] = key[32 * (7 - i) +: 32] ^ 32'h3636_3636;
    for (int i = 8; i < 16; i++) msg[i] = 32'h3636_3636;
    for (int i = 0; i < 8; i++) msg[16 + i] = dig[32 * (7 - i) +: 32];
    msg[24] = lw;
    inr = sha_msg(25);
    for (int i = 0; i < 8; i++) msg[i] = key[32 * (7 - i) +: 32] ^ 32'h5c5c_5c5c;
    for (int i = 8; i < 16; i++) msg[i] = 32'h5c5c_5c5c;
    for (int i = 0; i < 8; i++) msg[16 + i] = inr[32 * (7 - i) +: 32];
    hmac = sha_msg(24);
  endfunction

  // ---------------- lifecycle rules ----------------
  function automatic logic [31:0] lcw_of(input logic [2:0] s);
    lcw_of = s == TEST ? 32'h0000_00FF : s == DEV ? 32'h0000_FFFF : s == PROD ? 32'h00FF_00FF :
             s == RMA ? 32'hFFFF_FFFF : 32'h0;
  endfunction
  function automatic logic [2:0] decode(input logic [31:0] w, input logic [31:0] scr);
    decode = INVALID;
    if (scr == 32'hFFFF_FFFF) decode = SCRAP;
    else if (scr == 0)
      for (int s = 0; s <= 4; s++) if (w == lcw_of(3'(s))) decode = 3'(s);
  endfunction
  function automatic bit can_prog(input int a, input logic [2:0] s);
    if (a <= 7 || a >= 16 && a <= 31) can_prog = s == TEST;
    else if (a <= 15) can_prog = s == TEST || s == DEV;
    else if (a == 34) can_prog = s == DEV || s == PROD;
    else if (a >= 35) can_prog = s == TEST || s == DEV || s == PROD;
    else can_prog = 0;
  endfunction
  function automatic bit can_go(input logic [2:0] f, input logic [2:0] t);
    can_go = t == TEST && f == RAW || (t == DEV || t == PROD) && f == TEST || t == RMA && (f == DEV || f == PROD)
             || t == SCRAP && f != SCRAP;
  endfunction
  localparam logic [255:0] RAW_HASH = 256'he44f810d65513c0d4f08ccba93fb0f2c4144a6d78d58c871ecdd0edba4c1593e;

  // ---------------- the model ----------------
  logic [31:0] ov [0:63];               // OTP words as read
  int  nrd;                             // reads since reset
  logic [2:0] m_lc;
  logic [5:0] m_arb;
  bit  escd, booted_ok;
  // command in flight
  bit  c_act;
  logic [1:0] c_op;
  logic [5:0] c_addr;
  logic [31:0] c_data;
  logic [255:0] c_th;                   // hash of the token
  int  c_rds;                           // its OTP reads
  logic [31:0] c_rv;                    // the last word read
  logic [31:0] c_rd0;                   // cmd_rdata at the start
  bit  c_progd, c_tokok;
  int  tfail;
  bit  pend;
  // image
  int  nimg;
  logic [255:0] m_dig;
  bit  m_imgdone, m_vok;
  logic [31:0] m_ver;
  // coverage
  int  c_lc, c_tail = -1, c_cmd = -1;
  bit  v_multi, v_ovf, v_roll, v_dig, v_ok_dev, v_ok_prod, v_gap, v_lat, v_lock, v_pend, v_busy, v_lcfail,
       v_esc_idle, v_esc_cmd, v_esc_img, v_esc_ver, v_esc_key, v_raw_test, v_test_dev, v_test_prod, v_dev_rma,
       v_prod_rma, v_scrap;
  // checks
  bit  bad_prog, bad_done, bad_key, bad_boot, bad_init, bad_rd;
  wire rd_ack = otp_ack && !otp_we;
  wire pg_ack = otp_ack && otp_we;
  always @(posedge clk) begin
    c_tail <= -1; c_cmd <= -1;
    bad_prog <= 0; bad_done <= 0; bad_key <= 0; bad_boot <= 0; bad_init <= 0; bad_rd <= 0;
    if (!rst_n) begin
      nrd = 0; escd = 0; booted_ok = 0; c_act = 0; tfail = 0; pend = 0; nimg = 0; m_imgdone = 0; m_vok = 0;
    end else begin
      if (esc && !escd) begin
        if (!cmd_busy) v_esc_idle <= 1;
        else if (c_act) v_esc_cmd <= 1;
        else if (nimg > 0 && !m_imgdone) v_esc_img <= 1;
        else if (m_imgdone && !m_vok) v_esc_ver <= 1;
        else if (m_vok) v_esc_key <= 1;
      end
      if (esc) escd = 1;
      // OTP reads: the init reads, then the rest
      if (rd_ack) begin
        ov[otp_addr] = otp_rdata;
        if (nrd < 3 && otp_addr != 6'(32 + nrd)) bad_init <= 1;
        nrd++;
        if (c_act) begin c_rds++; c_rv = otp_rdata; end
        // the last digest word of a boot: may the key be derived now?
        if (!c_act && m_imgdone && otp_addr == 6'd15)
          m_vok = {ov[8], ov[9], ov[10], ov[11], ov[12], ov[13], ov[14], ov[15]} == m_dig && nimg < 16384
                  && m_ver >= 32'(m_arb);
        // a UDS word is read for the key, or to verify the program of that word
        if (otp_addr < 6'd8 && !(m_vok && !c_act) && !(c_act && c_op == 2'd1 && c_progd && otp_addr == c_addr))
          bad_rd <= 1;
      end
      if (nrd == 3 && rd_ack) begin
        m_lc = decode(ov[32], ov[33]);
        m_arb = '0;
        for (int i = 0; i < 32; i++) m_arb += 6'(ov[34][i]);
      end
      // OTP programs: only what a command allows
      if (pg_ack) begin
        if (!c_act) bad_prog <= 1;
        else if (c_op == 2'd1) begin
          if (otp_addr != c_addr || otp_wdata != c_data || !can_prog(int'(c_addr), m_lc)) bad_prog <= 1;
        end else if (c_op == 2'd2 && 3'(c_data) == SCRAP) begin
          if (otp_addr != 6'd33 || otp_wdata != 32'hFFFF_FFFF) bad_prog <= 1;
        end else if (c_op == 2'd2) begin
          logic [255:0] exp_h;
          if (m_lc == RAW) exp_h = RAW_HASH;
          else for (int i = 0; i < 8; i++) exp_h[32 * (7 - i) +: 32] = ov[(m_lc == TEST ? 16 : 24) + i];
          if (otp_addr != 6'd32 || otp_wdata != lcw_of(3'(c_data)) || c_th != exp_h) bad_prog <= 1;
        end else bad_prog <= 1;
        if (c_act) c_progd = 1;
      end
      // command results
      if (cmd_done) begin
        bit e;
        logic [2:0] al;
        al = 0;
        if (!c_act) bad_done <= 1;
        else begin
          if (tfail >= 3 || pend && c_op != 2'd0) e = 1;
          else case (c_op)
            2'd0: begin
              e = c_addr < 8;
              if (e) al = 4;
              else if (c_rds != 1 || cmd_rdata != c_rv) bad_done <= 1;
            end
            2'd1:
              if (!can_prog(int'(c_addr), m_lc)) begin e = 1; al = 4; end
              else begin e = (c_rv & c_data) != c_data; if (e) al = 5; if (!c_progd) bad_done <= 1; end
            2'd2:
              if (!can_go(m_lc, 3'(c_data))) e = 1;
              else if (3'(c_data) != SCRAP && !c_progd) begin e = 1; al = 3; tfail++; end
              else begin
                e = c_rv != (3'(c_data) == SCRAP ? 32'hFFFF_FFFF : lcw_of(3'(c_data)));
                if (e) al = 5;
                pend = 1;
              end
            default: e = 1;
          endcase
          if (cmd_err != e || (al != 0) != alert || al != 0 && alert_code != al)
            bad_done <= 1;
          if (c_op != 2'd0 && cmd_rdata != c_rd0) bad_done <= 1;      // only a read returns data
          // coverage of the outcome
          c_cmd <= c_op == 2'd0 ? (cmd_err ? 1 : 0)
                 : c_op == 2'd1 ? (al == 5 ? 4 : cmd_err ? 3 : 2)
                 : c_op == 2'd2 ? (al == 3 ? 6 : al == 5 ? 8 : cmd_err ? 7 : 5) : 9;
          if (tfail >= 3) v_lock <= 1;
          if (pend && c_op != 2'd0) v_pend <= 1;
          if (c_op == 2'd2 && !cmd_err)
            case ({m_lc, 3'(c_data)})
              {RAW, TEST}: v_raw_test <= 1;
              {TEST, DEV}: v_test_dev <= 1;
              {TEST, PROD}: v_test_prod <= 1;
              {DEV, RMA}: v_dev_rma <= 1;
              {PROD, RMA}: v_prod_rma <= 1;
              default: if (3'(c_data) == SCRAP) v_scrap <= 1;
            endcase
        end
        c_act = 0;
      end
      if (cmd_start && !cmd_busy) begin
        c_act = 1; c_op = cmd_op; c_addr = cmd_addr; c_data = cmd_data; c_rds = 0; c_progd = 0; c_rd0 = cmd_rdata;
        for (int i = 0; i < 4; i++) msg[i] = token[32 * (3 - i) +: 32];
        c_th = sha_msg(4);
      end
      // image
      if (img_valid && img_ready) begin
        if (nimg < 16400) msg[nimg] = img_data;
        if (nimg == 0) m_ver = img_data;
        nimg++;
        if (nimg == 17) v_multi <= 1;
        if (img_last) begin
          m_dig = sha_msg(nimg < 16400 ? nimg : 16400); m_imgdone = 1;
          c_tail <= (nimg - 1) % 16;
          if (nimg >= 16384) v_ovf <= 1;
        end
      end
      // boot result and key
      if (boot_done && !booted_ok && !escd) begin
        bit exp_ok;
        exp_ok = m_lc == TEST || m_lc == RMA || (m_lc == DEV || m_lc == PROD) && m_vok;
        if (boot_ok != exp_ok || cpu_en != exp_ok) bad_boot <= 1;
        if (key_valid != ((m_lc == DEV || m_lc == PROD) && exp_ok)) bad_boot <= 1;
        if (key_valid) begin
          logic [255:0] uds;
          logic [31:0] lw;
          for (int i = 0; i < 8; i++) uds[32 * (7 - i) +: 32] = ov[i];
          lw = ov[32];
          if (key_out != hmac(uds, m_dig, lw)) bad_key <= 1;
        end
        booted_ok = 1;
      end
    end
  end
  bit escd_q;
  always @(posedge clk) escd_q <= rst_n && (escd_q || esc);

  `SVA_INV(a_init_order, !bad_init)
  `SVA_IMP(a_lifecycle, init_done && !escd_q, lc_state == m_lc)
  `SVA_IMP(a_debug, init_done, dbg_en == (!escd_q && (m_lc == TEST || m_lc == DEV || m_lc == RMA)))
  `SVA_INV(a_otp_program, !bad_prog)
  `SVA_INV(a_uds_read_only_for_key, !bad_rd)
  `SVA_INV(a_command_result, !bad_done)
  `SVA_INV(a_boot_decision, !bad_boot)
  `SVA_INV(a_key, !bad_key)
  `SVA_IMP(a_image_only_when_verifying, img_ready, (m_lc == DEV || m_lc == PROD) && !boot_done && !escd_q)
  `SVA_IMP(a_cpu_only_after_boot, cpu_en, boot_done && boot_ok)
  `SVA_IMP(a_key_only_after_verified_boot, key_valid, m_vok && (m_lc == DEV || m_lc == PROD))
  `SVA_IMP(a_escalation, escd_q, lc_state == ESC && !cpu_en && !dbg_en && !key_valid && key_out == '0 && !otp_req
                                  && cmd_busy && !img_ready)
  `SVA_IMP(a_escalation_alert, esc && !escd_q, ##1 alert && alert_code == 3'd6)
  `SVA_IMP(a_idle_block_clear, init_done && !cmd_busy, blk == '0)
  `SVA_IMP(a_otp_req_hold, otp_req && !otp_ack && !esc, ##1 otp_req && $stable(otp_addr) && $stable(otp_we))
  `SVA_RST(a_reset, 1'b1, !otp_req && !cmd_done && !init_done && !boot_done && !cpu_en && !dbg_en && !key_valid
                          && key_out == '0 && !alert && !img_ready)

  // ---------------- functional coverage ----------------
  // (the outcome flags are set by the model above, where the command and
  // image state are known)
  bit init_q, boot_q, req_q, ack_q;
  always @(posedge clk) begin
    init_q <= init_done; boot_q <= boot_done; req_q <= otp_req; ack_q <= otp_ack;
    c_lc <= init_done && !init_q ? int'(lc_state) : -1;
    if (rst_n) begin
      if (boot_done && !boot_q && !boot_ok && m_imgdone) begin
        if (m_ver < 32'(m_arb)) v_roll <= 1;
        else if (nimg < 16384) v_dig <= 1;
      end
      if (key_valid && m_lc == DEV) v_ok_dev <= 1;
      if (key_valid && m_lc == PROD) v_ok_prod <= 1;
      if (img_ready && !img_valid && nimg > 0) v_gap <= 1;
      if (otp_req && !otp_ack && req_q && !ack_q) v_lat <= 1;
      if (cmd_start && cmd_busy && init_done && !escd_q) v_busy <= 1;
      if (init_done && !init_q && alert && alert_code == 3'd1) v_lcfail <= 1;
    end
  end
  covergroup cg_rot @(negedge clk);
    option.per_instance = 1;
    cp_lc: coverpoint c_lc iff (c_lc >= 0)
      { bins raw = {0}; bins test = {1}; bins dev = {2}; bins prod = {3}; bins rma = {4}; bins scrap = {5};
        bins invalid = {6}; }
    // where the image ends in its last block: every padding case
    cp_tail: coverpoint c_tail iff (c_tail >= 0) { bins tail[] = {[0:15]}; }
    cp_cmd: coverpoint c_cmd iff (c_cmd >= 0)
      { bins read = {0}; bins read_uds = {1}; bins prog = {2}; bins prog_refused = {3}; bins prog_verify_fail = {4};
        bins transition = {5}; bins wrong_token = {6}; bins refused = {7}; bins trans_verify_fail = {8};
        bins reserved = {9}; }
  endgroup
  cg_rot u_cg_rot = new;

  `FC(multi_block_image, v_multi)
  `FC(image_too_long, v_ovf)
  `FC(rollback_refused, v_roll)
  `FC(digest_mismatch, v_dig)
  `FC(key_in_dev, v_ok_dev)
  `FC(key_in_prod, v_ok_prod)
  `FC(image_gap, v_gap)
  `FC(otp_wait, v_lat)
  `FC(command_lock, v_lock)
  `FC(reset_required, v_pend)
  `FC(start_while_busy, v_busy)
  `FC(invalid_lifecycle, v_lcfail)
  `FC(escalation_idle, v_esc_idle)
  `FC(escalation_command, v_esc_cmd)
  `FC(escalation_image, v_esc_img)
  `FC(escalation_verify, v_esc_ver)
  `FC(escalation_key, v_esc_key)
  `FC(transition_raw_test, v_raw_test)
  `FC(transition_test_dev, v_test_dev)
  `FC(transition_test_prod, v_test_prod)
  `FC(transition_dev_rma, v_dev_rma)
  `FC(transition_prod_rma, v_prod_rma)
  `FC(transition_scrap, v_scrap)
  `FC_RST(reset_while_busy, rst_n && init_done && cmd_busy && !escd_q ##1 !rst_n)
endmodule

bind Root_of_Trust_top Root_of_Trust_sva u_sva (.*);
