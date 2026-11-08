// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of TSP_top (STB SoC, AXI4 manager). The TB
// scrambles packets with its own AES-128 encryption model (S-box computed
// from GF(2^8) inverses, checked against the FIPS 197 example), in CBC
// mode with the CISSA IV, plus one known-answer packet from Python
// cryptography (tb/tsp_cissa_kat.svh). Covers: even and odd keys, clear
// packets, a scrambled packet without its key, adaptation fields of
// several lengths (payload residue under 16 bytes left as is), an
// adaptation-only packet, PCR capture, a bad sync byte, an unmatched PID,
// routes A, B and both, buffers full (OVF), CTRL.keep_tsc, a key reloaded
// between jobs, AXI read and write errors, reset. Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module TSP_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  `include "tsp_cissa_kat.svh"
  logic        keep_tsc = 0, pcr_en = 0;
  logic [12:0] pcr_pid = 0, slot_pid = 0;
  logic [31:0] src_addr = 32'h0000_0000, outa_addr = 32'h0001_0000, outb_addr = 32'h0002_0000;   // one 1 MB window (the memory model hashes a[31:20])
  logic [15:0] pkts = 0, outa_max = 64, outb_max = 64;
  logic [1:0]  slot = 0, slot_route = 0;
  logic        odd = 0, slot_valid = 0;
  logic [31:0] key0 = 0, key1 = 0, key2 = 0, key3 = 0;
  logic        start = 0, key_load = 0, slot_load = 0;
  wire         busy, key_busy, err;
  wire  [15:0] a_cnt, b_cnt, desc_cnt, nokey_cnt, sync_cnt, drop_cnt, ovf_cnt, pkt_cnt;
  wire  [31:0] pcr_base, pcr_local;
  wire  [9:0]  pcr_ext;
  wire         done, err_irq, nokey, sync, pcr, ovf;
  TSP_top dut (.*);

`define PULSE(s) begin @(negedge clk); s = 1; @(negedge clk); s = 0; end

  int n_done = 0, n_err = 0, n_nokey = 0, n_sync = 0, n_pcr = 0, n_ovf = 0;
  always @(posedge clk) if (rst_n) begin
    n_done += done; n_err += err_irq; n_nokey += nokey; n_sync += sync; n_pcr += pcr; n_ovf += ovf;
  end

`define TSP_KEEP_TSC keep_tsc
  `include "tsp_pkt_model.svh"

  function automatic logic [127:0] kbytes(input logic [31:0] w0, w1, w2, w3);
    return {w0[7:0], w0[15:8], w0[23:16], w0[31:24], w1[7:0], w1[15:8], w1[23:16], w1[31:24],
            w2[7:0], w2[15:8], w2[23:16], w2[31:24], w3[7:0], w3[15:8], w3[23:16], w3[31:24]};
  endfunction
  task automatic load_key(input int s, input bit o, input logic [127:0] k);
    {key0, key1, key2, key3} = 0;
    for (int i = 0; i < 16; i++) case (i / 4)
      0: key0[8 * (i % 4) +: 8] = k[127 - 8 * i -: 8];
      1: key1[8 * (i % 4) +: 8] = k[127 - 8 * i -: 8];
      2: key2[8 * (i % 4) +: 8] = k[127 - 8 * i -: 8];
      default: key3[8 * (i % 4) +: 8] = k[127 - 8 * i -: 8];
    endcase
    if (kbytes(key0, key1, key2, key3) !== k) fail("TB key packing");
    slot = 2'(s); odd = o;
    `PULSE(key_load)
    wait (!key_busy); clks(1);
    if (o) begin kod[s] = k; kod_ok[s] = 1; end else begin kev[s] = k; kev_ok[s] = 1; end
  endtask
  task automatic load_slot(input int s, input logic [12:0] p, input bit v, input logic [1:0] r);
    slot = 2'(s); slot_pid = p; slot_valid = v; slot_route = r;
    `PULSE(slot_load)
    spid[s] = p; sval[s] = v; sroute[s] = r;
  endtask
  task automatic begin_job;
    n_pk = 0; exp_a.delete(); exp_b.delete(); a_room = outa_max; b_room = outb_max;
    e_desc = desc_cnt; e_nokey = nokey_cnt; e_sync = sync_cnt; e_drop = drop_cnt; e_ovf = ovf_cnt;
  endtask
  task automatic run_job(input string what, input bit chk);
    int d0;
    pkts = 16'(n_pk);
    d0 = n_done;
    `PULSE(start)
    while (n_done == d0) clks(1);
    clks(2);
    if (!chk) return;
    if (a_cnt != exp_a.size() / 188 || b_cnt != exp_b.size() / 188)
      fail($sformatf("%s: A_CNT %0d B_CNT %0d, expected %0d %0d", what, a_cnt, b_cnt, exp_a.size() / 188, exp_b.size() / 188));
    foreach (exp_a[i]) begin
      logic [31:0] w;
      w = mem.peek(outa_addr + 32'(i & ~3));
      if (w[8 * (i % 4) +: 8] !== exp_a[i]) begin fail($sformatf("%s: A byte %0d (packet %0d) = %h, expected %h", what, i, i / 188, w[8 * (i % 4) +: 8], exp_a[i])); break; end
    end
    foreach (exp_b[i]) begin
      logic [31:0] w;
      w = mem.peek(outb_addr + 32'(i & ~3));
      if (w[8 * (i % 4) +: 8] !== exp_b[i]) begin fail($sformatf("%s: B byte %0d (packet %0d) = %h, expected %h", what, i, i / 188, w[8 * (i % 4) +: 8], exp_b[i])); break; end
    end
    if (desc_cnt != e_desc || nokey_cnt != e_nokey || sync_cnt != e_sync || drop_cnt != e_drop || ovf_cnt != e_ovf)
      fail($sformatf("%s: counts desc %0d/%0d nokey %0d/%0d sync %0d/%0d drop %0d/%0d ovf %0d/%0d", what,
                     desc_cnt, e_desc, nokey_cnt, e_nokey, sync_cnt, e_sync, drop_cnt, e_drop, ovf_cnt, e_ovf));
  endtask

  initial begin
    lat_master = "tsp";
    for (int i = 0; i < 4; i++) begin kev_ok[i] = 0; kod_ok[i] = 0; sval[i] = 0; spid[i] = 0; sroute[i] = 0; end
    clks(3);
    rst_n = 1;
    clks(2);
    // the TB cipher against FIPS 197 C.1
    if (aes_enc(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff) !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a)
      fail("TB AES model fails FIPS 197");
    // known-answer packet (Python cryptography)
    load_key(0, 0, 128'h101112131415161718191a1b1c1d1e1f);
    load_slot(0, 13'h100, 1, 2'b01);
    for (int i = 0; i < 47; i++) mem.poke(src_addr + 32'(4 * i), kat_ct[i]);
    pkts = 1;
    `PULSE(start)
    wait (n_done == 1); clks(2);
    for (int i = 0; i < 47; i++)
      if (mem.peek(outa_addr + 32'(4 * i)) !== kat_pt[i]) begin fail($sformatf("CISSA known answer word %0d = %h, expected %h", i, mem.peek(outa_addr + 32'(4 * i)), kat_pt[i])); break; end
    if (a_cnt != 1 || desc_cnt != 1) fail("known answer counts");
    // a mixed job
    load_key(0, 1, {$urandom, $urandom, $urandom, $urandom});
    load_key(1, 0, {$urandom, $urandom, $urandom, $urandom});
    load_slot(1, 13'h200, 1, 2'b10);
    load_slot(2, 13'h300, 1, 2'b11);
    load_key(2, 1, {$urandom, $urandom, $urandom, $urandom});
    pcr_en = 1; pcr_pid = 13'h100;
    begin_job();
    mk(13'h100, 2'b10, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);           // even, no AF
    mk(13'h100, 2'b11, 2'b11, 7, 1, 33'h1_2345_6789, 9'h1A5, 8'h47); put(src_addr);   // odd, PCR
    mk(13'h100, 2'b00, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);           // clear
    mk(13'h200, 2'b10, 2'b11, 20, 0, 0, 0, 8'h47); put(src_addr);          // AF 20: residue
    mk(13'h200, 2'b11, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);           // odd key not loaded
    mk(13'h300, 2'b11, 2'b11, 0, 0, 0, 0, 8'h47); put(src_addr);           // AF 0, both buffers
    mk(13'h300, 2'b11, 2'b10, 183, 0, 0, 0, 8'h47); put(src_addr);         // AF only
    mk(13'h300, 2'b10, 2'b11, 170, 0, 0, 0, 8'h47); put(src_addr);         // even key not loaded, no full block
    mk(13'h300, 2'b11, 2'b11, 168, 0, 0, 0, 8'h47); put(src_addr);         // one block exactly
    mk(13'h1FFF, 2'b00, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);          // unmatched
    mk(13'h100, 2'b10, 2'b01, 0, 0, 0, 0, 8'h46); put(src_addr);           // bad sync
    mk(13'h100, 2'b01, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);           // reserved control: clear
    run_job("mixed", 1);
    if (n_pcr != 1 || pcr_base !== 32'h2345_6789 || pcr_ext !== {1'b1, 9'h1A5}) fail($sformatf("PCR %h ext %h (%0d PCR interrupts)", pcr_base, pcr_ext, n_pcr));
    if (pcr_local == 0) fail("PCR_LOCAL 0");
    if (n_nokey != 2 || n_sync != 1) fail($sformatf("%0d NOKEY / %0d SYNC interrupts", n_nokey, n_sync));
    // random packets on slots 0..2 with buffers too small (OVF), keep_tsc
    outa_max = 5; outb_max = 3; keep_tsc = 1;
    begin_job();
    for (int i = 0; i < 12; i++) begin
      logic [12:0] p;
      int af;
      p = (i % 3 == 0) ? 13'h100 : (i % 3 == 1) ? 13'h200 : 13'h300;
      af = $urandom % 40;
      mk(p, {1'b1, 1'($urandom)}, (af < 30) ? 2'b11 : 2'b01, af, 0, 0, 0, 8'h47); put(src_addr);
    end
    run_job("random, OVF, keep_tsc", 1);
    if (n_ovf == 0) fail("no OVF interrupt");
    outa_max = 64; outb_max = 64; keep_tsc = 0;
    // a key reloaded between jobs; a slot disabled
    load_key(0, 0, {$urandom, $urandom, $urandom, $urandom});
    load_slot(1, 13'h200, 0, 2'b10);
    begin_job();
    mk(13'h100, 2'b10, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);
    mk(13'h200, 2'b10, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);
    run_job("new key, disabled slot", 1);
    // AXI errors: a read and a write
    begin
      int e0;
      e0 = n_err;
      begin_job();
      mk(13'h100, 2'b00, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr);
      mem.err_lo = outa_addr; mem.err_hi = outa_addr + 4;
      run_job("write error", 0);
      if (n_err != e0 + 1 || !err) fail("no ERR for a write error");
      mem.err_lo = src_addr + 8; mem.err_hi = src_addr + 12;
      run_job("read error", 0);
      if (n_err != e0 + 2) fail("no ERR for a read error");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // reset during a job
    begin_job();
    for (int i = 0; i < 4; i++) begin mk(13'h100, 2'b10, 2'b01, 0, 0, 0, 0, 8'h47); put(src_addr); end
    pkts = 4;
    `PULSE(start)
    clks(150);
    rst_n = 0;
    clks(2);
    if (busy || m_awvalid || m_arvalid) fail("not idle in reset");
    rst_n = 1;
    clks(3);
    if (desc_cnt != 0 || a_cnt != 0) fail("counters not reset");
    lat_summary();
    finish("TSP");
  end
  initial begin
    #20ms;
    $display("TEST FAILED: TSP (timeout)");
    $finish;
  end
endmodule
