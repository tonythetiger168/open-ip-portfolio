// IP part of HDCP_2_3_Content_Protection_apb_tb: the TB plays the HDCP
// receiver through the registers (reads TXM, answers on RXM), with its own
// AES-128 (anchored on the FIPS-197 vector), and decrypts the pixel stream
// on the pass-through pins.
/*verilator coverage_off*/
  // derive ks / E_km / H' / CTR keystream on the receiver side.
  // ====================================================================
  // AES S-box as one packed constant (entry x at bits [8x+7:8x]); a
  // 256-arm case inside a function is rejected by Verilator 5.052 (IMPURE)
  localparam logic [2047:0] SBOX_V = {
    256'h16bb54b00f2d99416842e6bf0d89a18cdf2855cee9871e9b948ed9691198f8e1,
    256'h9e1dc186b95735610ef6034866b53e708a8bbd4b1f74dde8c6b4a61c2e2578ba,
    256'h08ae7a65eaf4566ca94ed58d6d37c8e779e4959162acd3c25c2406490a3a32e0,
    256'hdb0b5ede14b8ee4688902a22dc4f816073195d643d7ea7c41744975fec130ccd,
    256'hd2f3ff1021dab6bcf5389d928f40a351a89f3c507f02f94585334d43fbaaefd0,
    256'hcf584c4a39becb6a5bb1fc20ed00d153842fe329b3d63b52a05a6e1b1a2c8309,
    256'h75b227ebe28012079a059618c323c7041531d871f1e5a534ccf73f362693fdb7,
    256'hc072a49cafa2d4adf04759fa7dc982ca76abd7fe2b670130c56f6bf27b777c63
  };
  function automatic logic [7:0] sbox(input logic [7:0] x);
    return SBOX_V[8*x +: 8];
  endfunction

  function automatic logic [7:0] xtime(input logic [7:0] a);
    xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
  endfunction
  function automatic logic [7:0] mul2(input logic [7:0] a); mul2 = xtime(a); endfunction
  function automatic logic [7:0] mul3(input logic [7:0] a); mul3 = xtime(a) ^ a; endfunction

  function automatic logic [127:0] sub_bytes(input logic [127:0] s);
    for (int i = 0; i < 16; i++) sub_bytes[127-8*i -: 8] = sbox(s[127-8*i -: 8]);
  endfunction

  function automatic logic [127:0] shift_rows(input logic [127:0] s);
    logic [7:0] b [0:15];
    begin
      for (int i = 0; i < 16; i++) b[i] = s[127-8*i -: 8];
      shift_rows = {b[0], b[5], b[10], b[15], b[4], b[9], b[14], b[3],
                    b[8], b[13], b[2], b[7], b[12], b[1], b[6], b[11]};
    end
  endfunction

  function automatic logic [31:0] mix_col(input logic [31:0] c);
    logic [7:0] b0, b1, b2, b3;
    begin
      b0 = c[31:24]; b1 = c[23:16]; b2 = c[15:8]; b3 = c[7:0];
      mix_col = {mul2(b0) ^ mul3(b1) ^ b2 ^ b3,
                 b0 ^ mul2(b1) ^ mul3(b2) ^ b3,
                 b0 ^ b1 ^ mul2(b2) ^ mul3(b3),
                 mul3(b0) ^ b1 ^ b2 ^ mul2(b3)};
    end
  endfunction
  function automatic logic [127:0] mix_columns(input logic [127:0] s);
    mix_columns = {mix_col(s[127:96]), mix_col(s[95:64]),
                   mix_col(s[63:32]), mix_col(s[31:0])};
  endfunction

  function automatic logic [7:0] rcon(input logic [3:0] r);
    case (r)
      4'd1: rcon = 8'h01; 4'd2: rcon = 8'h02; 4'd3: rcon = 8'h04;
      4'd4: rcon = 8'h08; 4'd5: rcon = 8'h10; 4'd6: rcon = 8'h20;
      4'd7: rcon = 8'h40; 4'd8: rcon = 8'h80; 4'd9: rcon = 8'h1b;
      default: rcon = 8'h36;
    endcase
  endfunction

  function automatic logic [127:0] key_next(input logic [127:0] k,
                                            input logic [3:0] r);
    logic [31:0] w0, w1, w2, w3, t;
    begin
      w0 = k[127:96]; w1 = k[95:64]; w2 = k[63:32]; w3 = k[31:0];
      t  = {sbox(w3[23:16]), sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])}
           ^ {rcon(r), 24'h0};
      w0 = w0 ^ t;
      w1 = w1 ^ w0;
      w2 = w2 ^ w1;
      w3 = w3 ^ w2;
      key_next = {w0, w1, w2, w3};
    end
  endfunction

  function automatic logic [127:0] aes128_enc(input logic [127:0] key,
                                              input logic [127:0] pt);
    logic [127:0] rk, s;
    begin
      rk = key;
      s  = pt ^ rk;
      for (int r = 1; r <= 9; r++) begin
        rk = key_next(rk, r[3:0]);
        s  = mix_columns(shift_rows(sub_bytes(s))) ^ rk;
      end
      rk = key_next(rk, 4'd10);
      aes128_enc = shift_rows(sub_bytes(s)) ^ rk;
    end
  endfunction
/*verilator coverage_on*/

  localparam logic [3:0] MT_AKE_INIT = 4'd2, MT_AKE_CERT = 4'd3, MT_AKE_EKM = 4'd4,
                         MT_PAIR_ACK = 4'd7, MT_LC_INIT = 4'd9, MT_LC_RESP = 4'd10,
                         MT_SKE = 4'd11, MT_RPT_ACK = 4'd12;
  localparam logic [3:0] S_IDLE = 0, S_AKE_INIT = 1, S_AKE_CERT = 2, S_PAIR_TX = 3, S_PAIR_RX = 4,
                         S_LC_TX = 5, S_LC_WAIT = 6, S_SKE_TX = 7, S_RPT_WAIT = 8, S_AUTH = 9;
  localparam int MSG_TO = 255;

  initial begin pix_valid = 0; pix_data = 0; enc_ready = 1; end

  logic [127:0] km, ks;
  logic [63:0]  rtx;
  logic [15:0]  ctr;

  task automatic set_km(input logic [127:0] k);
    for (int i = 0; i < 16; i++) begin wr(A_KMIDX, i); wr(A_KMDAT, k[8*i +: 8]); end
    km = k;
  endtask

  // one message from the core: wait for it, read the body, the type word frees it
  task automatic txm_get(input logic [3:0] t, output logic [127:0] d);
    poll(A_FLAGS, 1 << FLAG_TXM_AVAIL, 1 << FLAG_TXM_AVAIL, 100);
    rd(A_TXM0); d[31:0] = rdv;
    rd(A_TXM1); d[63:32] = rdv;
    rd(A_TXM2); d[95:64] = rdv;
    rd(A_TXM3); d[127:96] = rdv;
    rd_exp(A_TXM4, {28'h0, t});
    rd_exp(A_FLAGS, 0);
  endtask

  task automatic rxm_put(input logic [3:0] t, input logic [127:0] d);
    wr(A_RXM0, d[31:0]); wr(A_RXM1, d[63:32]); wr(A_RXM2, d[95:64]); wr(A_RXM3, d[127:96]);
    wr(A_RXM4, {$urandom, t});                    // only [3:0] reach the core
  endtask

  task automatic err_clear(input logic [7:0] e);
    rd_exp(A_ERR, e);
    rd(A_HSTATUS); if (!rdv[3]) fail("HSTATUS fail flag");
    wr(A_CTRL, 4);
    rd_exp(A_ERR, 0);
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd_exp(A_IRQ_STATUS, 0);
  endtask

  // fail: 0 none, 1 pairing ack, 2 locality value, 3 locality timeout,
  //       4 bad type in AKE_CERT, 5 AKE_CERT timeout
  task automatic auth(input logic rpt, input int fl);
    logic [127:0] d, hpad;
    logic [31:0]  hrx;
    logic [63:0]  l;
    wr(A_CTRL, 1);
    txm_get(MT_AKE_INIT, d);
    if (d[127:64] != 0) fail("AKE_Init upper half");
    rtx = d[63:0];
    ks = aes128_enc(km, {rtx, rtx});
    hrx = $urandom; hpad = {hrx, hrx, hrx, hrx};
    rd_exp(A_STATE, S_AKE_CERT);
    if (fl == 4) begin
      rxm_put(MT_PAIR_ACK, {$urandom, $urandom, $urandom, $urandom}); cycles(2);
      rd_exp(A_STATE, S_IDLE); err_clear(8'h08);
    end else if (fl == 5) begin
      cycles(MSG_TO + 2); rd_exp(A_STATE, S_IDLE); err_clear(8'h10);
    end else begin
      rxm_put(MT_AKE_CERT, {$urandom, hrx, $urandom, 31'($urandom), rpt});
      txm_get(MT_AKE_EKM, d);
      if (d != aes128_enc(hpad, km)) fail("E_km");
      d = aes128_enc(km, hpad);
      rxm_put(MT_PAIR_ACK, {$urandom, $urandom, $urandom, d[31:0] ^ ((fl == 1) ? 32'h1 : 32'h0)});
      if (fl == 1) begin
        cycles(2); rd_exp(A_STATE, S_IDLE); err_clear(8'h02);
      end else begin
        // locality: 20 clocks from LC_Init to the answer
        no_idle = 1;
        poll(A_FLAGS, 1 << FLAG_TXM_AVAIL, 1 << FLAG_TXM_AVAIL, 10);
        rd(A_TXM0); l[31:0] = rdv;
        rd(A_TXM1); l[63:32] = rdv;
        rd_exp(A_TXM4, MT_LC_INIT);
        if (fl == 3) begin
          no_idle = 0; cycles(22); rd_exp(A_STATE, S_IDLE); err_clear(8'h01);
        end else begin
          l = l ^ ks[63:0] ^ ((fl == 2) ? 64'h8000_0000_0000_0000 : 64'h0);
          wr(A_RXM0, l[31:0]); wr(A_RXM1, l[63:32]); wr(A_RXM4, MT_LC_RESP);
          no_idle = 0;
          if (fl == 2) begin
            cycles(2); rd_exp(A_STATE, S_IDLE); err_clear(8'h04);
          end else begin
            txm_get(MT_SKE, d);
            if (d != (ks ^ km)) fail("SKE Eks");
            if (rpt) begin
              rd_exp(A_STATE, S_RPT_WAIT);
              rxm_put(MT_RPT_ACK, {$urandom, $urandom, $urandom, $urandom});
            end
            rd_exp(A_STATE, S_AUTH);
            rd_exp(A_HSTATUS, {rpt, 4'b0111});
            for (int i = 0; i < 16; i++) begin wr(A_KMIDX, i); rd_exp(A_KSDAT, ks[8*i +: 8]); end
            ctr = 0;
          end
        end
      end
    end
  endtask

  // n pixel words on the pins with gaps and enc_ready backpressure; each one decrypted
  logic [31:0] px_q [$];
  logic [15:0] pc_q [$];
  task automatic stream(input int n);
    logic [127:0] k;
    int sent, got;
    sent = 0; got = 0;
    fork
      begin
        while (sent < n) begin
          @(negedge PCLK);
          pix_valid = ($urandom_range(0, 3) != 0);
          pix_data = $urandom;
          #1;
          if (pix_valid && pix_ready) begin px_q.push_back(pix_data); pc_q.push_back(ctr); ctr++; sent++; end
        end
        @(negedge PCLK); pix_valid = 0;
      end
      begin
        while (got < n) begin
          @(negedge PCLK);
          enc_ready = ($urandom_range(0, 3) != 0);
          #1;
          if (enc_valid && enc_ready) begin
            k = aes128_enc(ks, {rtx, 48'h0, pc_q[0]});
            if (enc_data !== (px_q[0] ^ k[127:96])) fail("pixel decrypts");
            void'(px_q.pop_front()); void'(pc_q.pop_front());
            got++;
          end
        end
        @(negedge PCLK); enc_ready = 1;
      end
    join
  endtask

  task automatic ip_func;
    logic [127:0] d;
    d = aes128_enc(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff);
    if (d != 128'h69c4e0d86a7b0430d8cdb78070b4c55a) fail("TB AES FIPS-197 vector");
    // ---- the core register window ----
    rd_exp(A_VER, 8'h23);
    rd_exp(A_CTRL, 0);
    rd_exp(A_HSTATUS, 0);
    rd_exp(A_STATE, S_IDLE);
    set_km({128{1'b1}});
    for (int i = 0; i < 16; i++) begin wr(A_KMIDX, i); rd_exp(A_KMDAT, 8'hFF); end
    rd_exp(A_KMIDX, 8'h0F);
    set_km(128'h0);
    rd_exp(A_KMDAT, 8'h00);
    wr(A_KMIDX, 32'hFFFF_FFF5); rd_exp(A_KMIDX, 8'h05);  // only [3:0] are kept
    wr(A_VER, 32'hFFFF_FFFF); wr(A_ERR, 32'hFFFF_FFFF); wr(A_HSTATUS, 32'hFFFF_FFFF);
    wr(A_STATE, 32'hFFFF_FFFF); wr(A_KSDAT, 32'hFFFF_FFFF);
    rd_exp(A_VER, 8'h23); rd_exp(A_ERR, 0); rd_exp(A_HSTATUS, 0); rd_exp(A_STATE, S_IDLE);
    // a partial strobe on a core register is dropped with PSLVERR
    apb(1, A_KMDAT, 32'hA5, 4'h1);
    if (!rerr) fail("no PSLVERR on a partial core register write");
    rd_exp(A_KMDAT, 8'h00);
    wr(A_CTRL, 0);                                       // no action
    rd_exp(A_STATE, S_IDLE);
    set_km(128'h2b7e1516_28aed2a6_abf71588_09cf4f3c);
    // the message registers: TXM empty reads 0 and ignores writes, RXM reads 0
    for (int i = 0; i < 5; i++) begin wr(A_TXM0 + 4 * i, 32'hFFFF_FFFF); rd_exp(A_TXM0 + 4 * i, 0); end
    for (int i = 0; i < 5; i++) rd_exp(A_RXM0 + 4 * i, 0);
    wr(A_IRQ_ENABLE, IRQ_ALL);

    // ---- authentication, pixels ----
    auth(0, 0);
    rd(A_IRQ_STATUS);
    if (rdv !== ((1 << IRQ_TXM_AVAIL) | (1 << IRQ_RXM_DONE))) fail("IRQ_STATUS after auth");
    if (!irq) fail("irq pin");
    wr(A_IRQ_STATUS, IRQ_ALL);
    stream(200);
    auth(1, 0);                                          // restart from AUTH, a repeater
    stream(40);

    // ---- an answer written before the core waits for it: held, then taken ----
    // and a second write while full: dropped (RXM_OVF)
    wr(A_IRQ_ENABLE, 1 << IRQ_RXM_OVF);
    wr(A_IRQ_STATUS, IRQ_ALL);
    rxm_put(MT_AKE_CERT, {$urandom, 32'h1234_5678, $urandom, 32'h0});
    rd_exp(A_FLAGS, 1 << FLAG_RXM_FULL);
    rd_exp(A_RXM2, 32'h1234_5678);                        // reads back
    wr(A_RXM4, MT_PAIR_ACK);                             // dropped
    rd(A_IRQ_STATUS);
    if (rdv !== (1 << IRQ_RXM_OVF)) fail("RXM_OVF");
    if (!irq) fail("RXM_OVF drives the pin");
    wr(A_IRQ_STATUS, IRQ_ALL);
    if (irq) fail("irq pin after clear");
    wr(A_IRQ_ENABLE, 0);
    wr(A_RXM0, 0);                                       // dropped again, masked
    rd_exp(A_IRQ_STATUS, 1 << IRQ_RXM_OVF);
    if (irq) fail("masked RXM_OVF drives the pin");
    rd_exp(A_RXM0, 0);
    wr(A_IRQ_STATUS, IRQ_ALL);
    wr(A_CTRL, 1);
    cycles(4);
    // AKE_Init is still unread: the core took the certificate and waits in PAIR_TX
    rd_exp(A_STATE, S_PAIR_TX);
    rd_exp(A_FLAGS, 1 << FLAG_TXM_AVAIL);
    rd(A_TXM0); rtx[31:0] = rdv;
    rd(A_TXM1); rtx[63:32] = rdv;
    rd_exp(A_TXM4, MT_AKE_INIT);                         // frees it: E_km follows at once
    txm_get(MT_AKE_EKM, d);
    if (d != aes128_enc({4{32'h1234_5678}}, km)) fail("E_km of the held certificate");
    rd(A_IRQ_STATUS);
    if (rdv !== ((1 << IRQ_TXM_AVAIL) | (1 << IRQ_RXM_DONE))) fail("IRQ_STATUS held certificate");
    wr(A_IRQ_STATUS, IRQ_ALL);
    cycles(MSG_TO + 2);                                  // no pairing ack: timeout
    rd_exp(A_STATE, S_IDLE);
    err_clear(8'h10);
    wr(A_IRQ_ENABLE, IRQ_ALL);

    // ---- failures, irq ERROR ----
    set_km({$urandom, $urandom, $urandom, $urandom});
    auth(0, 1);
    auth(0, 2);
    auth(0, 3);
    auth(1, 4);
    wr(A_IRQ_ENABLE, 0);
    auth(0, 5);                                          // masked: no pin
    wr(A_IRQ_ENABLE, IRQ_ALL);
    wr(A_IRQ_STATUS, IRQ_ALL);
    // the level error re-sets ERROR until CTRL clears the flags
    wr(A_CTRL, 1);
    txm_get(MT_AKE_INIT, d);
    cycles(MSG_TO + 2);
    wr(A_IRQ_STATUS, 1 << IRQ_ERROR);
    rd(A_IRQ_STATUS); if (!rdv[IRQ_ERROR]) fail("ERROR is set again while the flag is held");
    if (!irq) fail("ERROR drives the pin");
    err_clear(8'h10);
    wr(A_IRQ_STATUS, IRQ_ALL);
    repeat (3) auth($urandom_range(0, 1), 0);
    stream(30);
    // reset with an enabled irq pending (a session started, AKE_Init waiting)
    wr(A_IRQ_STATUS, IRQ_ALL);
    wr(A_CTRL, 1);
    poll(A_IRQ_STATUS, 1 << IRQ_TXM_AVAIL, 1 << IRQ_TXM_AVAIL, 10);
    if (!irq) fail("TXM_AVAIL drives the pin");
  endtask
