// SPDX-License-Identifier: Apache-2.0
// IO_LINK_tb: a master port (M) and a device (D) on one C/Q line (wired AND
// of the drivers, 1 when nobody drives), plus a UART BFM for frames neither
// gives. Checks every message's octets in both buffers, the device reports,
// the master results, wake-up detection limits, every device and master
// error, response delay and timeout limits, lengths 0..32 and clamping, and
// reset.
`timescale 1ns/1ps
module IO_LINK_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask
  task automatic cyc(input int n); repeat (n) @(negedge clk); endtask

  // ---- shared configuration
  logic [15:0] cbit = 16, cwurq = 400;
  logic [1:0]  mtype = 0;
  logic [5:0]  pdo = 0, pdi = 0, odl = 1;
  logic [1:0]  d_mtype_x = 0;                 // XORed into the device's M-sequence type
  logic [7:0]  tmo = 20;
  logic [3:0]  ta = 2;
  logic        ev = 0, pdinv = 0;
  // ---- line
  logic        f_drv = 0, f_lvl = 1;          // BFM
  wire         m_txd, m_ten, d_txd, d_ten;
  wire         line = (m_ten ? m_txd : 1'b1) & (d_ten ? d_txd : 1'b1) & (f_drv ? f_lvl : 1'b1);
  // ---- master controls
  logic        m_wurq = 0, m_start = 0;
  logic [7:0]  m_mc = 0;

`define TERMINAL(G) \
    logic        hrd = 0, hwr = 0; \
    logic [7:0]  haddr = 0, hwd = 0, hrdat; \
    logic        busy, done, etmo, euart, ecks, wq, msg, txo, teo; \
    logic [7:0]  cks, mmc; \
    logic [6:0]  cnt; \
    logic [2:0]  why; \
    IO_LINK_top u ( \
      .clk, .rst_n, .cfg_master((G) == 0), .cfg_bit(cbit), .cfg_wurq(cwurq), \
      .cfg_mtype((G) == 0 ? mtype : mtype ^ d_mtype_x), \
      .cfg_pdout_len(pdo), .cfg_pdin_len(pdi), .cfg_od_len(odl), \
      .txd(txo), .tx_en(teo), .rxd(line), \
      .host_rd(hrd), .host_wr(hwr), .host_addr(haddr), .host_wdata(hwd), .host_rdata(hrdat), \
      .cfg_resp_timeout(tmo), .m_wurq((G) == 0 ? m_wurq : 1'b0), .m_start((G) == 0 ? m_start : 1'b0), \
      .m_mc(m_mc), .m_busy(busy), .m_done(done), .m_err_timeout(etmo), .m_err_uart(euart), \
      .m_err_cks(ecks), .m_cks(cks), .m_cnt(cnt), \
      .cfg_ta(ta), .cfg_event(ev), .cfg_pd_invalid(pdinv), \
      .d_wurq(wq), .d_msg(msg), .d_msg_mc(mmc), .d_msg_why(why)); \
    int          n_msg = 0, n_wq = 0, n_done = 0; \
    logic [7:0]  l_mc; \
    logic [2:0]  l_why; \
    always @(negedge clk) begin \
      if (msg) begin n_msg++; l_mc = mmc; l_why = why; end \
      if (wq) n_wq++; \
      if (done) n_done++; \
    end
  if (1) begin : M
`TERMINAL(0)
  end
  if (1) begin : D
`TERMINAL(1)
  end
  assign m_txd = M.txo;  assign m_ten = M.teo;
  assign d_txd = D.txo;  assign d_ten = D.teo;

  // ---- checksum model
  function automatic logic [5:0] comp(input logic [7:0] x);
    return {x[7] ^ x[5] ^ x[3] ^ x[1], x[6] ^ x[4] ^ x[2] ^ x[0], x[7] ^ x[6], x[5] ^ x[4],
            x[3] ^ x[2], x[1] ^ x[0]};
  endfunction
  function automatic int lim(input int n);
    return n > 32 ? 32 : n;
  endfunction

  // ---- buffers
  task automatic fill(input int g, input logic [7:0] a, input int n);
    for (int k = 0; k < n; k++)
      if (g == 0) M.u.ram[a + 8'(k)] = 8'($urandom); else D.u.ram[a + 8'(k)] = 8'($urandom);
  endtask
  function automatic logic [7:0] rdm(input int g, input logic [7:0] a);
    return g == 0 ? M.u.ram[a] : D.u.ram[a];
  endfunction
  task automatic cmp(input string what, input int g, input logic [7:0] a, input int h, input logic [7:0] b, input int n);
    int bad;
    bad = -1;
    for (int k = 0; k < n; k++) if (bad < 0 && rdm(g, a + 8'(k)) !== rdm(h, b + 8'(k))) bad = k;
    if (bad >= 0) fail($sformatf("%s: octet %0d %h != %h", what, bad, rdm(g, a + 8'(bad)), rdm(h, b + 8'(bad))));
  endtask

  // ---- master request
  logic [3:0] r_err;          // {timeout, uart, cks, 0}
  logic [7:0] r_cks;
  logic [6:0] r_cnt;
  int         base_msg;
  // reply delay: clocks from the master's last tx_en clock to the device's first
  // and from m_start to the master's first start bit
  int          t_clk = 0, t_mend = 0, t_gap = -1, t_mst = 0, t_lat = -1;
  bit          d_teo_q = 0, m_txo_q = 1;
  always @(negedge clk) begin
    t_clk++;
    if (m_start) begin t_mst = t_clk; t_lat = -1; end
    if (M.teo && !M.txo && m_txo_q && t_lat < 0) t_lat = t_clk - t_mst;
    if (M.teo) t_mend = t_clk;
    if (D.teo && !d_teo_q) t_gap = t_clk - t_mend;
    d_teo_q = D.teo; m_txo_q = !M.teo || M.txo;
  end
  task automatic m_req(input logic [7:0] mc);
    int k;
    base_msg = D.n_msg;
    @(negedge clk); m_mc = mc; m_start = 1;
    @(negedge clk) m_start = 0;
    k = 0;
    while (!M.done && k < 10000000) begin @(negedge clk); k++; end
    if (!M.done) fail("M: no m_done");
    if (M.busy) fail("M: busy with m_done");
    r_err = {M.etmo, M.euart, M.ecks, 1'b0}; r_cks = M.cks; r_cnt = M.cnt;
    cyc(4 * cbit);
  endtask
  task automatic m_expect(input string what, input logic [3:0] err, input int cnt = -1);
    if (r_err !== err) fail($sformatf("%s: M errors %b, expected %b", what, r_err, err));
    if (cnt >= 0 && r_cnt !== 7'(cnt)) fail($sformatf("%s: M received %0d octets, expected %0d", what, r_cnt, cnt));
  endtask
  task automatic d_expect(input string what, input logic [7:0] mc, input int why);
    if (D.n_msg != base_msg + 1) fail($sformatf("%s: D reported %0d messages", what, D.n_msg - base_msg));
    else if (D.l_mc !== mc || D.l_why !== 3'(why)) fail($sformatf("%s: D report mc %h why %0d", what, D.l_mc, D.l_why));
  endtask
  // a whole good exchange: buffers on both sides, reports, CKS
  task automatic xfer(input string what, input logic [7:0] mc);
    int no, np, ni;
    logic [7:0] e;
    no = lim(odl); np = lim(pdo); ni = lim(pdi);
    fill(0, 8'h00, np); fill(0, 8'h20, no); fill(1, 8'h00, ni); fill(1, 8'h20, no); fill(1, 8'h80, 32);
    m_req(mc);
    m_expect(what, 0, (mc[7] ? no : 0) + ni + 1);
    d_expect(what, mc, 0);
    // the device starts tA bit times (0 acts as 1) after the middle of the
    // master's last stop bit, plus 6 clocks of line and register latency
    if (t_gap != (ta == 0 ? 1 : ta) * cbit - (cbit + 1) / 2 + 6)
      fail($sformatf("%s: reply %0d clocks after the master's last octet", what, t_gap));
    cmp({what, " PD out"}, 0, 8'h00, 1, 8'h40, np);
    cmp({what, " PD in"}, 1, 8'h00, 0, 8'h40, ni);
    if (!mc[7]) cmp({what, " OD write"}, 0, 8'h20, 1, 8'h60, no);
    else if (mc[6:5] != 2'd1) cmp({what, " OD read"}, 1, 8'h20, 0, 8'h60, no);
    else for (int k = 0; k < no; k++)
      if (M.u.ram[8'h60 + 8'(k)] !== D.u.ram[{3'b100, 5'(mc[4:0] + 5'(k))}]) fail($sformatf("%s: page octet %0d", what, k));
    e = {ev, pdinv, 6'd0};
    if (r_cks[7:6] !== e[7:6]) fail($sformatf("%s: CKS %h", what, r_cks));
  endtask

  // ---- UART BFM
  task automatic f_bit(input logic b, input int n = 1);
    f_drv = 1; f_lvl = b;
    repeat (n * cbit) @(posedge clk);
  endtask
  // one octet; perr flips parity, ferr makes the stop bit 0
  task automatic f_oct(input logic [7:0] d, input bit perr = 0, input bit ferr = 0);
    f_bit(0);
    for (int i = 0; i < 8; i++) f_bit(d[i]);
    f_bit(^d ^ perr);
    f_bit(!ferr);
    f_drv = 0;
  endtask
  task automatic f_low(input int clocks);
    @(posedge clk); f_drv = 1; f_lvl = 0;
    repeat (clocks) @(posedge clk);
    f_drv = 0;
  endtask
  task automatic f_gap(input int bits);
    f_drv = 0; repeat (bits * cbit) @(posedge clk);
  endtask
  // a master message from the BFM; ck_x flips checksum bits
  task automatic f_msg(input logic [7:0] mc, input logic [1:0] ty, input logic [7:0] pl [], input logic [5:0] ck_x = 0);
    logic [7:0] x;
    x = 8'h52 ^ mc ^ {ty, 6'd0};
    foreach (pl[i]) x ^= pl[i];
    f_oct(mc); f_oct({ty, comp(x) ^ ck_x});
    foreach (pl[i]) f_oct(pl[i]);
  endtask
  // a device reply from the BFM: wait for the master's message to end first
  task automatic f_reply(input logic [7:0] pl [], input logic [1:0] st, input int gap0, input logic [5:0] ck_x = 0,
                         input int bad = -1);
    logic [7:0] x;
    @(negedge clk); while (!M.u.tx_en) @(negedge clk);
    while (M.u.tx_en) @(negedge clk);
    f_gap(gap0);
    x = 8'h52 ^ {st, 6'd0};
    foreach (pl[i]) begin x ^= pl[i]; f_oct(pl[i], i == bad); end
    f_oct({st, comp(x) ^ ck_x});
  endtask

  initial begin
    logic [7:0] pl [];
    int b0;
    cyc(3); rst_n = 1; cyc(5);

    // ---- 1. TYPE_0: page read / write, ISDU and diagnosis channels
    $display("[%0t] 1. TYPE_0", $time);
    mtype = 0; pdo = 0; pdi = 0; odl = 1;
    xfer("page read", 8'b1_01_00011);
    xfer("page read 31", 8'b1_01_11111);
    xfer("page write", 8'b0_01_00101);
    xfer("ISDU read", 8'b1_11_10000);
    xfer("diag write", 8'b0_10_00001);
    // m_start while busy: ignored
    fill(1, 8'h80, 32);
    fork
      m_req(8'b1_01_00100);
      begin
        @(negedge clk); while (!M.u.tx_en) @(negedge clk);
        cyc(5 * cbit);
        m_mc = 8'h00; m_start = 1; @(negedge clk) m_start = 0;
      end
    join
    m_expect("start while busy", 0, 2);
    if (M.u.ram[8'h60] !== D.u.ram[8'h84]) fail("start while busy: page octet");
    // ---- 2. TYPE_2_x with PD both ways, process channel
    $display("[%0t] 2. TYPE_2", $time);
    mtype = 2; pdo = 2; pdi = 3; odl = 1;
    xfer("T2 read", 8'b1_00_00000);
    xfer("T2 write", 8'b0_00_00001);
    ev = 1; xfer("T2 event", 8'b1_00_00010);
    pdinv = 1; xfer("T2 event + PD invalid", 8'b1_00_00010);
    ev = 0; xfer("T2 PD invalid", 8'b0_11_00010);
    pdinv = 0;
    // ---- 3. lengths: largest, clamped, zero
    $display("[%0t] 3. lengths", $time);
    mtype = 1; pdo = 32; pdi = 32; odl = 32;
    xfer("32 read", 8'b1_01_00111);
    xfer("32 write", 8'b0_11_00000);
    pdo = 63; pdi = 40; odl = 33;
    xfer("clamped read", 8'b1_10_11000);
    xfer("clamped write", 8'b0_01_00000);
    pdo = 28; pdi = 13; odl = 29;
    xfer("28 / 13 / 29 read", 8'b1_01_01010);
    pdi = 21;
    xfer("28 / 21 / 29 write", 8'b0_00_00011);
    pdo = 0; pdi = 0; odl = 0;
    xfer("empty read", 8'b1_00_00000);
    xfer("empty write", 8'b0_00_00000);
    mtype = 3; pdo = 1; pdi = 0; odl = 2;
    xfer("T3 read", 8'b1_01_11110);
    pdo = 0; pdi = 1;
    xfer("T3 write", 8'b0_01_11110);

    // ---- 4. bit times and response delays
    $display("[%0t] 4. timing", $time);
    mtype = 0; pdo = 0; pdi = 0; odl = 1;
    cbit = 4; xfer("4 clocks a bit", 8'hA1);
    cbit = 17; xfer("17 clocks a bit", 8'hA2);
    cbit = 300; tmo = 3; ta = 1; xfer("300 clocks a bit", 8'hA3);
    cbit = 16'hFFFF; tmo = 8'hE0; xfer("65535 clocks a bit", 8'hA8);
    cbit = 16; tmo = 20;
    ta = 0; xfer("tA 0", 8'hA4);
    ta = 15; xfer("tA 15", 8'hA5);
    ta = 15; tmo = 14; m_req(8'hA6); m_expect("tA 15, timeout 14", 4'b1000, 0);
    cyc(40 * cbit);
    tmo = 15; xfer("tA 15, timeout 15", 8'hA7);
    ta = 2; tmo = 20;

    // ---- 5. wake-up
    $display("[%0t] 5. wake-up", $time);
    b0 = D.n_wq;
    @(negedge clk) m_wurq = 1; @(negedge clk) m_wurq = 0;
    while (!M.done) @(negedge clk);
    if (M.busy || M.etmo || M.euart || M.ecks) fail("WURQ: m_done flags");
    cyc(20);
    if (D.n_wq != b0 + 1) fail("WURQ not detected");
    if (D.n_msg != base_msg + 1) fail("WURQ: the break octet was reported");
    f_low(400 - 25 - 1); cyc(50);  if (D.n_wq != b0 + 1) fail("WURQ: 374 clocks accepted");
    f_low(400 - 25);     cyc(50);  if (D.n_wq != b0 + 2) fail("WURQ: 375 clocks not accepted");
    f_low(400 + 25);     cyc(50);  if (D.n_wq != b0 + 3) fail("WURQ: 425 clocks not accepted");
    f_low(400 + 25 + 1); cyc(50);  if (D.n_wq != b0 + 3) fail("WURQ: 426 clocks accepted");
    cwurq = 0; f_low(1); cyc(50); if (D.n_wq != b0 + 3) fail("WURQ with cfg_wurq 0");
    cwurq = 16'hFFFF;
    @(negedge clk) m_wurq = 1; @(negedge clk) m_wurq = 0;
    while (!M.done) @(negedge clk);
    cyc(20); if (D.n_wq != b0 + 4) fail("WURQ of 65535 clocks");
    b0 = b0 + 1;
    f_low(70000); cyc(50); if (D.n_wq != b0 + 4) fail("WURQ: saturated counter");
    cwurq = 400;
    cyc(40 * cbit);
    // a wake-up while the device waits tA: no reply
    cwurq = 40; ta = 15;
    pl = new[0];
    fork m_req(8'hB0); begin f_gap(5); while (M.u.tx_en) @(negedge clk); f_gap(3); f_low(40); end join
    m_expect("wake-up in tA", 4'b1000, 1);                   // the master takes the pulse for an octet
    if (D.n_wq != b0 + 5) fail("WURQ in tA not detected");
    cwurq = 400; ta = 2;
    cyc(40 * cbit);
    xfer("after wake-up", 8'hB1);
    // a wake-up in the middle of a message restarts the device
    b0 = D.n_msg;
    f_oct(8'hB2); f_low(400); f_gap(20);
    if (D.n_msg != b0) fail("WURQ in a message: reported");
    xfer("after wake-up in a message", 8'hB3);

    // ---- 6. device errors (BFM as master)
    $display("[%0t] 6. device errors", $time);
    mtype = 2; pdo = 2; pdi = 1; odl = 1;
    pl = new[3]; pl[0] = 8'h11; pl[1] = 8'h22; pl[2] = 8'h33;
    b0 = D.n_msg;
    f_msg(8'h20, 2, pl); f_gap(40);                               // write: 2 PD + 1 OD
    if (D.n_msg != b0 + 1 || D.l_why != 0) fail("BFM message not taken");
    if (D.u.ram[8'h40] !== 8'h11 || D.u.ram[8'h41] !== 8'h22 || D.u.ram[8'h60] !== 8'h33) fail("BFM message stored");
    f_msg(8'h20, 2, pl, 6'h01); f_gap(40);
    if (D.n_msg != b0 + 2 || D.l_why != 2) fail("checksum error not reported");
    f_msg(8'h20, 1, pl); f_gap(40);
    if (D.n_msg != b0 + 3 || D.l_why != 3) fail("M-sequence type error not reported");
    f_oct(8'h20); f_oct(8'h80, 1); f_oct(8'h11); f_oct(8'h22); f_gap(40);
    if (D.n_msg != b0 + 4 || D.l_why != 1 || D.l_mc !== 8'h20) fail("parity error not reported");
    f_oct(8'h21, 0, 1); f_oct(8'h80); f_gap(40);
    if (D.n_msg != b0 + 5 || D.l_why != 1 || D.l_mc !== 8'h21) fail("framing error not reported");
    f_oct(8'h22); f_oct(8'h80); f_gap(17);
    if (D.n_msg != b0 + 6 || D.l_why != 4 || D.l_mc !== 8'h22) fail("gap not reported");
    f_oct(8'h23); f_oct(8'h80); f_gap(15); f_oct(8'h44); f_gap(15);  // 15 bit times: still one message
    if (D.n_msg != b0 + 6) fail("15-bit gap reported");
    f_oct(8'h55); f_oct(8'h66); f_gap(40);
    if (D.n_msg != b0 + 7 || D.l_why != 2) fail("message with gaps: checksum");
    // after an error, octets are dropped until 16 idle bit times
    f_oct(8'h20, 1); f_gap(15); f_msg(8'h20, 2, pl); f_gap(40);
    if (D.n_msg != b0 + 8) fail("octets after an error not dropped");
    f_oct(8'h20, 1); f_gap(17); f_msg(8'h20, 2, pl); f_gap(40);
    if (D.n_msg != b0 + 10 || D.l_why != 0) fail("message after the drop time not taken");
    // a low glitch shorter than half a bit is no start bit: the message right after it is taken
    f_low(2); f_gap(1); f_msg(8'h20, 2, pl); f_gap(40);
    if (D.n_msg != b0 + 11 || D.l_why != 0) fail("message after a start-bit glitch");
    // break octet (a long low that is no wake-up): ignored
    f_low(16 * 12); f_gap(20);
    if (D.n_msg != b0 + 11) fail("break octet reported");
    // a device read is answered after tA
    pl = new[2]; pl[0] = 8'h01; pl[1] = 8'h02;
    f_msg(8'hA0, 2, pl); f_gap(40);
    if (D.n_msg != b0 + 12 || D.l_why != 0) fail("BFM read not taken");

    // ---- 7. master errors (BFM as device)
    $display("[%0t] 7. master errors", $time);
    d_mtype_x = 2'b11;                                             // D answers nothing
    mtype = 0; pdo = 0; pdi = 1; odl = 1;
    pl = new[2]; pl[0] = 8'h5A; pl[1] = 8'hC3;
    fork m_req(8'h81); f_reply(pl, 2'b00, 3); join
    m_expect("BFM reply", 0, 3);
    if (M.u.ram[8'h60] !== 8'h5A || M.u.ram[8'h40] !== 8'hC3) fail("BFM reply stored");
    fork m_req(8'h81); f_reply(pl, 2'b11, 3); join
    m_expect("BFM reply flags", 0, 3);
    if (r_cks[7:6] !== 2'b11) fail("CKS flags");
    fork m_req(8'h81); f_reply(pl, 2'b00, 3, 6'h20); join
    m_expect("reply checksum", 4'b0010, 3);
    fork m_req(8'h81); f_reply(pl, 2'b00, 3, 0, 1); join
    m_expect("reply parity", 4'b0100, 2);
    m_req(8'h81); m_expect("no reply", 4'b1000, 0);
    tmo = 8'hE0; m_req(8'h81); m_expect("no reply in 224 bit times", 4'b1000, 0); tmo = 20;
    tmo = 6;
    fork m_req(8'h81); f_reply(pl, 2'b00, 5); join
    m_expect("reply 5 bits late", 0, 3);
    fork m_req(8'h81); f_reply(pl, 2'b00, 6); join
    m_expect("reply 6 bits late", 4'b1000, 0);
    cyc(40 * cbit);
    fork
      m_req(8'h81);
      begin
        @(negedge clk); while (!M.u.tx_en) @(negedge clk);
        while (M.u.tx_en) @(negedge clk);
        f_gap(2); f_oct(8'h5A); f_gap(7); f_oct(8'hC3);
      end
    join
    m_expect("gap in the reply", 4'b1000, 1);
    tmo = 20; d_mtype_x = 0;
    cyc(40 * cbit);

    // ---- 8. host port: reads, writes, collision with a received octet
    $display("[%0t] 8. host port", $time);
    for (int k = 0; k < 8; k++) begin
      @(negedge clk) D.hwr = 1; D.haddr = 8'(8'hA0 + k); D.hwd = 8'(k * 37);
    end
    @(negedge clk) D.hwr = 0;
    for (int k = 0; k < 8; k++) begin
      @(negedge clk) D.hrd = 1; D.haddr = 8'(8'hA0 + k);
      @(negedge clk) D.hrd = 0;
      if (D.hrdat !== 8'(k * 37)) fail($sformatf("host read %0d", k));
    end
    mtype = 2; pdo = 2; pdi = 1; odl = 1;
    fill(0, 8'h00, 2); fill(0, 8'h20, 1);
    fork
      m_req(8'h00);
      begin                                                         // write 0x41 as PD out octet 1 lands
        @(negedge clk); while (!(D.u.mem_wr && D.u.mem_waddr == 8'h41)) @(negedge clk);
        D.hwr = 1; D.haddr = 8'h41; D.hwd = ~M.u.ram[8'h01];
        @(negedge clk) D.hwr = 0;
      end
    join
    if (D.u.ram[8'h41] !== M.u.ram[8'h01]) fail("collision: host write won");
    @(negedge clk) D.hrd = 1; D.haddr = 8'h41;
    @(negedge clk) D.hrd = 0;
    if (D.hrdat !== M.u.ram[8'h01]) fail("host read after collision");
    for (int k = 0; k < 256; k++) begin
      @(negedge clk) M.hwr = 1; M.haddr = 8'(k); M.hwd = 8'(k ^ 8'hFF);
    end
    @(negedge clk) M.hwr = 0;
    for (int k = 0; k < 256; k += 51) begin
      @(negedge clk) M.hrd = 1; M.haddr = 8'(k);
      @(negedge clk) M.hrd = 0;
      if (M.hrdat !== 8'(k ^ 8'hFF)) fail($sformatf("M host read %0d", k));
    end

    // ---- 9. reset in the middle of a message
    $display("[%0t] 9. reset", $time);
    mtype = 1; pdo = 32; pdi = 32; odl = 32;
    fill(1, 8'h00, 32);
    @(negedge clk) m_mc = 8'h80; m_start = 1;
    @(negedge clk) m_start = 0;
    while (!D.u.tx_en) @(negedge clk);                        // the device is answering
    cyc(100 * cbit);
    rst_n = 0;
    cyc(3);
    if (M.u.tx_en || D.u.tx_en || M.busy || M.done || D.wq || D.msg || M.u.txd !== 1'b1)
      fail("outputs in reset");
    m_start = 0;
    cyc(3); rst_n = 1; cyc(10);
    xfer("after reset", 8'h80);
    if (t_lat > 3 * cbit) fail($sformatf("first message after reset started %0d clocks after m_start", t_lat));

    if (errors == 0) $display("TEST PASSED: IO_LINK");
    else $display("TEST FAILED: IO_LINK (%0d errors)", errors);
    $finish;
  end
  initial begin
    #500ms;
    $display("TEST FAILED: IO_LINK (timeout)");
    $finish;
  end
endmodule
