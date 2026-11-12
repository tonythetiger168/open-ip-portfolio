// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tsp_aes128_dec: AES-128 decryption (FIPS 197 inverse cipher), one round
// per clock, for the TSP descrambler.
// ----------------------------------------------------------------------------
// - Key: the LAST round key (round 10), as tsp_aes128_lastkey produces it;
//   the round keys 9..0 are derived backwards on the fly, so a key slot
//   stores 128 bits.
// - start with ct / rk10: done pulses 10 clocks later with pt. start is
//   ignored while busy.
// - Byte order: byte 0 of a block is bits 127:120 (FIPS 197 order).
// tsp_aes128_lastkey: forward key expansion, 10 clocks from start to done,
// rk10 = round key 10 of key.
// ============================================================================
module tsp_aes128_dec (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,
  input  logic [127:0] ct,
  input  logic [127:0] rk10,
  output logic         busy,
  output logic         done,
  output logic [127:0] pt
);
  function automatic logic [7:0] sbox(input logic [7:0] x);
    case (x)
      8'h00: sbox = 8'h63; 8'h01: sbox = 8'h7c; 8'h02: sbox = 8'h77; 8'h03: sbox = 8'h7b; 8'h04: sbox = 8'hf2; 8'h05: sbox = 8'h6b; 8'h06: sbox = 8'h6f; 8'h07: sbox = 8'hc5;
      8'h08: sbox = 8'h30; 8'h09: sbox = 8'h01; 8'h0a: sbox = 8'h67; 8'h0b: sbox = 8'h2b; 8'h0c: sbox = 8'hfe; 8'h0d: sbox = 8'hd7; 8'h0e: sbox = 8'hab; 8'h0f: sbox = 8'h76;
      8'h10: sbox = 8'hca; 8'h11: sbox = 8'h82; 8'h12: sbox = 8'hc9; 8'h13: sbox = 8'h7d; 8'h14: sbox = 8'hfa; 8'h15: sbox = 8'h59; 8'h16: sbox = 8'h47; 8'h17: sbox = 8'hf0;
      8'h18: sbox = 8'had; 8'h19: sbox = 8'hd4; 8'h1a: sbox = 8'ha2; 8'h1b: sbox = 8'haf; 8'h1c: sbox = 8'h9c; 8'h1d: sbox = 8'ha4; 8'h1e: sbox = 8'h72; 8'h1f: sbox = 8'hc0;
      8'h20: sbox = 8'hb7; 8'h21: sbox = 8'hfd; 8'h22: sbox = 8'h93; 8'h23: sbox = 8'h26; 8'h24: sbox = 8'h36; 8'h25: sbox = 8'h3f; 8'h26: sbox = 8'hf7; 8'h27: sbox = 8'hcc;
      8'h28: sbox = 8'h34; 8'h29: sbox = 8'ha5; 8'h2a: sbox = 8'he5; 8'h2b: sbox = 8'hf1; 8'h2c: sbox = 8'h71; 8'h2d: sbox = 8'hd8; 8'h2e: sbox = 8'h31; 8'h2f: sbox = 8'h15;
      8'h30: sbox = 8'h04; 8'h31: sbox = 8'hc7; 8'h32: sbox = 8'h23; 8'h33: sbox = 8'hc3; 8'h34: sbox = 8'h18; 8'h35: sbox = 8'h96; 8'h36: sbox = 8'h05; 8'h37: sbox = 8'h9a;
      8'h38: sbox = 8'h07; 8'h39: sbox = 8'h12; 8'h3a: sbox = 8'h80; 8'h3b: sbox = 8'he2; 8'h3c: sbox = 8'heb; 8'h3d: sbox = 8'h27; 8'h3e: sbox = 8'hb2; 8'h3f: sbox = 8'h75;
      8'h40: sbox = 8'h09; 8'h41: sbox = 8'h83; 8'h42: sbox = 8'h2c; 8'h43: sbox = 8'h1a; 8'h44: sbox = 8'h1b; 8'h45: sbox = 8'h6e; 8'h46: sbox = 8'h5a; 8'h47: sbox = 8'ha0;
      8'h48: sbox = 8'h52; 8'h49: sbox = 8'h3b; 8'h4a: sbox = 8'hd6; 8'h4b: sbox = 8'hb3; 8'h4c: sbox = 8'h29; 8'h4d: sbox = 8'he3; 8'h4e: sbox = 8'h2f; 8'h4f: sbox = 8'h84;
      8'h50: sbox = 8'h53; 8'h51: sbox = 8'hd1; 8'h52: sbox = 8'h00; 8'h53: sbox = 8'hed; 8'h54: sbox = 8'h20; 8'h55: sbox = 8'hfc; 8'h56: sbox = 8'hb1; 8'h57: sbox = 8'h5b;
      8'h58: sbox = 8'h6a; 8'h59: sbox = 8'hcb; 8'h5a: sbox = 8'hbe; 8'h5b: sbox = 8'h39; 8'h5c: sbox = 8'h4a; 8'h5d: sbox = 8'h4c; 8'h5e: sbox = 8'h58; 8'h5f: sbox = 8'hcf;
      8'h60: sbox = 8'hd0; 8'h61: sbox = 8'hef; 8'h62: sbox = 8'haa; 8'h63: sbox = 8'hfb; 8'h64: sbox = 8'h43; 8'h65: sbox = 8'h4d; 8'h66: sbox = 8'h33; 8'h67: sbox = 8'h85;
      8'h68: sbox = 8'h45; 8'h69: sbox = 8'hf9; 8'h6a: sbox = 8'h02; 8'h6b: sbox = 8'h7f; 8'h6c: sbox = 8'h50; 8'h6d: sbox = 8'h3c; 8'h6e: sbox = 8'h9f; 8'h6f: sbox = 8'ha8;
      8'h70: sbox = 8'h51; 8'h71: sbox = 8'ha3; 8'h72: sbox = 8'h40; 8'h73: sbox = 8'h8f; 8'h74: sbox = 8'h92; 8'h75: sbox = 8'h9d; 8'h76: sbox = 8'h38; 8'h77: sbox = 8'hf5;
      8'h78: sbox = 8'hbc; 8'h79: sbox = 8'hb6; 8'h7a: sbox = 8'hda; 8'h7b: sbox = 8'h21; 8'h7c: sbox = 8'h10; 8'h7d: sbox = 8'hff; 8'h7e: sbox = 8'hf3; 8'h7f: sbox = 8'hd2;
      8'h80: sbox = 8'hcd; 8'h81: sbox = 8'h0c; 8'h82: sbox = 8'h13; 8'h83: sbox = 8'hec; 8'h84: sbox = 8'h5f; 8'h85: sbox = 8'h97; 8'h86: sbox = 8'h44; 8'h87: sbox = 8'h17;
      8'h88: sbox = 8'hc4; 8'h89: sbox = 8'ha7; 8'h8a: sbox = 8'h7e; 8'h8b: sbox = 8'h3d; 8'h8c: sbox = 8'h64; 8'h8d: sbox = 8'h5d; 8'h8e: sbox = 8'h19; 8'h8f: sbox = 8'h73;
      8'h90: sbox = 8'h60; 8'h91: sbox = 8'h81; 8'h92: sbox = 8'h4f; 8'h93: sbox = 8'hdc; 8'h94: sbox = 8'h22; 8'h95: sbox = 8'h2a; 8'h96: sbox = 8'h90; 8'h97: sbox = 8'h88;
      8'h98: sbox = 8'h46; 8'h99: sbox = 8'hee; 8'h9a: sbox = 8'hb8; 8'h9b: sbox = 8'h14; 8'h9c: sbox = 8'hde; 8'h9d: sbox = 8'h5e; 8'h9e: sbox = 8'h0b; 8'h9f: sbox = 8'hdb;
      8'ha0: sbox = 8'he0; 8'ha1: sbox = 8'h32; 8'ha2: sbox = 8'h3a; 8'ha3: sbox = 8'h0a; 8'ha4: sbox = 8'h49; 8'ha5: sbox = 8'h06; 8'ha6: sbox = 8'h24; 8'ha7: sbox = 8'h5c;
      8'ha8: sbox = 8'hc2; 8'ha9: sbox = 8'hd3; 8'haa: sbox = 8'hac; 8'hab: sbox = 8'h62; 8'hac: sbox = 8'h91; 8'had: sbox = 8'h95; 8'hae: sbox = 8'he4; 8'haf: sbox = 8'h79;
      8'hb0: sbox = 8'he7; 8'hb1: sbox = 8'hc8; 8'hb2: sbox = 8'h37; 8'hb3: sbox = 8'h6d; 8'hb4: sbox = 8'h8d; 8'hb5: sbox = 8'hd5; 8'hb6: sbox = 8'h4e; 8'hb7: sbox = 8'ha9;
      8'hb8: sbox = 8'h6c; 8'hb9: sbox = 8'h56; 8'hba: sbox = 8'hf4; 8'hbb: sbox = 8'hea; 8'hbc: sbox = 8'h65; 8'hbd: sbox = 8'h7a; 8'hbe: sbox = 8'hae; 8'hbf: sbox = 8'h08;
      8'hc0: sbox = 8'hba; 8'hc1: sbox = 8'h78; 8'hc2: sbox = 8'h25; 8'hc3: sbox = 8'h2e; 8'hc4: sbox = 8'h1c; 8'hc5: sbox = 8'ha6; 8'hc6: sbox = 8'hb4; 8'hc7: sbox = 8'hc6;
      8'hc8: sbox = 8'he8; 8'hc9: sbox = 8'hdd; 8'hca: sbox = 8'h74; 8'hcb: sbox = 8'h1f; 8'hcc: sbox = 8'h4b; 8'hcd: sbox = 8'hbd; 8'hce: sbox = 8'h8b; 8'hcf: sbox = 8'h8a;
      8'hd0: sbox = 8'h70; 8'hd1: sbox = 8'h3e; 8'hd2: sbox = 8'hb5; 8'hd3: sbox = 8'h66; 8'hd4: sbox = 8'h48; 8'hd5: sbox = 8'h03; 8'hd6: sbox = 8'hf6; 8'hd7: sbox = 8'h0e;
      8'hd8: sbox = 8'h61; 8'hd9: sbox = 8'h35; 8'hda: sbox = 8'h57; 8'hdb: sbox = 8'hb9; 8'hdc: sbox = 8'h86; 8'hdd: sbox = 8'hc1; 8'hde: sbox = 8'h1d; 8'hdf: sbox = 8'h9e;
      8'he0: sbox = 8'he1; 8'he1: sbox = 8'hf8; 8'he2: sbox = 8'h98; 8'he3: sbox = 8'h11; 8'he4: sbox = 8'h69; 8'he5: sbox = 8'hd9; 8'he6: sbox = 8'h8e; 8'he7: sbox = 8'h94;
      8'he8: sbox = 8'h9b; 8'he9: sbox = 8'h1e; 8'hea: sbox = 8'h87; 8'heb: sbox = 8'he9; 8'hec: sbox = 8'hce; 8'hed: sbox = 8'h55; 8'hee: sbox = 8'h28; 8'hef: sbox = 8'hdf;
      8'hf0: sbox = 8'h8c; 8'hf1: sbox = 8'ha1; 8'hf2: sbox = 8'h89; 8'hf3: sbox = 8'h0d; 8'hf4: sbox = 8'hbf; 8'hf5: sbox = 8'he6; 8'hf6: sbox = 8'h42; 8'hf7: sbox = 8'h68;
      8'hf8: sbox = 8'h41; 8'hf9: sbox = 8'h99; 8'hfa: sbox = 8'h2d; 8'hfb: sbox = 8'h0f; 8'hfc: sbox = 8'hb0; 8'hfd: sbox = 8'h54; 8'hfe: sbox = 8'hbb; 8'hff: sbox = 8'h16;
      default: sbox = 8'h00;
    endcase
  endfunction
  function automatic logic [7:0] isbox(input logic [7:0] x);
    case (x)
      8'h00: isbox = 8'h52; 8'h01: isbox = 8'h09; 8'h02: isbox = 8'h6a; 8'h03: isbox = 8'hd5; 8'h04: isbox = 8'h30; 8'h05: isbox = 8'h36; 8'h06: isbox = 8'ha5; 8'h07: isbox = 8'h38;
      8'h08: isbox = 8'hbf; 8'h09: isbox = 8'h40; 8'h0a: isbox = 8'ha3; 8'h0b: isbox = 8'h9e; 8'h0c: isbox = 8'h81; 8'h0d: isbox = 8'hf3; 8'h0e: isbox = 8'hd7; 8'h0f: isbox = 8'hfb;
      8'h10: isbox = 8'h7c; 8'h11: isbox = 8'he3; 8'h12: isbox = 8'h39; 8'h13: isbox = 8'h82; 8'h14: isbox = 8'h9b; 8'h15: isbox = 8'h2f; 8'h16: isbox = 8'hff; 8'h17: isbox = 8'h87;
      8'h18: isbox = 8'h34; 8'h19: isbox = 8'h8e; 8'h1a: isbox = 8'h43; 8'h1b: isbox = 8'h44; 8'h1c: isbox = 8'hc4; 8'h1d: isbox = 8'hde; 8'h1e: isbox = 8'he9; 8'h1f: isbox = 8'hcb;
      8'h20: isbox = 8'h54; 8'h21: isbox = 8'h7b; 8'h22: isbox = 8'h94; 8'h23: isbox = 8'h32; 8'h24: isbox = 8'ha6; 8'h25: isbox = 8'hc2; 8'h26: isbox = 8'h23; 8'h27: isbox = 8'h3d;
      8'h28: isbox = 8'hee; 8'h29: isbox = 8'h4c; 8'h2a: isbox = 8'h95; 8'h2b: isbox = 8'h0b; 8'h2c: isbox = 8'h42; 8'h2d: isbox = 8'hfa; 8'h2e: isbox = 8'hc3; 8'h2f: isbox = 8'h4e;
      8'h30: isbox = 8'h08; 8'h31: isbox = 8'h2e; 8'h32: isbox = 8'ha1; 8'h33: isbox = 8'h66; 8'h34: isbox = 8'h28; 8'h35: isbox = 8'hd9; 8'h36: isbox = 8'h24; 8'h37: isbox = 8'hb2;
      8'h38: isbox = 8'h76; 8'h39: isbox = 8'h5b; 8'h3a: isbox = 8'ha2; 8'h3b: isbox = 8'h49; 8'h3c: isbox = 8'h6d; 8'h3d: isbox = 8'h8b; 8'h3e: isbox = 8'hd1; 8'h3f: isbox = 8'h25;
      8'h40: isbox = 8'h72; 8'h41: isbox = 8'hf8; 8'h42: isbox = 8'hf6; 8'h43: isbox = 8'h64; 8'h44: isbox = 8'h86; 8'h45: isbox = 8'h68; 8'h46: isbox = 8'h98; 8'h47: isbox = 8'h16;
      8'h48: isbox = 8'hd4; 8'h49: isbox = 8'ha4; 8'h4a: isbox = 8'h5c; 8'h4b: isbox = 8'hcc; 8'h4c: isbox = 8'h5d; 8'h4d: isbox = 8'h65; 8'h4e: isbox = 8'hb6; 8'h4f: isbox = 8'h92;
      8'h50: isbox = 8'h6c; 8'h51: isbox = 8'h70; 8'h52: isbox = 8'h48; 8'h53: isbox = 8'h50; 8'h54: isbox = 8'hfd; 8'h55: isbox = 8'hed; 8'h56: isbox = 8'hb9; 8'h57: isbox = 8'hda;
      8'h58: isbox = 8'h5e; 8'h59: isbox = 8'h15; 8'h5a: isbox = 8'h46; 8'h5b: isbox = 8'h57; 8'h5c: isbox = 8'ha7; 8'h5d: isbox = 8'h8d; 8'h5e: isbox = 8'h9d; 8'h5f: isbox = 8'h84;
      8'h60: isbox = 8'h90; 8'h61: isbox = 8'hd8; 8'h62: isbox = 8'hab; 8'h63: isbox = 8'h00; 8'h64: isbox = 8'h8c; 8'h65: isbox = 8'hbc; 8'h66: isbox = 8'hd3; 8'h67: isbox = 8'h0a;
      8'h68: isbox = 8'hf7; 8'h69: isbox = 8'he4; 8'h6a: isbox = 8'h58; 8'h6b: isbox = 8'h05; 8'h6c: isbox = 8'hb8; 8'h6d: isbox = 8'hb3; 8'h6e: isbox = 8'h45; 8'h6f: isbox = 8'h06;
      8'h70: isbox = 8'hd0; 8'h71: isbox = 8'h2c; 8'h72: isbox = 8'h1e; 8'h73: isbox = 8'h8f; 8'h74: isbox = 8'hca; 8'h75: isbox = 8'h3f; 8'h76: isbox = 8'h0f; 8'h77: isbox = 8'h02;
      8'h78: isbox = 8'hc1; 8'h79: isbox = 8'haf; 8'h7a: isbox = 8'hbd; 8'h7b: isbox = 8'h03; 8'h7c: isbox = 8'h01; 8'h7d: isbox = 8'h13; 8'h7e: isbox = 8'h8a; 8'h7f: isbox = 8'h6b;
      8'h80: isbox = 8'h3a; 8'h81: isbox = 8'h91; 8'h82: isbox = 8'h11; 8'h83: isbox = 8'h41; 8'h84: isbox = 8'h4f; 8'h85: isbox = 8'h67; 8'h86: isbox = 8'hdc; 8'h87: isbox = 8'hea;
      8'h88: isbox = 8'h97; 8'h89: isbox = 8'hf2; 8'h8a: isbox = 8'hcf; 8'h8b: isbox = 8'hce; 8'h8c: isbox = 8'hf0; 8'h8d: isbox = 8'hb4; 8'h8e: isbox = 8'he6; 8'h8f: isbox = 8'h73;
      8'h90: isbox = 8'h96; 8'h91: isbox = 8'hac; 8'h92: isbox = 8'h74; 8'h93: isbox = 8'h22; 8'h94: isbox = 8'he7; 8'h95: isbox = 8'had; 8'h96: isbox = 8'h35; 8'h97: isbox = 8'h85;
      8'h98: isbox = 8'he2; 8'h99: isbox = 8'hf9; 8'h9a: isbox = 8'h37; 8'h9b: isbox = 8'he8; 8'h9c: isbox = 8'h1c; 8'h9d: isbox = 8'h75; 8'h9e: isbox = 8'hdf; 8'h9f: isbox = 8'h6e;
      8'ha0: isbox = 8'h47; 8'ha1: isbox = 8'hf1; 8'ha2: isbox = 8'h1a; 8'ha3: isbox = 8'h71; 8'ha4: isbox = 8'h1d; 8'ha5: isbox = 8'h29; 8'ha6: isbox = 8'hc5; 8'ha7: isbox = 8'h89;
      8'ha8: isbox = 8'h6f; 8'ha9: isbox = 8'hb7; 8'haa: isbox = 8'h62; 8'hab: isbox = 8'h0e; 8'hac: isbox = 8'haa; 8'had: isbox = 8'h18; 8'hae: isbox = 8'hbe; 8'haf: isbox = 8'h1b;
      8'hb0: isbox = 8'hfc; 8'hb1: isbox = 8'h56; 8'hb2: isbox = 8'h3e; 8'hb3: isbox = 8'h4b; 8'hb4: isbox = 8'hc6; 8'hb5: isbox = 8'hd2; 8'hb6: isbox = 8'h79; 8'hb7: isbox = 8'h20;
      8'hb8: isbox = 8'h9a; 8'hb9: isbox = 8'hdb; 8'hba: isbox = 8'hc0; 8'hbb: isbox = 8'hfe; 8'hbc: isbox = 8'h78; 8'hbd: isbox = 8'hcd; 8'hbe: isbox = 8'h5a; 8'hbf: isbox = 8'hf4;
      8'hc0: isbox = 8'h1f; 8'hc1: isbox = 8'hdd; 8'hc2: isbox = 8'ha8; 8'hc3: isbox = 8'h33; 8'hc4: isbox = 8'h88; 8'hc5: isbox = 8'h07; 8'hc6: isbox = 8'hc7; 8'hc7: isbox = 8'h31;
      8'hc8: isbox = 8'hb1; 8'hc9: isbox = 8'h12; 8'hca: isbox = 8'h10; 8'hcb: isbox = 8'h59; 8'hcc: isbox = 8'h27; 8'hcd: isbox = 8'h80; 8'hce: isbox = 8'hec; 8'hcf: isbox = 8'h5f;
      8'hd0: isbox = 8'h60; 8'hd1: isbox = 8'h51; 8'hd2: isbox = 8'h7f; 8'hd3: isbox = 8'ha9; 8'hd4: isbox = 8'h19; 8'hd5: isbox = 8'hb5; 8'hd6: isbox = 8'h4a; 8'hd7: isbox = 8'h0d;
      8'hd8: isbox = 8'h2d; 8'hd9: isbox = 8'he5; 8'hda: isbox = 8'h7a; 8'hdb: isbox = 8'h9f; 8'hdc: isbox = 8'h93; 8'hdd: isbox = 8'hc9; 8'hde: isbox = 8'h9c; 8'hdf: isbox = 8'hef;
      8'he0: isbox = 8'ha0; 8'he1: isbox = 8'he0; 8'he2: isbox = 8'h3b; 8'he3: isbox = 8'h4d; 8'he4: isbox = 8'hae; 8'he5: isbox = 8'h2a; 8'he6: isbox = 8'hf5; 8'he7: isbox = 8'hb0;
      8'he8: isbox = 8'hc8; 8'he9: isbox = 8'heb; 8'hea: isbox = 8'hbb; 8'heb: isbox = 8'h3c; 8'hec: isbox = 8'h83; 8'hed: isbox = 8'h53; 8'hee: isbox = 8'h99; 8'hef: isbox = 8'h61;
      8'hf0: isbox = 8'h17; 8'hf1: isbox = 8'h2b; 8'hf2: isbox = 8'h04; 8'hf3: isbox = 8'h7e; 8'hf4: isbox = 8'hba; 8'hf5: isbox = 8'h77; 8'hf6: isbox = 8'hd6; 8'hf7: isbox = 8'h26;
      8'hf8: isbox = 8'he1; 8'hf9: isbox = 8'h69; 8'hfa: isbox = 8'h14; 8'hfb: isbox = 8'h63; 8'hfc: isbox = 8'h55; 8'hfd: isbox = 8'h21; 8'hfe: isbox = 8'h0c; 8'hff: isbox = 8'h7d;
      default: isbox = 8'h00;
    endcase
  endfunction
  function automatic logic [7:0] xt(input logic [7:0] a);
    xt = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
  endfunction
  function automatic logic [7:0] gm(input logic [7:0] a, input logic [3:0] b);   // a * b, b in {9, b, d, e}
    logic [7:0] a2, a4, a8;
    a2 = xt(a); a4 = xt(a2); a8 = xt(a4);
    gm = (b[0] ? a : 8'h00) ^ (b[1] ? a2 : 8'h00) ^ (b[2] ? a4 : 8'h00) ^ (b[3] ? a8 : 8'h00);
  endfunction
  function automatic logic [7:0] rcon(input logic [3:0] r);
    case (r)
      4'd1: rcon = 8'h01; 4'd2: rcon = 8'h02; 4'd3: rcon = 8'h04; 4'd4: rcon = 8'h08; 4'd5: rcon = 8'h10;
      4'd6: rcon = 8'h20; 4'd7: rcon = 8'h40; 4'd8: rcon = 8'h80; 4'd9: rcon = 8'h1b; default: rcon = 8'h36;
    endcase
  endfunction
  logic [127:0] s, k;
  logic [3:0]   r;
  // round key r - 1 from round key r
  logic [31:0]  k0, k1, k2, k3, p0, p1, p2, p3;
  assign {k0, k1, k2, k3} = k;
  assign p3 = k3 ^ k2;
  assign p2 = k2 ^ k1;
  assign p1 = k1 ^ k0;
  assign p0 = k0 ^ {sbox(p3[23:16]) ^ rcon(r), sbox(p3[15:8]), sbox(p3[7:0]), sbox(p3[31:24])};
  wire [127:0] kp = {p0, p1, p2, p3};
  // InvShiftRows + InvSubBytes + AddRoundKey(kp), then InvMixColumns unless last
  logic [127:0] sb, ak, mc;
  always_comb begin
    for (int c = 0; c < 4; c++)
      for (int rr = 0; rr < 4; rr++)
        sb[127 - 8 * (4 * c + rr) -: 8] = isbox(s[127 - 8 * (4 * ((c - rr + 4) % 4) + rr) -: 8]);
    ak = sb ^ kp;
    for (int c = 0; c < 4; c++) begin
      logic [7:0] a0, a1, a2, a3;
      a0 = ak[127 - 32 * c -: 8]; a1 = ak[119 - 32 * c -: 8]; a2 = ak[111 - 32 * c -: 8]; a3 = ak[103 - 32 * c -: 8];
      mc[127 - 32 * c -: 8] = gm(a0, 4'he) ^ gm(a1, 4'hb) ^ gm(a2, 4'hd) ^ gm(a3, 4'h9);
      mc[119 - 32 * c -: 8] = gm(a0, 4'h9) ^ gm(a1, 4'he) ^ gm(a2, 4'hb) ^ gm(a3, 4'hd);
      mc[111 - 32 * c -: 8] = gm(a0, 4'hd) ^ gm(a1, 4'h9) ^ gm(a2, 4'he) ^ gm(a3, 4'hb);
      mc[103 - 32 * c -: 8] = gm(a0, 4'hb) ^ gm(a1, 4'hd) ^ gm(a2, 4'h9) ^ gm(a3, 4'he);
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s <= '0; k <= '0; r <= '0; busy <= 1'b0; done <= 1'b0; pt <= '0;
    end else begin
      done <= 1'b0;
      if (!busy) begin
        if (start) begin s <= ct ^ rk10; k <= rk10; r <= 4'd10; busy <= 1'b1; end
      end else begin
        k <= kp; r <= r - 4'd1;
        if (r == 4'd1) begin pt <= ak; busy <= 1'b0; done <= 1'b1; end
        else s <= mc;
      end
    end
  end
endmodule

module tsp_aes128_lastkey (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,
  input  logic [127:0] key,
  output logic         busy,
  output logic         done,
  output logic [127:0] rk10
);
  function automatic logic [7:0] sbox(input logic [7:0] x);
    case (x)
      8'h00: sbox = 8'h63; 8'h01: sbox = 8'h7c; 8'h02: sbox = 8'h77; 8'h03: sbox = 8'h7b; 8'h04: sbox = 8'hf2; 8'h05: sbox = 8'h6b; 8'h06: sbox = 8'h6f; 8'h07: sbox = 8'hc5;
      8'h08: sbox = 8'h30; 8'h09: sbox = 8'h01; 8'h0a: sbox = 8'h67; 8'h0b: sbox = 8'h2b; 8'h0c: sbox = 8'hfe; 8'h0d: sbox = 8'hd7; 8'h0e: sbox = 8'hab; 8'h0f: sbox = 8'h76;
      8'h10: sbox = 8'hca; 8'h11: sbox = 8'h82; 8'h12: sbox = 8'hc9; 8'h13: sbox = 8'h7d; 8'h14: sbox = 8'hfa; 8'h15: sbox = 8'h59; 8'h16: sbox = 8'h47; 8'h17: sbox = 8'hf0;
      8'h18: sbox = 8'had; 8'h19: sbox = 8'hd4; 8'h1a: sbox = 8'ha2; 8'h1b: sbox = 8'haf; 8'h1c: sbox = 8'h9c; 8'h1d: sbox = 8'ha4; 8'h1e: sbox = 8'h72; 8'h1f: sbox = 8'hc0;
      8'h20: sbox = 8'hb7; 8'h21: sbox = 8'hfd; 8'h22: sbox = 8'h93; 8'h23: sbox = 8'h26; 8'h24: sbox = 8'h36; 8'h25: sbox = 8'h3f; 8'h26: sbox = 8'hf7; 8'h27: sbox = 8'hcc;
      8'h28: sbox = 8'h34; 8'h29: sbox = 8'ha5; 8'h2a: sbox = 8'he5; 8'h2b: sbox = 8'hf1; 8'h2c: sbox = 8'h71; 8'h2d: sbox = 8'hd8; 8'h2e: sbox = 8'h31; 8'h2f: sbox = 8'h15;
      8'h30: sbox = 8'h04; 8'h31: sbox = 8'hc7; 8'h32: sbox = 8'h23; 8'h33: sbox = 8'hc3; 8'h34: sbox = 8'h18; 8'h35: sbox = 8'h96; 8'h36: sbox = 8'h05; 8'h37: sbox = 8'h9a;
      8'h38: sbox = 8'h07; 8'h39: sbox = 8'h12; 8'h3a: sbox = 8'h80; 8'h3b: sbox = 8'he2; 8'h3c: sbox = 8'heb; 8'h3d: sbox = 8'h27; 8'h3e: sbox = 8'hb2; 8'h3f: sbox = 8'h75;
      8'h40: sbox = 8'h09; 8'h41: sbox = 8'h83; 8'h42: sbox = 8'h2c; 8'h43: sbox = 8'h1a; 8'h44: sbox = 8'h1b; 8'h45: sbox = 8'h6e; 8'h46: sbox = 8'h5a; 8'h47: sbox = 8'ha0;
      8'h48: sbox = 8'h52; 8'h49: sbox = 8'h3b; 8'h4a: sbox = 8'hd6; 8'h4b: sbox = 8'hb3; 8'h4c: sbox = 8'h29; 8'h4d: sbox = 8'he3; 8'h4e: sbox = 8'h2f; 8'h4f: sbox = 8'h84;
      8'h50: sbox = 8'h53; 8'h51: sbox = 8'hd1; 8'h52: sbox = 8'h00; 8'h53: sbox = 8'hed; 8'h54: sbox = 8'h20; 8'h55: sbox = 8'hfc; 8'h56: sbox = 8'hb1; 8'h57: sbox = 8'h5b;
      8'h58: sbox = 8'h6a; 8'h59: sbox = 8'hcb; 8'h5a: sbox = 8'hbe; 8'h5b: sbox = 8'h39; 8'h5c: sbox = 8'h4a; 8'h5d: sbox = 8'h4c; 8'h5e: sbox = 8'h58; 8'h5f: sbox = 8'hcf;
      8'h60: sbox = 8'hd0; 8'h61: sbox = 8'hef; 8'h62: sbox = 8'haa; 8'h63: sbox = 8'hfb; 8'h64: sbox = 8'h43; 8'h65: sbox = 8'h4d; 8'h66: sbox = 8'h33; 8'h67: sbox = 8'h85;
      8'h68: sbox = 8'h45; 8'h69: sbox = 8'hf9; 8'h6a: sbox = 8'h02; 8'h6b: sbox = 8'h7f; 8'h6c: sbox = 8'h50; 8'h6d: sbox = 8'h3c; 8'h6e: sbox = 8'h9f; 8'h6f: sbox = 8'ha8;
      8'h70: sbox = 8'h51; 8'h71: sbox = 8'ha3; 8'h72: sbox = 8'h40; 8'h73: sbox = 8'h8f; 8'h74: sbox = 8'h92; 8'h75: sbox = 8'h9d; 8'h76: sbox = 8'h38; 8'h77: sbox = 8'hf5;
      8'h78: sbox = 8'hbc; 8'h79: sbox = 8'hb6; 8'h7a: sbox = 8'hda; 8'h7b: sbox = 8'h21; 8'h7c: sbox = 8'h10; 8'h7d: sbox = 8'hff; 8'h7e: sbox = 8'hf3; 8'h7f: sbox = 8'hd2;
      8'h80: sbox = 8'hcd; 8'h81: sbox = 8'h0c; 8'h82: sbox = 8'h13; 8'h83: sbox = 8'hec; 8'h84: sbox = 8'h5f; 8'h85: sbox = 8'h97; 8'h86: sbox = 8'h44; 8'h87: sbox = 8'h17;
      8'h88: sbox = 8'hc4; 8'h89: sbox = 8'ha7; 8'h8a: sbox = 8'h7e; 8'h8b: sbox = 8'h3d; 8'h8c: sbox = 8'h64; 8'h8d: sbox = 8'h5d; 8'h8e: sbox = 8'h19; 8'h8f: sbox = 8'h73;
      8'h90: sbox = 8'h60; 8'h91: sbox = 8'h81; 8'h92: sbox = 8'h4f; 8'h93: sbox = 8'hdc; 8'h94: sbox = 8'h22; 8'h95: sbox = 8'h2a; 8'h96: sbox = 8'h90; 8'h97: sbox = 8'h88;
      8'h98: sbox = 8'h46; 8'h99: sbox = 8'hee; 8'h9a: sbox = 8'hb8; 8'h9b: sbox = 8'h14; 8'h9c: sbox = 8'hde; 8'h9d: sbox = 8'h5e; 8'h9e: sbox = 8'h0b; 8'h9f: sbox = 8'hdb;
      8'ha0: sbox = 8'he0; 8'ha1: sbox = 8'h32; 8'ha2: sbox = 8'h3a; 8'ha3: sbox = 8'h0a; 8'ha4: sbox = 8'h49; 8'ha5: sbox = 8'h06; 8'ha6: sbox = 8'h24; 8'ha7: sbox = 8'h5c;
      8'ha8: sbox = 8'hc2; 8'ha9: sbox = 8'hd3; 8'haa: sbox = 8'hac; 8'hab: sbox = 8'h62; 8'hac: sbox = 8'h91; 8'had: sbox = 8'h95; 8'hae: sbox = 8'he4; 8'haf: sbox = 8'h79;
      8'hb0: sbox = 8'he7; 8'hb1: sbox = 8'hc8; 8'hb2: sbox = 8'h37; 8'hb3: sbox = 8'h6d; 8'hb4: sbox = 8'h8d; 8'hb5: sbox = 8'hd5; 8'hb6: sbox = 8'h4e; 8'hb7: sbox = 8'ha9;
      8'hb8: sbox = 8'h6c; 8'hb9: sbox = 8'h56; 8'hba: sbox = 8'hf4; 8'hbb: sbox = 8'hea; 8'hbc: sbox = 8'h65; 8'hbd: sbox = 8'h7a; 8'hbe: sbox = 8'hae; 8'hbf: sbox = 8'h08;
      8'hc0: sbox = 8'hba; 8'hc1: sbox = 8'h78; 8'hc2: sbox = 8'h25; 8'hc3: sbox = 8'h2e; 8'hc4: sbox = 8'h1c; 8'hc5: sbox = 8'ha6; 8'hc6: sbox = 8'hb4; 8'hc7: sbox = 8'hc6;
      8'hc8: sbox = 8'he8; 8'hc9: sbox = 8'hdd; 8'hca: sbox = 8'h74; 8'hcb: sbox = 8'h1f; 8'hcc: sbox = 8'h4b; 8'hcd: sbox = 8'hbd; 8'hce: sbox = 8'h8b; 8'hcf: sbox = 8'h8a;
      8'hd0: sbox = 8'h70; 8'hd1: sbox = 8'h3e; 8'hd2: sbox = 8'hb5; 8'hd3: sbox = 8'h66; 8'hd4: sbox = 8'h48; 8'hd5: sbox = 8'h03; 8'hd6: sbox = 8'hf6; 8'hd7: sbox = 8'h0e;
      8'hd8: sbox = 8'h61; 8'hd9: sbox = 8'h35; 8'hda: sbox = 8'h57; 8'hdb: sbox = 8'hb9; 8'hdc: sbox = 8'h86; 8'hdd: sbox = 8'hc1; 8'hde: sbox = 8'h1d; 8'hdf: sbox = 8'h9e;
      8'he0: sbox = 8'he1; 8'he1: sbox = 8'hf8; 8'he2: sbox = 8'h98; 8'he3: sbox = 8'h11; 8'he4: sbox = 8'h69; 8'he5: sbox = 8'hd9; 8'he6: sbox = 8'h8e; 8'he7: sbox = 8'h94;
      8'he8: sbox = 8'h9b; 8'he9: sbox = 8'h1e; 8'hea: sbox = 8'h87; 8'heb: sbox = 8'he9; 8'hec: sbox = 8'hce; 8'hed: sbox = 8'h55; 8'hee: sbox = 8'h28; 8'hef: sbox = 8'hdf;
      8'hf0: sbox = 8'h8c; 8'hf1: sbox = 8'ha1; 8'hf2: sbox = 8'h89; 8'hf3: sbox = 8'h0d; 8'hf4: sbox = 8'hbf; 8'hf5: sbox = 8'he6; 8'hf6: sbox = 8'h42; 8'hf7: sbox = 8'h68;
      8'hf8: sbox = 8'h41; 8'hf9: sbox = 8'h99; 8'hfa: sbox = 8'h2d; 8'hfb: sbox = 8'h0f; 8'hfc: sbox = 8'hb0; 8'hfd: sbox = 8'h54; 8'hfe: sbox = 8'hbb; 8'hff: sbox = 8'h16;
      default: sbox = 8'h00;
    endcase
  endfunction
  logic [3:0]  i;
  logic [31:0] w0, w1, w2, w3, n0, n1, n2, n3;
  logic [7:0]  rc;
  assign {w0, w1, w2, w3} = rk10;
  always_comb begin
    case (i)
      4'd1: rc = 8'h01; 4'd2: rc = 8'h02; 4'd3: rc = 8'h04; 4'd4: rc = 8'h08; 4'd5: rc = 8'h10;
      4'd6: rc = 8'h20; 4'd7: rc = 8'h40; 4'd8: rc = 8'h80; 4'd9: rc = 8'h1b; default: rc = 8'h36;
    endcase
  end
  assign n0 = w0 ^ {sbox(w3[23:16]) ^ rc, sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])};
  assign n1 = w1 ^ n0;
  assign n2 = w2 ^ n1;
  assign n3 = w3 ^ n2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i <= '0; busy <= 1'b0; done <= 1'b0; rk10 <= '0;
    end else begin
      done <= 1'b0;
      if (!busy) begin
        if (start) begin rk10 <= key; i <= 4'd1; busy <= 1'b1; end
      end else begin
        rk10 <= {n0, n1, n2, n3}; i <= i + 4'd1;
        if (i == 4'd10) begin busy <= 1'b0; done <= 1'b1; end
      end
    end
  end
endmodule
