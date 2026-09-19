// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for HDCP_2_3_Content_Protection_top -- SystemVerilog
// TB plays the HDCP receiver (sink): answers AKE/pairing/locality/SKE
// messages, independently computes the session key with its own AES-128
// (FIPS-197) implementation, decrypts the AES-128-CTR pixel keystream and
// injects locality-timeout and pairing-failure errors.
//
// The TB AES function is anchored to reality by two known-answer checks
// before any DUT traffic:
//   * FIPS-197 / NIST vector: key=000102..0f, pt=00112233..ff
//   * openssl-precomputed:    key=2b7e1516..4f3c (the TB km), pt=0^128
// ============================================================================
`timescale 1ns/1ps
module HDCP_2_3_Content_Protection_tb;

  logic         clk = 1'b0, rst_n = 1'b0;
  logic         reg_we = 1'b0;
  logic [2:0]   reg_addr = 3'h0;
  logic [7:0]   reg_wdata = 8'h0, reg_rdata;
  logic         txm_valid, txm_ready = 1'b0;
  logic [3:0]   txm_type;
  logic [127:0] txm_data;
  logic         rxm_valid = 1'b0, rxm_ready;
  logic [3:0]   rxm_type = 4'h0;
  logic [127:0] rxm_data = 128'h0;
  logic         pix_valid = 1'b0, pix_ready;
  logic [31:0]  pix_data = 32'h0;
  logic         enc_valid, enc_ready;
  logic [31:0]  enc_data;
  logic         irq;
  int           errors = 0;

  HDCP_2_3_Content_Protection_top dut (
    .clk(clk), .rst_n(rst_n),
    .reg_we(reg_we), .reg_addr(reg_addr),
    .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .txm_valid(txm_valid), .txm_ready(txm_ready),
    .txm_type(txm_type), .txm_data(txm_data),
    .rxm_valid(rxm_valid), .rxm_ready(rxm_ready),
    .rxm_type(rxm_type), .rxm_data(rxm_data),
    .pix_valid(pix_valid), .pix_ready(pix_ready), .pix_data(pix_data),
    .enc_valid(enc_valid), .enc_ready(enc_ready), .enc_data(enc_data),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // message types (mirror RTL)
  localparam logic [3:0] MT_AKE_INIT = 4'd1, MT_AKE_CERT = 4'd2,
                         MT_AKE_EKM  = 4'd3, MT_PAIR_ACK = 4'd4,
                         MT_LC_INIT  = 4'd5, MT_LC_RESP = 4'd6,
                         MT_SKE      = 4'd7, MT_RPT_ACK = 4'd8;

  // receiver-side identity / knobs
  logic [127:0] rx_km;              // receiver shares the provisioned km
  logic [31:0]  rx_hrx;             // receiver pubkey-hash placeholder
  logic         rx_repeater;        // REPEATER bit advertised in rxcaps

  // captured per-session values
  logic [63:0]  cap_rtx, cap_l;
  logic [127:0] ks_exp;             // TB-side independent session key

  // ====================================================================
  // TB-side AES-128 (FIPS-197) encrypt -- independent reference used to
  // derive ks / E_km / H' / CTR keystream on the receiver side.
  // ====================================================================
  function automatic logic [7:0] sbox(input logic [7:0] x);
    case (x)
      8'h00: sbox=8'h63; 8'h01: sbox=8'h7c; 8'h02: sbox=8'h77; 8'h03: sbox=8'h7b;
      8'h04: sbox=8'hf2; 8'h05: sbox=8'h6b; 8'h06: sbox=8'h6f; 8'h07: sbox=8'hc5;
      8'h08: sbox=8'h30; 8'h09: sbox=8'h01; 8'h0a: sbox=8'h67; 8'h0b: sbox=8'h2b;
      8'h0c: sbox=8'hfe; 8'h0d: sbox=8'hd7; 8'h0e: sbox=8'hab; 8'h0f: sbox=8'h76;
      8'h10: sbox=8'hca; 8'h11: sbox=8'h82; 8'h12: sbox=8'hc9; 8'h13: sbox=8'h7d;
      8'h14: sbox=8'hfa; 8'h15: sbox=8'h59; 8'h16: sbox=8'h47; 8'h17: sbox=8'hf0;
      8'h18: sbox=8'had; 8'h19: sbox=8'hd4; 8'h1a: sbox=8'ha2; 8'h1b: sbox=8'haf;
      8'h1c: sbox=8'h9c; 8'h1d: sbox=8'ha4; 8'h1e: sbox=8'h72; 8'h1f: sbox=8'hc0;
      8'h20: sbox=8'hb7; 8'h21: sbox=8'hfd; 8'h22: sbox=8'h93; 8'h23: sbox=8'h26;
      8'h24: sbox=8'h36; 8'h25: sbox=8'h3f; 8'h26: sbox=8'hf7; 8'h27: sbox=8'hcc;
      8'h28: sbox=8'h34; 8'h29: sbox=8'ha5; 8'h2a: sbox=8'he5; 8'h2b: sbox=8'hf1;
      8'h2c: sbox=8'h71; 8'h2d: sbox=8'hd8; 8'h2e: sbox=8'h31; 8'h2f: sbox=8'h15;
      8'h30: sbox=8'h04; 8'h31: sbox=8'hc7; 8'h32: sbox=8'h23; 8'h33: sbox=8'hc3;
      8'h34: sbox=8'h18; 8'h35: sbox=8'h96; 8'h36: sbox=8'h05; 8'h37: sbox=8'h9a;
      8'h38: sbox=8'h07; 8'h39: sbox=8'h12; 8'h3a: sbox=8'h80; 8'h3b: sbox=8'he2;
      8'h3c: sbox=8'heb; 8'h3d: sbox=8'h27; 8'h3e: sbox=8'hb2; 8'h3f: sbox=8'h75;
      8'h40: sbox=8'h09; 8'h41: sbox=8'h83; 8'h42: sbox=8'h2c; 8'h43: sbox=8'h1a;
      8'h44: sbox=8'h1b; 8'h45: sbox=8'h6e; 8'h46: sbox=8'h5a; 8'h47: sbox=8'ha0;
      8'h48: sbox=8'h52; 8'h49: sbox=8'h3b; 8'h4a: sbox=8'hd6; 8'h4b: sbox=8'hb3;
      8'h4c: sbox=8'h29; 8'h4d: sbox=8'he3; 8'h4e: sbox=8'h2f; 8'h4f: sbox=8'h84;
      8'h50: sbox=8'h53; 8'h51: sbox=8'hd1; 8'h52: sbox=8'h00; 8'h53: sbox=8'hed;
      8'h54: sbox=8'h20; 8'h55: sbox=8'hfc; 8'h56: sbox=8'hb1; 8'h57: sbox=8'h5b;
      8'h58: sbox=8'h6a; 8'h59: sbox=8'hcb; 8'h5a: sbox=8'hbe; 8'h5b: sbox=8'h39;
      8'h5c: sbox=8'h4a; 8'h5d: sbox=8'h4c; 8'h5e: sbox=8'h58; 8'h5f: sbox=8'hcf;
      8'h60: sbox=8'hd0; 8'h61: sbox=8'hef; 8'h62: sbox=8'haa; 8'h63: sbox=8'hfb;
      8'h64: sbox=8'h43; 8'h65: sbox=8'h4d; 8'h66: sbox=8'h33; 8'h67: sbox=8'h85;
      8'h68: sbox=8'h45; 8'h69: sbox=8'hf9; 8'h6a: sbox=8'h02; 8'h6b: sbox=8'h7f;
      8'h6c: sbox=8'h50; 8'h6d: sbox=8'h3c; 8'h6e: sbox=8'h9f; 8'h6f: sbox=8'ha8;
      8'h70: sbox=8'h51; 8'h71: sbox=8'ha3; 8'h72: sbox=8'h40; 8'h73: sbox=8'h8f;
      8'h74: sbox=8'h92; 8'h75: sbox=8'h9d; 8'h76: sbox=8'h38; 8'h77: sbox=8'hf5;
      8'h78: sbox=8'hbc; 8'h79: sbox=8'hb6; 8'h7a: sbox=8'hda; 8'h7b: sbox=8'h21;
      8'h7c: sbox=8'h10; 8'h7d: sbox=8'hff; 8'h7e: sbox=8'hf3; 8'h7f: sbox=8'hd2;
      8'h80: sbox=8'hcd; 8'h81: sbox=8'h0c; 8'h82: sbox=8'h13; 8'h83: sbox=8'hec;
      8'h84: sbox=8'h5f; 8'h85: sbox=8'h97; 8'h86: sbox=8'h44; 8'h87: sbox=8'h17;
      8'h88: sbox=8'hc4; 8'h89: sbox=8'ha7; 8'h8a: sbox=8'h7e; 8'h8b: sbox=8'h3d;
      8'h8c: sbox=8'h64; 8'h8d: sbox=8'h5d; 8'h8e: sbox=8'h19; 8'h8f: sbox=8'h73;
      8'h90: sbox=8'h60; 8'h91: sbox=8'h81; 8'h92: sbox=8'h4f; 8'h93: sbox=8'hdc;
      8'h94: sbox=8'h22; 8'h95: sbox=8'h2a; 8'h96: sbox=8'h90; 8'h97: sbox=8'h88;
      8'h98: sbox=8'h46; 8'h99: sbox=8'hee; 8'h9a: sbox=8'hb8; 8'h9b: sbox=8'h14;
      8'h9c: sbox=8'hde; 8'h9d: sbox=8'h5e; 8'h9e: sbox=8'h0b; 8'h9f: sbox=8'hdb;
      8'ha0: sbox=8'he0; 8'ha1: sbox=8'h32; 8'ha2: sbox=8'h3a; 8'ha3: sbox=8'h0a;
      8'ha4: sbox=8'h49; 8'ha5: sbox=8'h06; 8'ha6: sbox=8'h24; 8'ha7: sbox=8'h5c;
      8'ha8: sbox=8'hc2; 8'ha9: sbox=8'hd3; 8'haa: sbox=8'hac; 8'hab: sbox=8'h62;
      8'hac: sbox=8'h91; 8'had: sbox=8'h95; 8'hae: sbox=8'he4; 8'haf: sbox=8'h79;
      8'hb0: sbox=8'he7; 8'hb1: sbox=8'hc8; 8'hb2: sbox=8'h37; 8'hb3: sbox=8'h6d;
      8'hb4: sbox=8'h8d; 8'hb5: sbox=8'hd5; 8'hb6: sbox=8'h4e; 8'hb7: sbox=8'ha9;
      8'hb8: sbox=8'h6c; 8'hb9: sbox=8'h56; 8'hba: sbox=8'hf4; 8'hbb: sbox=8'hea;
      8'hbc: sbox=8'h65; 8'hbd: sbox=8'h7a; 8'hbe: sbox=8'hae; 8'hbf: sbox=8'h08;
      8'hc0: sbox=8'hba; 8'hc1: sbox=8'h78; 8'hc2: sbox=8'h25; 8'hc3: sbox=8'h2e;
      8'hc4: sbox=8'h1c; 8'hc5: sbox=8'ha6; 8'hc6: sbox=8'hb4; 8'hc7: sbox=8'hc6;
      8'hc8: sbox=8'he8; 8'hc9: sbox=8'hdd; 8'hca: sbox=8'h74; 8'hcb: sbox=8'h1f;
      8'hcc: sbox=8'h4b; 8'hcd: sbox=8'hbd; 8'hce: sbox=8'h8b; 8'hcf: sbox=8'h8a;
      8'hd0: sbox=8'h70; 8'hd1: sbox=8'h3e; 8'hd2: sbox=8'hb5; 8'hd3: sbox=8'h66;
      8'hd4: sbox=8'h48; 8'hd5: sbox=8'h03; 8'hd6: sbox=8'hf6; 8'hd7: sbox=8'h0e;
      8'hd8: sbox=8'h61; 8'hd9: sbox=8'h35; 8'hda: sbox=8'h57; 8'hdb: sbox=8'hb9;
      8'hdc: sbox=8'h86; 8'hdd: sbox=8'hc1; 8'hde: sbox=8'h1d; 8'hdf: sbox=8'h9e;
      8'he0: sbox=8'he1; 8'he1: sbox=8'hf8; 8'he2: sbox=8'h98; 8'he3: sbox=8'h11;
      8'he4: sbox=8'h69; 8'he5: sbox=8'hd9; 8'he6: sbox=8'h8e; 8'he7: sbox=8'h94;
      8'he8: sbox=8'h9b; 8'he9: sbox=8'h1e; 8'hea: sbox=8'h87; 8'heb: sbox=8'he9;
      8'hec: sbox=8'hce; 8'hed: sbox=8'h55; 8'hee: sbox=8'h28; 8'hef: sbox=8'hdf;
      8'hf0: sbox=8'h8c; 8'hf1: sbox=8'ha1; 8'hf2: sbox=8'h89; 8'hf3: sbox=8'h0d;
      8'hf4: sbox=8'hbf; 8'hf5: sbox=8'he6; 8'hf6: sbox=8'h42; 8'hf7: sbox=8'h68;
      8'hf8: sbox=8'h41; 8'hf9: sbox=8'h99; 8'hfa: sbox=8'h2d; 8'hfb: sbox=8'h0f;
      8'hfc: sbox=8'hb0; 8'hfd: sbox=8'h54; 8'hfe: sbox=8'hbb; 8'hff: sbox=8'h16;
    endcase
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

  // ------------------- helpers --------------------------------------------
  task automatic chk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (t=%0t)", msg, $time);
    end
  endtask

  task automatic reg_write(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk);
      reg_addr = a; reg_wdata = d; reg_we = 1'b1;
      @(negedge clk);
      reg_we = 1'b0;
    end
  endtask

  task automatic reg_read(input [2:0] a, output [7:0] d);
    begin
      @(negedge clk);
      reg_addr = a;
      #1 d = reg_rdata;            // combinational read
    end
  endtask

  // expect a TX->RX message of given type; capture payload
  task automatic tx_expect(input [3:0] mtype, output [127:0] data);
    int n;
    bit done;
    begin
      n = 0; done = 1'b0;
      txm_ready = 1'b1;            // DUT holds the message until we accept
      #1;                          // settle; the message may already be up
      if (txm_valid && txm_type == mtype) begin
        data = txm_data;
        done = 1'b1;
        @(negedge clk);            // handshake lands on the next posedge
      end
      while (!done) begin
        @(negedge clk);
        if (txm_valid && txm_type == mtype) begin
          data = txm_data;
          @(negedge clk);          // handshake lands on the next posedge
          done = 1'b1;
        end else begin
          n++;
          if (n > 2000) begin
            chk(0, $sformatf("timeout waiting TX message type %0d", mtype));
            data = {128{1'bx}};
            done = 1'b1;
          end
        end
      end
      txm_ready = 1'b0;
    end
  endtask

  // send an RX->TX message (valid/ready handshake)
  task automatic rx_send(input [3:0] mtype, input [127:0] data);
    int n = 0;
    begin
      @(negedge clk);
      rxm_type = mtype; rxm_data = data; rxm_valid = 1'b1;
      @(posedge clk);
      while (!rxm_ready && n <= 2000) begin
        n++;
        @(posedge clk);
      end
      chk(n <= 2000, $sformatf("rx_send type %0d never accepted", mtype));
      @(negedge clk);
      rxm_valid = 1'b0;
    end
  endtask

  // wait until STATUS bit1 (authenticated) reaches 'val'
  task automatic wait_auth(input bit val);
    int n;
    bit done;
    logic [7:0] st;
    begin
      n = 0; done = 1'b0;
      while (!done) begin
        reg_read(3'd1, st);
        if (st[1] == val) done = 1'b1;
        else begin
          n++;
          if (n > 2000) begin
            chk(0, $sformatf("timeout waiting authenticated=%0b", val));
            done = 1'b1;
          end
        end
      end
    end
  endtask

  // drive one pixel, check its encrypted word against the AES-CTR keystream
  task automatic pixel_xfer(input [31:0] pix, input [127:0] sk,
                            input [63:0] frame, input int blk);
    logic [127:0] kb;
    begin
      kb = aes128_enc(sk, {frame, 32'h0, blk[31:0]}); // TB CTR keystream
      @(negedge clk);
      pix_data = pix; pix_valid = 1'b1;
      @(posedge clk);
      while (!pix_ready) @(posedge clk);     // accepted at this edge
      @(negedge clk);
      pix_valid = 1'b0;
      chk(enc_valid, "enc_valid not raised after accepted pixel");
      if (enc_valid)
        chk(enc_data === (pix ^ kb[127:96]),
            $sformatf("cipher mismatch pix=%08x got=%08x exp=%08x",
                      pix, enc_data, pix ^ kb[127:96]));
    end
  endtask

  // full pixel loopback round with boundary + pseudo-random samples
  task automatic pixel_round(input [127:0] sk, input [63:0] frame);
    logic [31:0] pats [0:7];
    int i;
    begin
      pats[0] = 32'h0000_0000; pats[1] = 32'hFFFF_FFFF;
      pats[2] = 32'hAAAA_AAAA; pats[3] = 32'h5555_5555;
      pats[4] = 32'h1234_5678; pats[5] = 32'hDEAD_BEEF;
      pats[6] = 32'h0000_0001; pats[7] = 32'h8000_0000;
      for (i = 0; i < 8; i++) pixel_xfer(pats[i], sk, frame, i);
      $display("INFO: pixel loopback round done (8 words, AES-CTR decrypt OK)");
    end
  endtask

  // run the AKE/pairing/locality/SKE sequence up to (excl.) authentication
  // fail_mode: 0 = none, 1 = withhold locality response, 2 = bad pairing ack
  task automatic auth_sequence(input bit repeater, input int fail_mode);
    logic [127:0] m;
    logic [127:0] hrx_pad;
    logic [7:0]   rb;
    begin
      hrx_pad = {rx_hrx, rx_hrx, rx_hrx, rx_hrx};

      // --- AKE_Init ---
      tx_expect(MT_AKE_INIT, m);
      cap_rtx = m[63:0];
      chk(cap_rtx !== 64'h0, "rtx must be nonzero");
      // independent session key derivation: ks = AES-128-ECB(km, {rtx,rtx})
      ks_exp = aes128_enc(rx_km, {cap_rtx, cap_rtx});

      // --- AKE_Send_Cert: rxcaps + rx pubkey-hash placeholder ---
      rx_send(MT_AKE_CERT, {32'h0, rx_hrx, 63'h0, repeater});

      // --- pairing: expect E_km = AES-128-ECB(key=hrx_pad, pt=km) ---
      tx_expect(MT_AKE_EKM, m);
      chk(m === aes128_enc(hrx_pad, rx_km),
          $sformatf("E_km mismatch got=%032x exp=%032x",
                    m, aes128_enc(hrx_pad, rx_km)));

      // --- pairing ack (H' = AES-128-ECB(key=km, pt=hrx_pad)[31:0]) ---
      m = aes128_enc(rx_km, hrx_pad);
      if (fail_mode == 2)
        rx_send(MT_PAIR_ACK, {96'h0, ~m[31:0]});   // deliberately wrong H'
      else
        rx_send(MT_PAIR_ACK, {96'h0, m[31:0]});

      if (fail_mode != 2) begin
        // --- locality challenge ---
        tx_expect(MT_LC_INIT, m);
        cap_l = m[63:0];
        if (fail_mode != 1) begin
          rx_send(MT_LC_RESP, {64'h0, cap_l ^ ks_exp[63:0]});

          // --- session key exchange: Eks = ks XOR km ---
          tx_expect(MT_SKE, m);
          chk((m ^ rx_km) === ks_exp,
              $sformatf("session key mismatch: DUT ks=%032x TB ks=%032x",
                        m ^ rx_km, ks_exp));

          if (repeater) begin
            // DUT waits in RPT_WAIT (state 8) for repeater-ready
            reg_read(3'd6, rb);
            chk(rb === 8'd8, "FSM not in RPT_WAIT after SKE (repeater peer)");
            reg_read(3'd1, rb);
            chk(rb[1] === 1'b0, "authenticated early (before RPT_ACK)");
            rx_send(MT_RPT_ACK, {96'h0, 32'h0000_0100}); // RxInfo-ish
          end
        end
        // fail_mode == 1: withhold LC response -> DUT times out
      end
      // fail_mode == 2: DUT must fail on the bad pairing ack
    end
  endtask

  // ------------------- stimulus -------------------------------------------
  logic [7:0]  rb;
  logic [127:0] rtx_prev;
  int i;

  assign enc_ready = 1'b1;   // sink always drains encrypted pixels

  initial begin
    rx_km       = 128'h2B7E_1516_28AE_D2A6_ABF7_1588_09CF_4F3C;
    rx_hrx      = 32'hC0FF_EE11;
    rx_repeater = 1'b0;

    // ---------------- reset ----------------
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // ---- CHECK 0: TB AES-128 known-answer anchors ----
    // FIPS-197 Appendix C / NIST vector: key=000102..0f
    chk(aes128_enc(128'h00010203_04050607_08090a0b_0c0d0e0f,
                   128'h00112233_44556677_8899aabb_ccddeeff)
        === 128'h69c4e0d8_6a7b0430_d8cdb780_70b4c55a,
        "TB AES-128 fails FIPS-197 KAT (key=000102..0f)");
    // openssl-precomputed anchor: AES-128-ECB(key=rx_km, pt=0^128)
    chk(aes128_enc(rx_km, 128'h0)
        === 128'h7df76b0c_1ab899b3_3e42f047_b91b546f,
        "TB AES-128 fails openssl KAT (key=km, pt=0)");
    $display("INFO: check 0 (AES-128 known-answer anchors) done");

    // ---- CHECK 1: reset state ----
    reg_read(3'd1, rb); chk(rb === 8'h00, "STATUS not 0 after reset");
    reg_read(3'd2, rb); chk(rb === 8'h23, "hdcp2version != 0x23");
    reg_read(3'd3, rb); chk(rb === 8'h00, "ERR not 0 after reset");
    reg_read(3'd6, rb); chk(rb === 8'h00, "STATE not IDLE after reset");
    chk(irq === 1'b0, "irq asserted after reset");
    $display("INFO: check 1 (reset state) done");

    // ---- CHECK 2: km register-window write + readback ----
    for (i = 0; i < 16; i++) begin
      reg_write(3'd4, i[3:0]);                       // KMIDX
      reg_write(3'd5, rx_km[i*8 +: 8]);              // KMDAT
    end
    for (i = 0; i < 16; i++) begin
      reg_write(3'd4, i[3:0]);
      reg_read(3'd5, rb);
      chk(rb === rx_km[i*8 +: 8],
          $sformatf("km readback byte %0d got=%02x exp=%02x",
                    i, rb, rx_km[i*8 +: 8]));
    end
    $display("INFO: check 2 (km window write/readback) done");

    // ---- CHECK 3: session 1 (non-repeater) full auth + encryption ----
    reg_write(3'd0, 8'h01);                          // CTRL.start
    auth_sequence(1'b0, 0);
    wait_auth(1'b1);
    reg_read(3'd1, rb);
    chk(rb[2] === 1'b1, "enc_active not set after auth");
    chk(rb[4] === 1'b0, "peer_is_repeater wrong for session 1");
    // session key readable via KS window and matches TB AES derivation
    for (i = 0; i < 16; i++) begin
      reg_write(3'd4, i[3:0]);
      reg_read(3'd7, rb);
      chk(rb === ks_exp[i*8 +: 8],
          $sformatf("ks window byte %0d got=%02x exp=%02x",
                    i, rb, ks_exp[i*8 +: 8]));
    end
    pixel_round(ks_exp, 64'd1);                      // frame_ctr = 1 (session 1)
    rtx_prev = cap_rtx;
    $display("INFO: check 3 (session 1 full auth + AES-CTR cipher) done");

    // ---- CHECK 4: session 2 (repeater peer), back-to-back ----
    reg_write(3'd0, 8'h01);                          // re-start from AUTH state
    auth_sequence(1'b1, 0);
    chk(cap_rtx !== rtx_prev[63:0], "rtx not refreshed for session 2");
    wait_auth(1'b1);
    reg_read(3'd1, rb);
    chk(rb[4] === 1'b1, "peer_is_repeater not set for session 2");
    pixel_round(ks_exp, 64'd2);                      // frame_ctr = 2 (session 2)
    $display("INFO: check 4 (session 2 repeater back-to-back) done");

    // ---- CHECK 5: error injection -- locality timeout ----
    reg_write(3'd0, 8'h01);
    auth_sequence(1'b0, 1);                          // withhold LC response
    repeat (40) @(negedge clk);                      // let the 20-clk timer expire
    reg_read(3'd1, rb);
    chk(rb[3] === 1'b1, "fail not set after locality timeout");
    chk(rb[1] === 1'b0, "authenticated wrongly set after locality timeout");
    reg_read(3'd3, rb);
    chk(rb[0] === 1'b1, "ERR locality-timeout bit not set");
    chk(irq === 1'b1, "irq not asserted on locality timeout");
    reg_write(3'd0, 8'h04);                          // CTRL.irq_clr
    @(negedge clk);
    chk(irq === 1'b0, "irq not cleared by CTRL.irq_clr");
    reg_read(3'd6, rb);
    chk(rb === 8'h00, "FSM not back to IDLE after locality fail");
    $display("INFO: check 5 (locality timeout injection) done");

    // ---- CHECK 6: error injection -- pairing failure ----
    reg_write(3'd0, 8'h01);
    auth_sequence(1'b0, 2);                          // wrong pairing ack
    repeat (4) @(negedge clk);
    reg_read(3'd1, rb);
    chk(rb[3] === 1'b1, "fail not set after pairing failure");
    reg_read(3'd3, rb);
    chk(rb[1] === 1'b1, "ERR pairing-fail bit not set");
    chk(irq === 1'b1, "irq not asserted on pairing failure");
    reg_read(3'd6, rb);
    chk(rb === 8'h00, "FSM not back to IDLE after pairing fail");
    $display("INFO: check 6 (pairing failure injection) done");

    // ---------------- result ----------------
    if (errors == 0) $display("TEST PASSED: HDCP_2_3_Content_Protection");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // ------------------- timeout guard --------------------------------------
  initial begin
    #2_000_000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
