// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Crypto_DMA_top (AES_GCM_top + AXI4 DMA).
// - 48 messages from tb/Crypto_DMA_vec.svh (scripts/crypto_dma/gen_vec.py:
//   random keys, IVs, AAD of 0..69 bytes and text of 0..1000 bytes, AES-128 and
//   AES-256, encrypt and decrypt with right, truncated and corrupted tags;
//   expected values from Python cryptography / OpenSSL). Each runs from
//   random buffers (low memory, top of the address space, across 4 KB) with
//   random and zero AXI stalls; the TB checks every output byte, the zero
//   padding of the last block, nothing written past it, TAG / TAG_OK, DONE
//   once per job, STATUS.
// - An AXI error on a read and on a write: ERR and the ERR interrupt, the job
//   still ends. A sideload key that is not valid: the core's error 4, the job
//   still ends (reads drained, the output padded with zeros).
// - START while busy is ignored. Every burst's latency (first request to the
//   last response, memory side) is printed as "LAT Crypto_DMA axi R|W <c>".
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Crypto_DMA_tb;
  `include "soc_ss_tb_common.svh"
  `include "Crypto_DMA_vec.svh"
  logic         key256 = 0, decrypt = 0, key_sel = 0, sl_valid = 0;
  logic [3:0]   tag_len = 0;
  logic [255:0] key = 0, sl_key = 0;
  logic [95:0]  iv = 0;
  logic [127:0] tag_in = 0;
  logic [31:0]  src_addr = 0, dst_addr = 0;
  logic [15:0]  aad_len = 0, txt_len = 0;
  logic         start = 0;
  wire          busy, err, gcm_err, tag_ok, done, err_irq;
  wire  [2:0]   err_code;
  wire  [127:0] tag;
  wire  [31:0]  cycles;
  Crypto_DMA_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  int t_ar = -1, t_aw = -1;
  always @(posedge clk) if (rst_n) begin
    if (m_arvalid && m_arready && t_ar < 0) t_ar = $time / 10;
    if (m_rvalid && m_rready && m_rlast && t_ar >= 0) begin $display("LAT Crypto_DMA axi R %0d", $time / 10 - t_ar); t_ar = -1; end
    if (m_awvalid && m_awready && t_aw < 0) t_aw = $time / 10;
    if (m_bvalid && m_bready && t_aw >= 0) begin $display("LAT Crypto_DMA axi W %0d", $time / 10 - t_aw); t_aw = -1; end
  end

  function automatic void poke_byte(input logic [31:0] a, input logic [7:0] b);
    logic [31:0] w;
    w = mem.peek({a[31:2], 2'b00});
    w[8 * a[1:0] +: 8] = b;
    mem.poke({a[31:2], 2'b00}, w);
  endfunction
  function automatic logic [7:0] peek_byte(input logic [31:0] a);
    logic [31:0] w;
    w = mem.peek({a[31:2], 2'b00});
    return w[8 * a[1:0] +: 8];
  endfunction
  function automatic int up16(input int n); return (n + 15) / 16 * 16; endfunction

  // inject: 0 none, 1 read error, 2 write error, 3 sideload key not valid
  task automatic run(input int v, input int inject, input bit restart);
    logic [31:0] s, d;
    int al, pl, t, nd0, ne0, nbad;
    bit ex_err;
    al = v_alen[v]; pl = v_plen[v];
    s = pick_addr((up16(al) + up16(pl)) / 4 + 1); d = dst_of(s);
    for (int i = 0; i < up16(al) + up16(pl); i += 4) mem.poke(s + 32'(i), $urandom);
    for (int i = 0; i < al; i++) poke_byte(s + 32'(i), vd[v_off[v] + i]);
    for (int i = al; i < up16(al); i++) poke_byte(s + 32'(i), 8'h00);
    for (int i = 0; i < pl; i++) poke_byte(s + 32'(up16(al) + i), vd[v_off[v] + al + i]);
    for (int i = 0; i < up16(pl) + 16; i += 4) mem.poke(d + 32'(i), 32'hBAD0_0000 ^ i);
    if (inject == 1) begin mem.err_lo = s; mem.err_hi = s + 4; end
    if (inject == 2) begin mem.err_lo = d; mem.err_hi = d + 4; end
    ex_err = (inject == 1 && al + pl != 0) || (inject == 2 && pl != 0) || inject == 3;
    @(negedge clk);
    key256 = v_k256[v]; decrypt = v_dec[v]; tag_len = v_tlen[v]; key = v_key[v]; iv = v_iv[v];
    tag_in = v_tag[v]; key_sel = (inject == 3); sl_valid = 0; sl_key = $urandom;
    src_addr = s; dst_addr = d; aad_len = 16'(al); txt_len = 16'(pl);
    nd0 = n_done; ne0 = n_err_irq;
    start = 1; @(negedge clk); start = 0;
    if (!busy) fail("busy low after start");
    if (restart) begin clks(3); start = 1; @(negedge clk); start = 0; end
    t = 0;
    while (busy && t < 200000) begin @(negedge clk); t++; end
    if (busy) fail($sformatf("case %0d timed out", v));
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one job", n_done - nd0));
    if ((err || gcm_err) !== ex_err) fail($sformatf("case %0d inject %0d: ERR %b GCM_ERR %b", v, inject, err, gcm_err));
    if (n_err_irq != ne0 + ex_err) fail("ERR interrupt count");
    if (inject == 3 && !(gcm_err && err_code == 3'd4)) fail($sformatf("sideload: GCM_ERR %b code %0d", gcm_err, err_code));
    if (inject != 3 && gcm_err) fail($sformatf("case %0d: core error %0d", v, err_code));
    mem.err_lo = '1; mem.err_hi = '1;
    if (inject != 0) return;
    nbad = 0;
    for (int i = 0; i < up16(pl); i++) begin
      logic [7:0] e;
      e = (i < pl) ? vd[v_off[v] + al + pl + i] : 8'h00;
      if (peek_byte(d + 32'(i)) !== e && nbad++ < 4)
        fail($sformatf("case %0d byte %0d: %h, expected %h", v, i, peek_byte(d + 32'(i)), e));
    end
    if (mem.peek(d + 32'(up16(pl))) !== (32'hBAD0_0000 ^ up16(pl))) fail("written past the output");
    if (!v_dec[v] && tag !== v_tag[v]) fail($sformatf("case %0d tag %h, expected %h", v, tag, v_tag[v]));
    if (v_dec[v] && tag_ok !== v_ok[v]) fail($sformatf("case %0d TAG_OK %b, expected %b", v, tag_ok, v_ok[v]));
    if (cycles == 0) fail("CYCLES = 0");
  endtask

  initial begin
    load_vecs();
    clks(3);
    rst_n = 1;
    clks(2);
    for (int v = 0; v < NV; v++) begin
      mem.stall = (v % 5) != 4;
      run(v, 0, v % 9 == 3);
    end
    mem.stall = 1;
    run(7, 1, 0);
    run(8, 2, 0);
    run(9, 3, 0);
    run(10, 0, 0);
    // reset in the middle of a job: the core and the bus go idle
    @(negedge clk);
    src_addr = 32'h0000_2000; dst_addr = 32'h4000_2000; aad_len = 16; txt_len = 400; key_sel = 0;
    start = 1; @(negedge clk); start = 0;
    clks(60);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(10);
    run(11, 0, 0);
    finish("Crypto_DMA");
  end
endmodule
