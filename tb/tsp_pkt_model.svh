// SPDX-License-Identifier: Apache-2.0
// TS packet model shared by tb/TSP_tb.sv and the TSP register test: an
// AES-128 encryption model (S-box computed from GF(2^8) inverses), the slot
// and key state the TB loaded, mk() to build a plaintext packet and put()
// to scramble it with CISSA (AES-128-CBC, IV "DVBTMCPTAESCISSA") as a head
// end would, place it in memory and queue the bytes expected in buffers A
// and B. Define TSP_KEEP_TSC (the CTRL.keep_tsc value) before including.
// ---------------- AES-128 encryption model ----------------
logic [7:0] sb [256];
function automatic logic [7:0] xt(input logic [7:0] a); return {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00); endfunction
function automatic logic [7:0] gmul(input logic [7:0] a, input logic [7:0] b);
  logic [7:0] r;
  r = 0;
  for (int i = 0; i < 8; i++) begin if (b[i]) r ^= a; a = xt(a); end
  return r;
endfunction
initial begin
  for (int a = 0; a < 256; a++) begin
    logic [7:0] inv, s;
    inv = 0;
    if (a != 0) for (int b = 1; b < 256; b++) if (gmul(8'(a), 8'(b)) == 8'h01) begin inv = 8'(b); break; end
    s = inv;
    for (int i = 1; i < 5; i++) s ^= (inv << i) | (inv >> (8 - i));
    sb[a] = s ^ 8'h63;
  end
end
function automatic logic [127:0] aes_enc(input logic [127:0] key, input logic [127:0] pt);
  logic [7:0] st [16], k [16], t [16];
  logic [7:0] rc;
  for (int i = 0; i < 16; i++) begin st[i] = pt[127 - 8 * i -: 8] ^ key[127 - 8 * i -: 8]; k[i] = key[127 - 8 * i -: 8]; end
  rc = 8'h01;
  for (int r = 1; r <= 10; r++) begin
    // key schedule
    k[0] ^= sb[k[13]] ^ rc; k[1] ^= sb[k[14]]; k[2] ^= sb[k[15]]; k[3] ^= sb[k[12]];
    for (int i = 4; i < 16; i++) k[i] ^= k[i - 4];
    rc = xt(rc);
    // SubBytes + ShiftRows
    for (int c = 0; c < 4; c++) for (int rr = 0; rr < 4; rr++) t[4 * c + rr] = sb[st[4 * ((c + rr) % 4) + rr]];
    // MixColumns
    if (r != 10) for (int c = 0; c < 4; c++) begin
      logic [7:0] a0, a1, a2, a3;
      a0 = t[4 * c]; a1 = t[4 * c + 1]; a2 = t[4 * c + 2]; a3 = t[4 * c + 3];
      t[4 * c]     = xt(a0) ^ (xt(a1) ^ a1) ^ a2 ^ a3;
      t[4 * c + 1] = a0 ^ xt(a1) ^ (xt(a2) ^ a2) ^ a3;
      t[4 * c + 2] = a0 ^ a1 ^ xt(a2) ^ (xt(a3) ^ a3);
      t[4 * c + 3] = (xt(a0) ^ a0) ^ a1 ^ a2 ^ xt(a3);
    end
    for (int i = 0; i < 16; i++) st[i] = t[i] ^ k[i];
  end
  for (int i = 0; i < 16; i++) aes_enc[127 - 8 * i -: 8] = st[i];
endfunction

// ---------------- packets ----------------
logic [7:0] pkt [188];                           // the packet being built (plaintext)
logic [7:0] exp_a [$], exp_b [$];                // expected bytes in A and B
logic [127:0] kev [4], kod [4];                  // keys per slot
bit          kev_ok [4], kod_ok [4];
logic [12:0] spid [4];
logic [1:0]  sroute [4];
bit          sval [4];
int          n_pk = 0;                           // packets placed at src_addr
int          e_desc = 0, e_nokey = 0, e_sync = 0, e_drop = 0, e_ovf = 0;
int          a_room, b_room;

// build a packet: pid, tsc, afc, AF length (afc 1x), PCR in the AF, sync byte
task automatic mk(input logic [12:0] p, input logic [1:0] tsc, input logic [1:0] afc, input int afl,
                  input bit with_pcr, input logic [32:0] base, input logic [8:0] ext, input logic [7:0] syncb);
  int pay;
  for (int i = 0; i < 188; i++) pkt[i] = 8'($urandom);
  pkt[0] = syncb; pkt[1] = {3'b000, p[12:8]}; pkt[2] = p[7:0]; pkt[3] = {tsc, afc, 4'(n_pk)};
  if (afc[1]) begin
    pkt[4] = 8'(afl);
    if (afl > 0) pkt[5] = with_pcr ? 8'h10 : 8'h00;
    if (with_pcr) begin
      pkt[6] = base[32:25]; pkt[7] = base[24:17]; pkt[8] = base[16:9]; pkt[9] = base[8:1];
      pkt[10] = {base[0], 6'h3F, ext[8]}; pkt[11] = ext[7:0];
    end
  end
endtask
// scramble pkt as the head end would, place it at src_addr, and queue the
// expected output
task automatic put(input logic [31:0] base_addr);
  logic [7:0]  sc [188], ex [188];
  int          s, start_b, nb;
  bit          hit, dec, keyok;
  logic [127:0] key, c, ivv;
  for (int i = 0; i < 188; i++) begin ex[i] = pkt[i]; sc[i] = pkt[i]; end
  hit = 0; s = 0;
  for (int i = 3; i >= 0; i--) if (sval[i] && spid[i] == {pkt[1][4:0], pkt[2]}) begin hit = 1; s = i; end
  start_b = (pkt[3][5:4] == 2'b01) ? 4 : 5 + pkt[4];
  dec = pkt[3][7] && pkt[3][4] && start_b < 188;
  keyok = pkt[3][6] ? kod_ok[s] : kev_ok[s];
  key = pkt[3][6] ? kod[s] : kev[s];
  if (pkt[3][7] && pkt[0] == 8'h47 && hit && keyok) begin
    if (!(`TSP_KEEP_TSC)) ex[3][7:6] = 2'b00;
    if (dec) begin
      nb = (188 - start_b) / 16;
      ivv = "DVBTMCPTAESCISSA";
      for (int b = 0; b < nb; b++) begin
        logic [127:0] p;
        for (int i = 0; i < 16; i++) p[127 - 8 * i -: 8] = pkt[start_b + 16 * b + i];
        c = aes_enc(key, p ^ ivv); ivv = c;
        for (int i = 0; i < 16; i++) sc[start_b + 16 * b + i] = c[127 - 8 * i -: 8];
      end
    end
    e_desc++;
  end
  for (int i = 0; i < 188; i += 4) mem.poke(base_addr + 32'(188 * n_pk + i), {sc[i + 3], sc[i + 2], sc[i + 1], sc[i]});
  n_pk++;
  if (pkt[0] != 8'h47) begin e_sync++; return; end
  if (!hit) begin e_drop++; return; end
  if (pkt[3][7] && !keyok) e_nokey++;
  if (sroute[s][0]) begin
    if (a_room > 0) begin foreach (ex[i]) exp_a.push_back(ex[i]); a_room--; end else e_ovf++;
  end
  if (sroute[s][1]) begin
    if (b_room > 0) begin foreach (ex[i]) exp_b.push_back(ex[i]); b_room--; end else e_ovf++;
  end
endtask
