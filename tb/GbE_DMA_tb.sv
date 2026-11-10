// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of GbE_DMA_top (Ethernet_top MAC + descriptor
// ring DMA). The link partner is a second Ethernet_top on the other end of
// the GMII wires (cfg_div = 1, promiscuous): the TB sends frames with it and
// reads what it receives.
// - TX: random frames of 1..1514 bytes in random buffers, posted in a ring
//   of 8 descriptors in batches; every frame the partner receives is
//   compared with the posted one (zero padded to 60 bytes, FCS good), each
//   descriptor's write-back {done, len} and TX_HEAD, the TX interrupt count.
// - RX: frames of 60..1514 bytes to the DUT's address and to broadcast (and
//   some to another address, which the filter drops) into a ring of 6
//   descriptors with random buffer sizes (checked as each completes); the buffer contents (truncated to
//   the buffer size), the write-back {done, trunc, stat, len}, RX_HEAD and
//   order are checked.
// - TX and RX traffic at the same time; frames with no free descriptor wait
//   in the FIFO (4 records) and the fifth is dropped (RX_DROP, DROP irq);
//   RX_EN off drops frames.
// - A descriptor in an SLVERR region: ERR and the ERR interrupt, CMD.clr_err.
// - Every burst's latency (first request to the last response, memory side)
//   is printed as "LAT GbE_DMA axi R|W <cycles>".
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module GbE_DMA_tb;
  `include "soc_ss_tb_common.svh"
  logic [4:0]  cfg_div = 5'd1;
  logic [47:0] cfg_mac = 48'h02_11_22_33_44_55;
  logic        cfg_promisc = 0, cfg_pause_en = 0;
  wire  [7:0]  gtxd, p_gtxd;
  wire         gtx_en, gtx_er, p_gtx_en, p_gtx_er;
  logic        tx_en = 0, rx_en = 0, clr_err = 0;
  logic [31:0] tx_base = 32'h0001_0000, rx_base = 32'h0002_0000;
  logic [15:0] tx_num = 8, rx_num = 6, tx_tail = 0, rx_tail = 0;
  wire  [15:0] tx_head, rx_head, tx_frames, rx_frames, rx_drop;
  wire         err, tx_paused, tx_irq, rx_irq, drop_irq, err_irq;
  // raw GMII frames from the TB (bad FCS, GRX_ER, PAUSE, length errors)
  // replace the partner's line while raw is set
  logic        raw = 0, raw_dv = 0, raw_er = 0;
  logic [7:0]  raw_d = 0;
  GbE_DMA_top dut (.*, .grxd(raw ? raw_d : p_gtxd), .grx_dv(raw ? raw_dv : p_gtx_en),
                   .grx_er(raw ? raw_er : p_gtx_er));

  // link partner
  logic        p_tx_valid = 0, p_tx_last = 0;
  logic [7:0]  p_tx_data = 0;
  wire         p_tx_ready, p_tx_done, p_tx_underrun, p_tx_paused;
  wire         p_rx_valid, p_rx_last, p_rx_frag;
  wire  [7:0]  p_rx_data;
  wire  [3:0]  p_rx_stat;
  Ethernet_top partner (
    .clk, .rst_n, .cfg_div, .cfg_mac(48'h02_AA_BB_CC_DD_EE), .cfg_promisc(1'b1), .cfg_pause_en(1'b0),
    .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_last(p_tx_last),
    .tx_done(p_tx_done), .tx_underrun(p_tx_underrun), .tx_paused(p_tx_paused),
    .gtxd(p_gtxd), .gtx_en(p_gtx_en), .gtx_er(p_gtx_er), .grxd(gtxd), .grx_dv(gtx_en), .grx_er(gtx_er),
    .rx_valid(p_rx_valid), .rx_data(p_rx_data), .rx_last(p_rx_last), .rx_stat(p_rx_stat), .rx_frag(p_rx_frag)
  );

  int n_tx_irq = 0, n_rx_irq = 0, n_drop_irq = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin
    n_tx_irq += tx_irq; n_rx_irq += rx_irq; n_drop_irq += drop_irq; n_err_irq += err_irq;
  end
  int t_ar = -1, t_aw = -1;
  always @(posedge clk) if (rst_n) begin
    if (m_arvalid && m_arready && t_ar < 0) t_ar = $time / 10;
    if (m_rvalid && m_rready && m_rlast && t_ar >= 0) begin $display("LAT GbE_DMA axi R %0d", $time / 10 - t_ar); t_ar = -1; end
    if (m_awvalid && m_awready && t_aw < 0) t_aw = $time / 10;
    if (m_bvalid && m_bready && t_aw >= 0) begin $display("LAT GbE_DMA axi W %0d", $time / 10 - t_aw); t_aw = -1; end
  end

  function automatic void poke_byte(input logic [31:0] a, input logic [7:0] b);
    logic [31:0] w;
    w = mem.peek({a[31:2], 2'b00}); w[8 * a[1:0] +: 8] = b; mem.poke({a[31:2], 2'b00}, w);
  endfunction
  function automatic logic [7:0] peek_byte(input logic [31:0] a);
    logic [31:0] w;
    w = mem.peek({a[31:2], 2'b00}); return w[8 * a[1:0] +: 8];
  endfunction

  // ------------------------------------------------------------ TX side
  // frames live in a byte pool; a frame is an index into fo / fl
  logic [7:0] pool [0:1048575];
  int         fo [0:4095], fl [0:4095];
  int         n_fr = 0, pool_n = 0;
  int     tx_q [$];                    // posted, not yet received by the partner
  int     tx_posted = 0, tx_seen = 0;
  // partner receive: collect frames
  logic [7:0] p_cur [$];
  bit p_ignore = 0;   // after a reset in the middle of a TX frame
  always @(posedge clk) if (rst_n && p_rx_valid && !p_ignore) begin
    p_cur.push_back(p_rx_data);
    if (p_rx_last) begin
      int e, n;
      if (tx_q.size() == 0) fail("partner received a frame nobody sent");
      else begin
        e = tx_q.pop_front();
        n = fl[e] < 60 ? 60 : fl[e];
        if (p_rx_stat[2:0] != (fl[e] > 1514 ? 3'b010 : 3'b000) && !p_ignore) fail($sformatf("partner rx_stat %b on TX frame %0d", p_rx_stat, tx_seen));
        if (p_cur.size() != n) fail($sformatf("TX frame %0d: %0d bytes, expected %0d", tx_seen, p_cur.size(), n));
        else for (int i = 0; i < n; i++)
          if (p_cur[i] !== (i < fl[e] ? pool[fo[e] + i] : 8'h00)) begin
            fail($sformatf("TX frame %0d byte %0d: %h", tx_seen, i, p_cur[i])); break;
          end
      end
      tx_seen++;
      p_cur.delete();
    end
  end
  function automatic int mk_frame(input int n, input logic [47:0] da);
    fo[n_fr] = pool_n; fl[n_fr] = n;
    for (int i = 0; i < n; i++) pool[pool_n + i] = i < 6 ? da[47 - 8 * i -: 8] : (i < 12 ? 8'(8'h02 + i) : 8'($urandom));
    pool_n += n;
    return n_fr++;
  endfunction
  task automatic post_tx(input int f);
    logic [31:0] b, d;
    int idx;
    idx = tx_tail;
    b = 32'h0010_0000 + 32'(idx) * 32'h800 + 32'(4 * ($urandom % 4));
    d = tx_base + 32'(8 * idx);
    for (int i = 0; i < fl[f]; i++) poke_byte(b + 32'(i), pool[fo[f] + i]);
    mem.poke(d, b); mem.poke(d + 4, 32'(fl[f]));
    tx_q.push_back(f); tx_posted++;
    @(negedge clk); tx_tail = (tx_tail + 1 == tx_num) ? 0 : tx_tail + 1;
  endtask
  // every completed TX descriptor: {done, len} and in order
  int tx_chk = 0;
  int tx_log [$];
  task automatic check_tx_wb(input int idx, input int len);
    logic [31:0] w;
    w = mem.peek(tx_base + 32'(8 * idx) + 4);
    if (w !== {1'b1, 15'd0, 16'(len)}) fail($sformatf("TX descriptor %0d write-back %h, len %0d", idx, w, len));
  endtask

  // ------------------------------------------------------------ RX side
  int rx_q [$];                        // sent by the partner, accepted by the filter
  logic [3:0] rx_stq [$];              // their expected rx_stat
  int     rx_size [16];
  task automatic p_send(input int f);
    for (int i = 0; i < fl[f]; i++) begin
      p_tx_valid = 1; p_tx_data = pool[fo[f] + i]; p_tx_last = (i == fl[f] - 1);
      @(posedge clk); while (!p_tx_ready) @(posedge clk);
      @(negedge clk);
    end
    p_tx_valid = 0; p_tx_last = 0;
    @(posedge clk); while (!p_tx_done) @(posedge clk);
    @(negedge clk);
  endtask
  task automatic post_rx(input int size);
    logic [31:0] d;
    int idx;
    idx = rx_tail;
    d = rx_base + 32'(8 * idx);
    mem.poke(d, 32'h0800_0000 + 32'(idx) * 32'h800); mem.poke(d + 4, 32'(size));
    rx_size[idx] = size;
    for (int i = 0; i < 2048; i += 4) mem.poke(32'h0800_0000 + 32'(idx) * 32'h800 + 32'(i), 32'hBAD0_0000);
    @(negedge clk); rx_tail = (rx_tail + 1 == rx_num) ? 0 : rx_tail + 1;
  endtask
  int rx_chk = 0, rx_hw = 0;           // frames checked, hardware head mirror
  task automatic check_rx(input int idx, input int f);
    logic [31:0] w, b;
    int sz, n;
    bit tr;
    w = mem.peek(rx_base + 32'(8 * idx) + 4);
    b = 32'h0800_0000 + 32'(idx) * 32'h800;
    sz = rx_size[idx]; tr = fl[f] > sz; n = tr ? sz : fl[f];
    if (w !== {1'b1, tr, 10'd0, rx_stq.size() ? rx_stq.pop_front() : 4'd0, 16'(fl[f])})
      fail($sformatf("RX descriptor %0d write-back %h, frame %0d bytes, buffer %0d", idx, w, fl[f], sz));
    for (int i = 0; i < n; i++)
      if (peek_byte(b + 32'(i)) !== pool[fo[f] + i]) begin fail($sformatf("RX frame %0d byte %0d: %h, expected %h", rx_chk, i, peek_byte(b + 32'(i)), pool[fo[f] + i])); break; end
    if (mem.peek(b + 32'(((n + 3) / 4) * 4)) !== 32'hBAD0_0000) fail($sformatf("RX frame %0d written past %0d bytes", rx_chk, n));
    rx_chk++;
  endtask
  // completed RX descriptors are checked as soon as RX_HEAD moves, before
  // the TB can post the entry again
  initial forever begin
    @(posedge clk); #2;
    while (rst_n && rx_hw != rx_head) begin
      if (rx_q.size() == 0) begin fail("RX descriptor completed with no frame sent"); rx_hw = rx_head; end
      else check_rx(rx_hw, rx_q.pop_front());
      rx_hw = (rx_hw + 1 == rx_num) ? 0 : rx_hw + 1;
    end
  end
  task automatic rx_collect(input int want);
    int t;
    t = 0;
    while (rx_chk < want && t < 400000) begin @(negedge clk); t++; end
    if (rx_chk < want) fail($sformatf("only %0d of %0d RX frames arrived", rx_chk, want));
  endtask

  int force_len = 0;                   // TX frame length (0: random)
  task automatic tx_burst(input int n);
    int done0, t, h;
    done0 = tx_seen;
    for (int k = 0; k < n; k++) begin
      int len;
      len = ($urandom % 4 == 0) ? 1 + $urandom % 59 : ($urandom % 8 == 0 ? 1400 + $urandom % 115 : 60 + $urandom % 300);
      if (force_len != 0) len = force_len;
      post_tx(mk_frame(len, 48'h02_AA_BB_CC_DD_EE));
      tx_log.push_back(tx_q[tx_q.size() - 1]);
    end
    t = 0;
    while (tx_seen < done0 + n && t < 2000000) begin @(negedge clk); t++; end
    if (tx_seen < done0 + n) fail($sformatf("TX: %0d of %0d frames sent", tx_seen - done0, n));
    t = 0;
    while (tx_head != tx_tail && t < 10000) begin @(negedge clk); t++; end
    if (tx_head != tx_tail) fail("TX_HEAD did not reach TX_TAIL");
    while (tx_chk < tx_posted) begin
      int f;
      f = tx_log.pop_front();
      check_tx_wb(tx_chk % tx_num, fl[f]);
      tx_chk++;
    end
  endtask

  // a TX descriptor with a length of 0 or above TXF_BYTES: not sent,
  // write-back {done, bad_len, len}
  task automatic tx_bad(input int len);
    int idx, t;
    logic [31:0] w;
    idx = tx_tail;
    mem.poke(tx_base + 32'(8 * idx), 32'h0010_0000); mem.poke(tx_base + 32'(8 * idx) + 4, 32'(len));
    @(negedge clk); tx_tail = (tx_tail + 1 == tx_num) ? 0 : tx_tail + 1;
    t = 0;
    while (tx_head != tx_tail && t < 10000) begin @(negedge clk); t++; end
    w = mem.peek(tx_base + 32'(8 * idx) + 4);
    if (w !== {1'b1, 1'b0, 1'b0, 1'b1, 12'd0, 16'(len)}) fail($sformatf("bad-length TX descriptor write-back %h", w));
    tx_chk++;
  endtask
  // raw GMII: a byte per MAC byte time
  task automatic raw_byte(input logic [7:0] b, input bit dv, input bit er);
    @(negedge clk); raw_d = b; raw_dv = dv; raw_er = er;
    while (!dut.u_mac.ls) @(negedge clk);
    @(posedge clk);
  endtask
  function automatic logic [31:0] crc_b(input logic [31:0] c, input logic [7:0] d);
    for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction
  task automatic raw_frame(input int f, input bit bad_fcs, input int er_at, input logic [3:0] stat);
    logic [31:0] c;
    rx_q.push_back(f); rx_stq.push_back(stat);
    raw = 1;
    for (int i = 0; i < 7; i++) raw_byte(8'h55, 1, 0);
    raw_byte(8'hD5, 1, 0);
    c = '1;
    for (int i = 0; i < fl[f]; i++) begin raw_byte(pool[fo[f] + i], 1, i == er_at); c = crc_b(c, pool[fo[f] + i]); end
    c = ~c ^ 32'(bad_fcs);
    for (int i = 0; i < 4; i++) raw_byte(c[8 * i +: 8], 1, 0);
    for (int i = 0; i < 12; i++) raw_byte(8'h00, 0, 0);
    raw = 0;
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(10);
    tx_en = 1; rx_en = 1;
    // TX only
    tx_burst(1);
    tx_burst(5);
    for (int k = 0; k < 4; k++) begin mem.stall = k != 2; tx_burst(1 + $urandom % 7); end
    clks(2);
    if (tx_frames != 16'(tx_posted)) fail($sformatf("TX_FRAMES %0d, expected %0d", tx_frames, tx_posted));
    if (n_tx_irq != tx_posted) fail($sformatf("%0d TX interrupts for %0d frames", n_tx_irq, tx_posted));
    // RX only: buffers first, then frames (some larger than the buffer)
    mem.stall = 1;
    for (int k = 0; k < 5; k++) post_rx(($urandom % 3 == 0) ? 64 + $urandom % 200 : 1600);
    for (int k = 0; k < 5; k++) begin
      int f;
      logic [47:0] da;
      da = (k == 2) ? 48'hFFFF_FFFF_FFFF : cfg_mac;
      f = mk_frame(60 + $urandom % 400, da);
      begin rx_q.push_back(f); rx_stq.push_back(4'd0); end p_send(f);
      if (k == 3) p_send(mk_frame(80, 48'h02_99_99_99_99_99));   // filtered out
    end
    rx_collect(5);
    // TX and RX together
    fork
      tx_burst(6);
      begin
        for (int k = 0; k < 8; k++) begin
          int f;
          post_rx(1600);
          f = mk_frame(60 + $urandom % 1455, cfg_mac);
          begin rx_q.push_back(f); rx_stq.push_back(4'd0); end p_send(f);
        end
        rx_collect(13);
      end
    join
    // no free descriptor: 4 frames wait, the fifth is dropped, then delivered
    begin
      int d0;
      d0 = rx_drop;
      for (int k = 0; k < 5; k++) begin
        int f;
        f = mk_frame(60 + $urandom % 100, cfg_mac);
        if (k < 4) begin rx_q.push_back(f); rx_stq.push_back(4'd0); end
        p_send(f);
      end
      clks(50);
      if (rx_drop != d0 + 1) fail($sformatf("RX_DROP %0d, expected %0d", rx_drop, d0 + 1));
      for (int k = 0; k < 4; k++) post_rx(1600);
      rx_collect(17);
      // RX_EN off: dropped
      rx_en = 0;
      p_send(mk_frame(70, cfg_mac));
      clks(50);
      if (rx_drop != d0 + 2) fail("a frame was not dropped with RX_EN off");
      if (n_drop_irq != 2) fail($sformatf("%0d DROP interrupts, expected 2", n_drop_irq));
      rx_en = 1;
    end
    clks(2);
    if (rx_frames != 16'(rx_chk)) fail($sformatf("RX_FRAMES %0d, expected %0d", rx_frames, rx_chk));
    if (n_rx_irq != rx_chk) fail($sformatf("%0d RX interrupts for %0d frames", n_rx_irq, rx_chk));
    // AXI error: the next TX descriptor is in an SLVERR region
    mem.err_lo = tx_base + 32'(8 * tx_tail); mem.err_hi = mem.err_lo + 8;
    @(negedge clk); tx_tail = (tx_tail + 1 == tx_num) ? 0 : tx_tail + 1;
    clks(400);
    if (!err) fail("ERR low after an SLVERR descriptor read");
    if (n_err_irq == 0) fail("no ERR interrupt");
    if (tx_head != tx_tail) fail("the bad TX descriptor was not consumed");
    mem.err_lo = '1; mem.err_hi = '1;
    clr_err = 1; @(negedge clk); clr_err = 0;
    if (err) fail("CMD.clr_err did not clear ERR");
    tx_chk++; tx_posted++;                             // skip its write-back check
    tx_burst(2);
    // every non-OKAY response code on a descriptor read and on a status write
    for (int k = 0; k < 6; k++) begin
      mem.err_resp = 2'(1 + k % 3);
      if (k < 3) begin mem.err_lo = tx_base + 32'(8 * tx_tail); mem.err_hi = mem.err_lo + 4; end
      else begin mem.err_lo = tx_base + 32'(8 * tx_tail) + 4; mem.err_hi = mem.err_lo + 4; end
      mem.poke(tx_base + 32'(8 * tx_tail) + 4, 32'd0);
      @(negedge clk); tx_tail = (tx_tail + 1 == tx_num) ? 0 : tx_tail + 1;
      clks(400);
      if (!err || tx_head != tx_tail) fail($sformatf("response %0d: ERR %b", mem.err_resp, err));
      mem.err_lo = '1; mem.err_hi = '1;
      clr_err = 1; @(negedge clk); clr_err = 0;
      tx_chk++;
    end
    mem.err_resp = 2'b10;
    mem.rand_id = 1;
    // TX: lengths 0 and above TXF_BYTES are not sent; up to TXF_BYTES is
    tx_bad(0); tx_bad(2049); tx_bad(16'hFFFF);
    force_len = 2048; tx_burst(1); force_len = 1519; tx_burst(1); force_len = 4; tx_burst(2); force_len = 0;
    // RX: frames with each error status (bad FCS, GRX_ER, too short, too
    // long), a PAUSE frame into a buffer of 0 bytes (status only); a ring of
    // NUM entries holds NUM - 1 free descriptors
    for (int k = 0; k < 5; k++) post_rx(k == 4 ? 0 : 1700);
    raw_frame(mk_frame(80, cfg_mac), 1, -1, 4'b0001);
    raw_frame(mk_frame(90, cfg_mac), 0, 30, 4'b0100);
    raw_frame(mk_frame(40, cfg_mac), 0, -1, 4'b0010);
    raw_frame(mk_frame(1600, cfg_mac), 0, -1, 4'b0010);
    begin
      int f;
      f = mk_frame(64, 48'h01_80_C2_00_00_01);
      pool[fo[f] + 12] = 8'h88; pool[fo[f] + 13] = 8'h08; pool[fo[f] + 14] = 8'h00; pool[fo[f] + 15] = 8'h01;
      pool[fo[f] + 16] = 8'h00; pool[fo[f] + 17] = 8'h02;
      cfg_pause_en = 1;
      raw_frame(f, 0, -1, 4'b1000);
    end
    rx_collect(rx_chk + rx_q.size());
    cfg_pause_en = 0;
    // no free descriptor: two 1500-byte frames wait, the third does not fit
    // in the RX FIFO and is dropped
    begin
      int d0;
      d0 = rx_drop;
      for (int k = 0; k < 3; k++) begin
        int f;
        f = mk_frame(1500, cfg_mac);
        if (k < 2) begin rx_q.push_back(f); rx_stq.push_back(4'd0); end
        p_send(f);
      end
      clks(50);
      if (rx_drop != d0 + 1) fail($sformatf("FIFO full: RX_DROP %0d, expected %0d", rx_drop, d0 + 1));
      for (int k = 0; k < 2; k++) post_rx(1600);
      rx_collect(rx_chk + rx_q.size());
    end
    if (tx_q.size() != 0) fail("TX frames left over");
    if (rx_q.size() != 0) fail("RX frames left over");
    // every bit of the ring and MAC configuration pins, while disabled
    tx_en = 0; rx_en = 0;
    @(negedge clk);
    tx_base = '1; rx_base = '1; tx_num = '1; rx_num = '1; tx_tail = '1; rx_tail = '1;
    cfg_mac = '1; cfg_div = '1; cfg_promisc = 1;
    clks(4);
    tx_base = 0; rx_base = 0; tx_num = 0; rx_num = 0; tx_tail = 0; rx_tail = 0;
    cfg_mac = 0; cfg_div = 0;
    clks(4);
    // reset in the middle of a TX frame and of an RX frame
    @(negedge clk);
    cfg_div = 1; cfg_promisc = 0; cfg_mac = 48'h02_11_22_33_44_55;
    tx_base = 32'h0001_0000; rx_base = 32'h0002_0000; tx_num = 8; rx_num = 6;
    rst_n = 0; clks(2); rst_n = 1; clks(2);
    tx_en = 1; rx_en = 1;
    mem.poke(tx_base, 32'h0010_0000); mem.poke(tx_base + 4, 32'd300);
    @(negedge clk); tx_tail = 1;
    while (!dut.tx_valid) @(negedge clk);
    clks(20);
    p_ignore = 1;
    rst_n = 0; clks(3);
    if (dut.tx_valid || tx_head != 0) fail("TX not idle in reset");
    rst_n = 1; tx_tail = 0; clks(200);
    fork p_send(mk_frame(200, cfg_mac)); join_none
    while (!dut.rx_valid) @(negedge clk);
    clks(20);
    rst_n = 0; clks(3);
    rst_n = 1;
    wait fork;
    clks(100);
    finish("GbE_DMA");
  end
  initial begin #100ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
endmodule
