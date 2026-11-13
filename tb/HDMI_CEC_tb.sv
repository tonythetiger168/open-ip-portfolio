// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of HDMI_CEC_top (TV SoC, AXI4 manager).
// The CEC line is a wired AND of the DUT's open drain and a TB device that
// can be an initiator (sends messages with +-2 tick jitter, samples the ACK
// bits) and a follower (decodes every message on the bus and acknowledges
// those for its address). Checks: messages received by the DUT in the RX
// ring (header, bytes, ACK / broadcast flags) and its ACK pulls; messages
// sent by the DUT (bytes decoded on the bus, EOM, TX_STATUS ok / nack /
// arbitration lost / bit error); broadcasts both ways; PROMISC; bad bit
// timings (RX_ERR); RX ring full (RX_OVF_CNT); too many bytes; a bad TX
// length; AXI errors; ENABLE off; reset.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module HDMI_CEC_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic        tb_low = 0;
  wire         cec_oe_low;
  wire         cec_in = !(cec_oe_low || tb_low);
  logic        enable = 0, promisc = 0, tx_start = 0;
  logic [15:0] tick_div = 1;
  logic [3:0]  la = 4'h0;
  logic [9:0]  sft = 30;
  logic [31:0] rx_base = 32'h0060_0000, tx_addr = 32'h0061_0000;
  logic [7:0]  rx_slots = 4, rx_rd = 0;
  wire  [7:0]  rx_wr;
  wire  [15:0] rx_cnt, rx_err_cnt, rx_ovf_cnt;
  wire  [3:0]  tx_status;
  wire         tx_busy, rx, rx_err, tx_done, err_irq;
  HDMI_CEC_top dut (.*);

  int n_rx = 0, n_rx_err = 0, n_tx_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_rx += rx; n_rx_err += rx_err; n_tx_done += tx_done; n_err_irq += err_irq; end

  string phase = "";
  function automatic int tpc; return int'(tick_div) + 1; endfunction   // clks per tick
  // ---------------- TB initiator ----------------
  int jit = 1;
  task automatic ticks(input int t);
    int n;
    n = t + ((jit != 0) ? int'($urandom % (2 * jit + 1)) - jit : 0);
    repeat (n * tpc()) @(negedge clk);
  endtask
  // one bit: drive low, release, sample at 21; returns the bus level at 21
  task automatic tb_bit(input bit v, output bit smp, input int lo_override);
    int lo, j;
    lo = (lo_override > 0) ? lo_override : (v ? 12 : 30);
    j = ((jit != 0) ? int'($urandom % 3) - 1 : 0);
    tb_low = 1; repeat ((lo + j) * tpc()) @(negedge clk);
    tb_low = 0;
    if (lo + j < 21) begin
      repeat ((21 - lo - j) * tpc()) @(negedge clk);
      smp = cec_in;
      repeat (27 * tpc()) @(negedge clk);
    end else begin
      smp = 0;
      repeat ((48 - lo - j) * tpc()) @(negedge clk);
    end
  endtask
  // a message from the TB; acks[i] = bus level of block i's ACK bit;
  // bad_bit: index of a bit sent with a 40-tick low (illegal), -1 none
  bit acks [16];
  task automatic tb_send(input logic [7:0] b [], input int bad_bit);
    bit s;
    int k;
    tb_low = 1; ticks(74); tb_low = 0; ticks(16);
    k = 0;
    for (int i = 0; i < b.size(); i++) begin
      logic [7:0] x;
      x = b[i];
      for (int j = 7; j >= 0; j--) begin tb_bit(x[j], s, (k == bad_bit) ? 40 : 0); k++; end
      tb_bit(i == b.size() - 1, s, 0); k++;
      tb_bit(1, s, 0); k++;
      acks[i] = s;
    end
    repeat (60 * tpc()) @(negedge clk);
  endtask

  // ---------------- TB follower / bus monitor ----------------
  logic [3:0] tb_la = 4'h5;
  bit         tb_ack_en = 1;
  logic [7:0] mon [$];                               // bytes of the last message seen
  bit         mon_eom_ok, mon_done;
  initial begin
    forever begin
      int lo, nb;
      logic [7:0] byt;
      bit eom, us, ended;
      @(negedge cec_in);
      if (!rst_n) continue;
      // start bit?
      lo = 0;
      while (!cec_in) begin @(negedge clk); lo++; end
      if (lo < 60 * tpc()) continue;
      mon.delete(); mon_done = 0; mon_eom_ok = 1; us = 0; ended = 0;
      while (!ended) begin
        byt = 0;
        for (int j = 0; j < 10; j++) begin
          fork : wait_fall
            @(negedge cec_in);
            begin repeat (100 * tpc()) @(negedge clk); end
          join_any
          disable wait_fall;
          if (cec_in) begin ended = 1; break; end      // timeout: the message ended
          if (j == 9 && (mon.size() == 0 ? byt[3:0] == tb_la : us) && tb_ack_en) begin tb_low = 1; repeat (30 * tpc()) @(negedge clk); tb_low = 0; end
          lo = 0;
          while (!cec_in) begin @(negedge clk); lo++; end
          if (j < 8) byt = {byt[6:0], lo < 21 * tpc()};
          if (j == 8) eom = lo < 21 * tpc();
        end
        if (ended) break;
        mon.push_back(byt);
        if (mon.size() == 1) us = (byt[3:0] == tb_la);
        if (eom) ended = 1;
      end
      mon_done = 1;
    end
  end

  // ---------------- RX check ----------------
  task automatic check_rx(input logic [7:0] b [], input bit acked, input bit bc, input int slot, input string what);
    logic [31:0] a, w;
    a = rx_base + 32'(slot * 32);
    w = mem.peek(a);
    if (w !== {16'b0, 5'b0, bc, acked, 1'b0, 3'b0, 5'(b.size())}) fail($sformatf("%s: RX header %h", what, w));
    for (int i = 0; i < b.size(); i++) begin
      w = mem.peek(a + 4 + 32'(4 * (i / 4)));
      if (w[8 * (i % 4) +: 8] !== b[i]) fail($sformatf("%s: RX byte %0d = %h, expected %h", what, i, w[8 * (i % 4) +: 8], b[i]));
    end
  endtask

  // ---------------- TX from the DUT ----------------
  task automatic dut_send(input logic [7:0] b [], input logic [3:0] exp_status, input string what);
    int nt0, t;
    logic [31:0] w [5];
    phase = what;
    for (int i = 0; i < 5; i++) w[i] = 0;
    w[0] = 32'(b.size());
    for (int i = 0; i < b.size(); i++) w[1 + i / 4][8 * (i % 4) +: 8] = b[i];
    for (int i = 0; i < 5; i++) mem.poke(tx_addr + 32'(4 * i), w[i]);
    nt0 = n_tx_done;
    @(negedge clk); tx_start = 1; @(negedge clk); tx_start = 0;
    t = 0;
    while (n_tx_done == nt0 && t < 2000000) begin @(negedge clk); t++; end
    if (n_tx_done != nt0 + 1) fail({what, ": no TX_DONE"});
    if (tx_status !== exp_status) fail($sformatf("%s: TX_STATUS %b, expected %b", what, tx_status, exp_status));
    repeat (120 * tpc()) @(negedge clk);
    if (exp_status == 4'b0001) begin
      if (mon.size() != b.size()) fail($sformatf("%s: %0d bytes on the bus, expected %0d", what, mon.size(), b.size()));
      else for (int i = 0; i < b.size(); i++) if (mon[i] !== b[i]) fail($sformatf("%s: bus byte %0d %h, expected %h", what, i, mon[i], b[i]));
    end
  endtask

  logic [7:0] m [];
  int slot = 0;
  task automatic rand_msg(input logic [3:0] init, input logic [3:0] dest, input int n);
    m = new[n];
    m[0] = {init, dest};
    for (int i = 1; i < n; i++) m[i] = $urandom;
  endtask
  task automatic rx_msg(input logic [3:0] dest, input int n, input bit stored, input bit acked, input string what);
    int nr0;
    phase = what;
    rand_msg(4'h5, dest, n);
    nr0 = n_rx;
    tb_send(m, -1);
    for (int i = 0; i < n; i++) if (acks[i] !== !acked) fail($sformatf("%s: ACK of block %0d = %b", what, i, acks[i]));
    clks(20);
    if (stored) begin
      if (n_rx != nr0 + 1) fail({what, ": not stored"});
      else check_rx(m, acked, dest == 4'hF, slot, what);
      slot = (slot + 1) % rx_slots;
      rx_rd = 8'(slot);
    end else if (n_rx != nr0) fail({what, ": stored"});
  endtask

  initial begin
    #200ms;
    fail({"watchdog in ", phase});
    finish("HDMI_CEC");
  end
  initial begin
    lat_master = "cec";
    clks(3);
    rst_n = 1;
    clks(2);
    la = 4'h0;                                       // TV
    // disabled: no ACK, nothing stored
    rx_msg(4'h0, 2, 0, 0, "disabled");
    enable = 1; clks(2);
    // directed messages of 1..16 bytes, stalls on and off
    for (int k = 0; k < 10; k++) begin
      mem.stall = k % 2;
      rx_msg(4'h0, 1 + $urandom % 16, 1, 1, $sformatf("rx %0d", k));
    end
    rx_msg(4'h0, 16, 1, 1, "rx 16 bytes");
    // broadcast: stored, not acknowledged; another destination: ignored
    rx_msg(4'hF, 3, 1, 0, "broadcast");
    rx_msg(4'h3, 3, 0, 0, "other destination");
    promisc = 1;
    rx_msg(4'h3, 4, 1, 0, "promisc");
    promisc = 0;
    // illegal bit timing: RX_ERR
    begin
      int e0;
      e0 = rx_err_cnt;
      rand_msg(4'h5, 4'h0, 3);
      tb_send(m, 12);
      clks(20);
      if (rx_err_cnt == e0 || n_rx_err == 0) fail("bad bit timing: no RX_ERR");
    end
    // 17 bytes: RX_ERR, not stored
    begin
      int e0, nr0;
      e0 = rx_err_cnt; nr0 = n_rx;
      rand_msg(4'h5, 4'h0, 17);
      tb_send(m, -1);
      clks(20);
      if (rx_err_cnt != e0 + 1 || n_rx != nr0) fail("17 bytes accepted");
    end
    // ring full: RX_OVF_CNT
    begin
      int o0;
      o0 = rx_ovf_cnt;
      rx_rd = 8'(slot);
      for (int k = 0; k < 4; k++) begin rand_msg(4'h5, 4'h0, 2); tb_send(m, -1); end
      clks(20);
      if (rx_ovf_cnt != o0 + 1) fail($sformatf("ring full: RX_OVF_CNT +%0d", rx_ovf_cnt - o0));
      slot = (slot + 3) % rx_slots; rx_rd = 8'(slot);
    end
    // DUT transmits: ACKed, NACKed, broadcast
    tb_ack_en = 1;
    for (int k = 0; k < 6; k++) begin
      rand_msg(4'h0, tb_la, 1 + $urandom % 16);
      dut_send(m, 4'b0001, $sformatf("tx %0d", k));
    end
    tb_ack_en = 0;
    rand_msg(4'h0, tb_la, 3);
    dut_send(m, 4'b0010, "tx nack");
    rand_msg(4'h0, 4'hF, 4);
    dut_send(m, 4'b0001, "tx broadcast");
    tb_ack_en = 1;
    // a broadcast the TB rejects (pulls ACK low) -> NACK
    begin
      logic [3:0] keep_la;
      keep_la = tb_la; tb_la = 4'hF;
      rand_msg(4'h0, 4'hF, 2);
      dut_send(m, 4'b0010, "tx broadcast rejected");
      tb_la = keep_la;
    end
    // arbitration: the TB starts at the same time with initiator 0 vs the DUT's 4
    begin
      int nt0;
      logic [7:0] tbm [];
      rand_msg(4'h4, tb_la, 2);
      for (int i = 0; i < 5; i++) mem.poke(tx_addr + 32'(4 * i), 0);
      mem.poke(tx_addr, 2); mem.poke(tx_addr + 4, {16'b0, m[1], m[0]});
      tbm = new[2]; tbm[0] = 8'h05; tbm[1] = 8'h11;
      wait (cec_in === 1);
      repeat (40 * tpc()) @(negedge clk);
      nt0 = n_tx_done;
      jit = 0;
      @(negedge clk); tx_start = 1; @(negedge clk); tx_start = 0;
      wait (cec_oe_low === 1);                         // the DUT starts its start bit
      tb_send(tbm, -1);
      jit = 1;
      wait (n_tx_done == nt0 + 1);
      if (tx_status !== 4'b0100) fail($sformatf("arbitration: TX_STATUS %b", tx_status));
    end
    // bad TX length
    for (int i = 0; i < 5; i++) mem.poke(tx_addr + 32'(4 * i), 0);
    begin
      int nt0;
      nt0 = n_tx_done;
      @(negedge clk); tx_start = 1; @(negedge clk); tx_start = 0;
      wait (n_tx_done == nt0 + 1);
      if (tx_status !== 4'b1000) fail("length 0 not rejected");
    end
    // AXI error on the RX store
    begin
      int ne0;
      ne0 = n_err_irq;
      mem.err_lo = rx_base + 32'(slot * 32) + 4; mem.err_hi = mem.err_lo + 4;
      rand_msg(4'h5, 4'h0, 2); tb_send(m, -1); clks(20);
      if (n_err_irq != ne0 + 1) fail("no ERR on an AXI error");
      mem.err_lo = '1; mem.err_hi = '1;
      slot = (slot + 1) % rx_slots; rx_rd = 8'(slot);
    end
    // ENABLE off: RX_WR clears
    enable = 0; clks(4);
    if (rx_wr != 0 || cec_oe_low) fail("ENABLE 0 does not clear");
    slot = 0; rx_rd = 0;
    enable = 1; clks(2);
    rx_msg(4'h0, 5, 1, 1, "re-enable");
    // reset in the middle of a message
    fork
      begin rand_msg(4'h5, 4'h0, 4); tb_send(m, -1); end
      begin repeat (400 * tpc()) @(negedge clk); rst_n = 0; end
    join
    if (cec_oe_low || m_awvalid || m_arvalid) fail("not idle in reset");
    rst_n = 1; slot = 0; rx_rd = 0; clks(2);
    enable = 1;
    rx_msg(4'h0, 3, 1, 1, "after reset");
    lat_summary();
    finish("HDMI_CEC");
  end
endmodule
