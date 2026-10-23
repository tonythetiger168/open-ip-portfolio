// IP part of WTB_apb_tb: the other stations of the core TB on a looped-back
// bus (rx_bit = tx_en ? tx_bit : peer_bit) and a monitor decoding every frame
// the station sends. TXF pushes, NS / DA / CTRL writes, RXF pops and STATUS
// reads through APB against a model: token passes, data frames per hold and
// the hold window, RX delivery with padding, FIFO overflows, bad frames,
// claim_token outcomes, a MYADDR change; every event in IRQ_STATUS.EVT
// (masked and on the irq pin); PRESETN mid-hold.
  localparam int MAX_FR = 4;
  logic peer_bit = 1'b1;
  assign rx_bit = tx_en ? tx_bit : peer_bit;
  task automatic check(input logic cond, input string msg);
    if (!cond) fail(msg);
  endtask

  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    c = crc ^ {data, 8'h00};
    for (int i = 0; i < 8; i++)
      c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction

  // ------------------------------------------------------------------
  // monitor: decode every frame the station sends
  // ------------------------------------------------------------------
  logic [7:0]  mbuf [0:31];
  logic [7:0]  mon_fc [0:255], mon_da [0:255], mon_len [0:255];
  logic [31:0] mon_w [0:255];
  int          mon_cnt = 0, mon_rd = 0;
  int          mbits = 0;
  logic        irq_seen = 0;
  logic [7:0]  mcur;

  always @(posedge dut.c_irq) irq_seen = 1;

  always @(negedge PCLK) begin
    logic [15:0] c;
    int n;
    if (!PRESETN) mbits = 0;
    else if (tx_en) begin
      mcur = {mcur[6:0], tx_bit};
      mbits++;
      if (mbits % 8 == 0 && mbits <= 256) mbuf[mbits / 8 - 1] = mcur;
    end else begin
      check(tx_bit == 1'b1, "idle tx_bit is 1");
      if (mbits != 0) begin
        n = mbits / 8;
        check(mbits % 8 == 0, "whole bytes");
        check(n >= 10 && mbuf[0] == 8'h55 && mbuf[1] == 8'h55 && mbuf[2] == 8'hD5,
              "preamble and SD");
        check(n == 10 + mbuf[6] && mbuf[n-1] == 8'hD4, "length and ED");
        check(mbuf[5] == dut.c_my_addr, "SA is dut.c_my_addr");
        c = 16'hFFFF;
        for (int i = 3; i < n - 3; i++) c = crc16_byte(c, mbuf[i]);
        check(c == {mbuf[n-3], mbuf[n-2]}, "frame CRC");
        mon_fc[mon_cnt[7:0]]  = mbuf[3];
        mon_da[mon_cnt[7:0]]  = mbuf[4];
        mon_len[mon_cnt[7:0]] = mbuf[6];
        mon_w[mon_cnt[7:0]]   = {mbuf[7], mbuf[8], mbuf[9], mbuf[10]};
        mon_cnt++;
        mbits = 0;
      end
    end
  end

  // ------------------------------------------------------------------
  // expected TX words / RX words
  // ------------------------------------------------------------------
  logic [31:0] txq [0:255];
  int          txq_wr = 0, txq_rd = 0;
  logic [31:0] rxq [0:255];
  int          rxq_wr = 0, rxq_rd = 0;


  logic [31:0] wfix = 0;
  logic        wfix_en = 0;
  task automatic push_words(input int n);
    logic [31:0] w;
    for (int i = 0; i < n; i++) begin
      w = wfix_en ? wfix : $urandom;
      if (dut.c_fifo_count != 8) begin txq[txq_wr[7:0]] = w; txq_wr++; end
      wr(A_TXF, w);
    end
  endtask
  task automatic ctrl(input logic claim, input int win);
    wr(A_CTRL, {$urandom} & 32'hFE00_0000 | (win << 8) | {31'd0, claim});
  endtask
  task automatic rx_pop(input int n);
    for (int i = 0; i < n; i++) begin
      rd_exp(A_RXF, rxq[rxq_rd[7:0]]);
      rxq_rd++;
    end
  endtask
  task automatic status_exp(input int f, input int r, input bit t);
    rd_exp(A_STATUS, {23'h0, t, 4'(r), 4'(f)});
  endtask
  // EVT latched; w1c clears it; the pin follows the enable
  task automatic evt(input bit en, input string m);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_EVT);
    if (irq !== en) fail({m, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_EVT);
    rd_exp(A_IRQ_STATUS, 0);
  endtask
  // ------------------------------------------------------------------
  // peer stations on the bus
  // ------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      @(negedge PCLK);
      peer_bit = b[i];
    end
  endtask

  // mode: 0 good, 1 bad CRC, 2 bad ED, 3 bad CRC and ED
  logic [7:0] pl [0:15];
  task automatic send_frame(input logic [7:0] fc, da, sa, len, input int mode);
    logic [15:0] c;
    logic [31:0] w;
    int nb;
    nb = (len > 16) ? 0 : len;
    for (int i = 0; i < 16; i++) pl[i] = $urandom;
    c = 16'hFFFF;
    c = crc16_byte(c, fc);
    c = crc16_byte(c, da);
    c = crc16_byte(c, sa);
    c = crc16_byte(c, len);
    for (int i = 0; i < nb; i++) c = crc16_byte(c, pl[i]);
    if (mode[0]) c = c ^ (16'h1 << ($urandom % 16));
    send_byte(8'h55); send_byte(8'h55); send_byte(8'hD5);
    send_byte(fc); send_byte(da); send_byte(sa); send_byte(len);
    if (len <= 16) begin
      for (int i = 0; i < nb; i++) send_byte(pl[i]);
      send_byte(c[15:8]); send_byte(c[7:0]);
      send_byte(mode[1] ? 8'hD4 ^ (8'h1 << ($urandom % 8)) : 8'hD4);
      // expected delivery
      if (mode == 0 && fc == 8'h02 && (da == dut.c_my_addr || da == 8'hFF) && sa != dut.c_my_addr)
        for (int k = 0; k < (nb + 3) / 4; k++) begin
          w = 0;
          for (int j = 0; j < 4; j++) if (4 * k + j < nb) w[8 * (3 - j) +: 8] = pl[4 * k + j];
          rxq[rxq_wr[7:0]] = w; rxq_wr++;
        end
    end
    @(negedge PCLK); peer_bit = 1'b1;
    repeat (4) @(negedge PCLK);
  endtask

  task automatic noise(input int n);
    for (int i = 0; i < n; i++) begin @(negedge PCLK); peer_bit = $urandom; end
    @(negedge PCLK); peer_bit = 1'b1;
  endtask

  // wait until the station has sent n more frames (bounded)
  task automatic wait_frames(input int n, input string tag);
    int to;
    to = 0;
    while (mon_cnt < mon_rd + n && to < 20000) begin @(negedge PCLK); to++; end
    check(mon_cnt >= mon_rd + n, {tag, ": frames sent"});
  endtask

  task automatic expect_frame(input logic [7:0] fc, da, input string tag);
    wait_frames(1, tag);
    check(mon_fc[mon_rd[7:0]] == fc, {tag, ": FC"});
    check(mon_da[mon_rd[7:0]] == da, {tag, ": DA"});
    if (fc == 8'h02) begin
      check(mon_len[mon_rd[7:0]] == 4, {tag, ": data LEN"});
      check(mon_w[mon_rd[7:0]] == txq[txq_rd[7:0]], {tag, ": data word"});
      txq_rd++;
    end else check(mon_len[mon_rd[7:0]] == 0, {tag, ": LEN 0"});
    mon_rd++;
  endtask

  // give the station the token and check the hold: nd data frames, then
  // the token to ns
  task automatic token_round(input logic [7:0] ns, da, input int nd, input string tag);
    send_frame(8'h01, dut.c_my_addr, 8'h05, 8'h00, 0);
    for (int i = 0; i < nd; i++) expect_frame(8'h02, da, tag);
    expect_frame(8'h01, ns, tag);
    repeat (4) @(negedge PCLK);
    check(!dut.c_token_held, {tag, ": token released"});
  endtask


  logic [7:0] ns, da;
  task automatic ip_func;
    rd_exp(A_FLAGS, 0);
    status_exp(0, 0, 0);
    rd_exp(A_MYADDR, 32'h11);
    rd_exp(A_NS, 0); rd_exp(A_DA, 0); rd_exp(A_CTRL, 0); rd_exp(A_TXF, 0);   // write-only
    wr(A_RXF, $urandom);                                                     // read-only: ignored
    apb(1, A_NS, 32'h44, 4'h1);
    if (!rerr) fail("no PSLVERR on a partial core write");
    mon_rd = mon_cnt;

    // ---- configuration ----
    ns = 8'h22; da = 8'h33;
    wr(A_NS, {$urandom} & 32'hFFFF_FF00 | ns);
    wr(A_DA, {$urandom} & 32'hFFFF_FF00 | da);
    ctrl(0, 511);

    // ---- token with an empty FIFO: EVT (token acquired, masked) ----
    token_round(ns, da, 0, "empty pass");
    evt(0, "token acquired");

    // ---- data frames, MAX_FR per hold, TX overflow on the irq pin ----
    push_words(3);
    status_exp(3, 0, 0);
    token_round(ns, da, 3, "three frames");
    status_exp(0, 0, 0);
    wr(A_IRQ_STATUS, 1 << IRQ_EVT);
    wr(A_IRQ_ENABLE, 1 << IRQ_EVT);
    push_words(8);
    status_exp(8, 0, 0);
    rd_exp(A_IRQ_STATUS, 0);
    push_words(1);                       // overflow write
    status_exp(8, 0, 0);
    evt(1, "tx overflow");
    // token held: STATUS.TOKEN_HELD while the frames go out
    send_frame(8'h01, dut.c_my_addr, 8'h05, 8'h00, 0);
    repeat (30) @(negedge PCLK);
    rd(A_STATUS);
    if (!rdv[8]) fail("STATUS.TOKEN_HELD while holding");
    for (int i = 0; i < MAX_FR; i++) expect_frame(8'h02, da, "max frames");
    wait (tx_en);                                    // the token pass goes out:
    rd(A_STATUS);                                    // still held until it ends
    if (!rdv[8]) fail("STATUS.TOKEN_HELD during the token pass");
    expect_frame(8'h01, ns, "max frames");
    repeat (4) @(negedge PCLK);
    status_exp(4, 0, 0);
    wr(A_IRQ_STATUS, 1 << IRQ_EVT);
    wr(A_IRQ_ENABLE, 0);
    ns = 8'hDD; da = 8'hCC;
    wr(A_NS, ns); wr(A_DA, da);
    token_round(ns, da, MAX_FR, "max frames 2");

    // ---- hold window ----
    push_words(8);
    ctrl(0, 0);
    token_round(ns, da, 0, "window 0");
    ctrl(0, 150);
    token_round(ns, da, 2, "window 150");
    ctrl(0, 100);
    token_round(ns, da, 1, "window 100");
    ctrl(0, 511);
    token_round(ns, da, 4, "rest");
    status_exp(1, 0, 0);
    token_round(ns, da, 1, "last");
    wr(A_IRQ_STATUS, 1 << IRQ_EVT);

    // ---- RX delivery ----
    for (int l = 0; l <= 16; l++) begin
      send_frame(8'h02, (l % 3 == 0) ? 8'hFF : dut.c_my_addr, 8'(8'h20 + l), 8'(l), 0);
      repeat (6) @(negedge PCLK);
      status_exp(0, rxq_wr - rxq_rd, 0);
      rx_pop(rxq_wr - rxq_rd);
    end
    rd_exp(A_IRQ_STATUS, 0);
    // bad frames: EVT, nothing delivered
    send_frame(8'h02, dut.c_my_addr, 8'h05, 8'd8, 1);
    evt(0, "bad CRC");
    send_frame(8'h02, dut.c_my_addr, 8'h05, 8'd8, 2);
    evt(0, "bad ED");
    send_frame(8'h02, dut.c_my_addr, 8'h05, 8'd17, 0);
    evt(0, "overlong");
    send_frame(8'h02, 8'h44, 8'h05, 8'd8, 0);              // not for me
    send_frame(8'h02, dut.c_my_addr, dut.c_my_addr, 8'd8, 0);  // own frame
    repeat (6) @(negedge PCLK);
    status_exp(0, 0, 0);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- RX FIFO overflow; every RXF bit both ways ----
    for (int i = 0; i < 2; i++) send_frame(8'h02, dut.c_my_addr, 8'h05, 8'd16, 0);
    repeat (6) @(negedge PCLK);
    status_exp(0, 8, 0);
    send_frame(8'h02, 8'hFF, 8'h05, 8'd16, 0);
    evt(0, "rx overflow");
    rxq_wr = rxq_wr - 4;
    rx_pop(8);
    for (int r = 0; r < 2; r++) begin
      wfix_en = 1; wfix = r ? '0 : '1;
      push_words(4);
      wfix_en = 0;
      token_round(ns, da, 4, "soak");
      for (int i = 0; i < 2; i++) send_frame(8'h02, dut.c_my_addr, 8'h05, 8'd16, 0);
      repeat (6) @(negedge PCLK);
      rx_pop(8);
    end
    wr(A_IRQ_STATUS, 1 << IRQ_EVT);

    // ---- MYADDR change ----
    wr(A_MYADDR, 32'hEE);
    send_frame(8'h02, 8'hEE, 8'h05, 8'd4, 0);
    repeat (6) @(negedge PCLK);
    rx_pop(1);
    push_words(1);
    token_round(ns, da, 1, "new address");
    wr(A_MYADDR, 32'h11);
    wr(A_IRQ_STATUS, 1 << IRQ_EVT);

    // ---- claim token ----
    ctrl(1, 511);
    expect_frame(8'h00, 8'hFF, "claim");
    wait (dut.c_token_held);
    expect_frame(8'h01, ns, "claim won");
    evt(0, "claim won");
    expect_frame(8'h00, 8'hFF, "claim 2");
    send_frame(8'h00, 8'hFF, 8'h03, 8'h00, 0);           // lower address: back off
    repeat (5) @(negedge PCLK);
    status_exp(0, 0, 0);
    ctrl(0, 511);
    repeat (400) @(negedge PCLK);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- PRESETN mid-hold ----
    push_words(4);
    send_frame(8'h01, dut.c_my_addr, 8'h05, 8'h00, 0);
    repeat (30) @(negedge PCLK);
    rd(A_STATUS);
    if (!rdv[8] || rdv[3:0] == 0) fail("holding with words queued");
    PRESETN = 0; peer_bit = 1;
    repeat (3) @(negedge PCLK);
    check(!tx_en && tx_bit && !irq, "PRESETN outputs");
    PRESETN = 1;
    mbits = 0; mon_rd = mon_cnt;
    txq_rd = txq_wr; rxq_rd = rxq_wr;
    repeat (2) @(negedge PCLK);
    check_reset_values();
    status_exp(0, 0, 0);
    rd_exp(A_MYADDR, 32'h11);
    // leave EVT pending (masked) for the final reset
    send_frame(8'h02, dut.c_my_addr, 8'h05, 8'd8, 1);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_EVT);
  endtask
