// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for Ethernet_top v2.0 (802.3 MAC)
//  * Two MACs, A (index 0) and B (index 1), cross-connected. The TB can take
//    over A's receive lines with an injector of its own.
//  * Transmit check: a line monitor per MAC collects every frame from gtx_*
//    and compares it with the host's frame plus padding, FCS (computed by
//    the TB) and 7 x 0x55 + 0xD5; underrun frames end with one gtx_er byte;
//    idle gaps are at least 12 byte times.
//  * Receive check: a reference receiver per MAC watches the lines that MAC
//    sees and predicts every rx_* byte, rx_last, rx_stat and rx_frag (CRC,
//    length, VLAN length, grx_er, address filter, PAUSE).
//  * PAUSE: B sends PAUSE frames to A as ordinary frames; A must not start
//    a frame for quanta x 64 byte times (not with cfg_pause_en off, nor for
//    a PAUSE with a bad FCS).
//  * Byte times 1, 2, 4 and 32 clocks, every frame size from the minimum
//    up to the VLAN maximum and past it, promiscuous mode, resets.
// ============================================================================
`timescale 1ns/1ps
module Ethernet_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 40) $display("ERROR: %s @%0t", m, $time);
  endfunction

  localparam logic [47:0] MA = 48'h02_11_22_33_44_55, MB = 48'h02_AA_BB_CC_DD_EE;
  logic [47:0] mac [0:1];                // the MACs' addresses (MA / MB, inverted for a while)
  localparam logic [47:0] PAUSE_DA = 48'h01_80_C2_00_00_01, BCAST = 48'hFF_FF_FF_FF_FF_FF;

  // ---------------- MACs ----------------
  logic [4:0]  cfg_div = 0;
  logic        promisc [0:1], pause_en [0:1];
  logic        tx_valid [0:1], tx_last [0:1];
  logic [7:0]  tx_data [0:1];
  wire         tx_ready [0:1], tx_done [0:1], tx_underrun [0:1], tx_paused [0:1];
  wire  [7:0]  gtxd [0:1];
  wire         gtx_en [0:1], gtx_er [0:1];
  logic [7:0]  rxd [0:1];
  logic        rxdv [0:1], rxer [0:1];
  wire         rx_valid [0:1], rx_last [0:1], rx_frag [0:1];
  wire  [7:0]  rx_data [0:1];
  wire  [3:0]  rx_stat [0:1];
  logic        inj = 0;                  // the injector drives A's receive lines
  logic [7:0]  ij_d = 0;
  logic        ij_dv = 0, ij_er = 0;
  always_comb begin
    rxd[1] = gtxd[0]; rxdv[1] = gtx_en[0]; rxer[1] = gtx_er[0];
    rxd[0] = inj ? ij_d : gtxd[1]; rxdv[0] = inj ? ij_dv : gtx_en[1]; rxer[0] = inj ? ij_er : gtx_er[1];
  end
  for (genvar i = 0; i < 2; i++) begin : g_mac
    Ethernet_top u (
      .clk, .rst_n, .cfg_div, .cfg_mac(mac[i]), .cfg_promisc(promisc[i]), .cfg_pause_en(pause_en[i]),
      .tx_valid(tx_valid[i]), .tx_ready(tx_ready[i]), .tx_data(tx_data[i]), .tx_last(tx_last[i]),
      .tx_done(tx_done[i]), .tx_underrun(tx_underrun[i]), .tx_paused(tx_paused[i]),
      .gtxd(gtxd[i]), .gtx_en(gtx_en[i]), .gtx_er(gtx_er[i]), .grxd(rxd[i]), .grx_dv(rxdv[i]), .grx_er(rxer[i]),
      .rx_valid(rx_valid[i]), .rx_data(rx_data[i]), .rx_last(rx_last[i]), .rx_stat(rx_stat[i]), .rx_frag(rx_frag[i]));
  end
  wire ls [0:1];
  assign ls[0] = g_mac[0].u.ls;
  assign ls[1] = g_mac[1].u.ls;

  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] d);
    for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction

  // ---------------- transmit hosts ----------------
  // frames to send: bytes in fb[i], frame k at fo[i][k] with length fl[i][k],
  // underrun after fu[i][k] bytes (-1: none)
  logic [7:0] fb [0:1][0:65535];
  int         fo [0:1][0:255], fl [0:1][0:255], fu [0:1][0:255];
  int         fh [0:1], ft [0:1], fw [0:1], hp [0:1], bp [0:1];   // head / tail frames, write pointer, host byte, line check frame
  bit         took [0:1], stopped [0:1];
  int         n_tx [0:1], n_ur [0:1];
  for (genvar i = 0; i < 2; i++) begin : g_host
    always @(posedge clk) took[i] <= tx_valid[i] && tx_ready[i];
    always @(negedge clk) if (!rst_n) begin tx_valid[i] = 0; hp[i] = 0; stopped[i] = 0; end
    else begin
      if (took[i]) begin
        hp[i]++;
        tx_valid[i] = 0;
        if (hp[i] == fl[i][fh[i] % 256]) begin fh[i]++; hp[i] = 0; end
      end
      if (tx_underrun[i]) begin fh[i]++; hp[i] = 0; stopped[i] = 0; end
      if (fh[i] != ft[i] && !stopped[i]) begin : b_offer
        int k;
        k = fh[i] % 256;
        if (hp[i] == fu[i][k]) begin stopped[i] = 1; tx_valid[i] = 0; end
        else begin
          tx_valid[i] = 1; tx_data[i] = fb[i][(fo[i][k] + hp[i]) % 65536]; tx_last[i] = hp[i] == fl[i][k] - 1;
        end
      end
    end
  end
  // queue a frame: DA, SA, type, payload of len - 14 bytes
  task automatic send(input int i, input logic [47:0] da, input logic [15:0] ty, input int len, input int ur);
    int k, o;
    k = ft[i] % 256; o = fw[i];
    for (int j = 0; j < 6; j++) fb[i][(o + j) % 65536] = da[47 - 8 * j -: 8];
    for (int j = 0; j < 6; j++) fb[i][(o + 6 + j) % 65536] = mac[i] >> (40 - 8 * j);
    fb[i][(o + 12) % 65536] = ty[15:8]; fb[i][(o + 13) % 65536] = ty[7:0];
    for (int j = 14; j < len; j++) fb[i][(o + j) % 65536] = $urandom;
    fo[i][k] = o; fl[i][k] = len; fu[i][k] = ur;
    fw[i] = (o + len) % 65536;
    ft[i]++;
  endtask
  task automatic send_pause(input int i, input logic [47:0] da, input logic [15:0] q);
    int o;
    o = fw[i];
    send(i, da, 16'h8808, 60, -1);
    fb[i][(o + 14) % 65536] = 8'h00; fb[i][(o + 15) % 65536] = 8'h01;
    fb[i][(o + 16) % 65536] = q[15:8]; fb[i][(o + 17) % 65536] = q[7:0];
  endtask

  // ---------------- transmit line check ----------------
  int   lk [0:1], lgap [0:1], lcrc_n [0:1];
  bit   lin [0:1];
  logic [31:0] lcrc [0:1];
  int   tx_start_t [0:1];
  for (genvar i = 0; i < 2; i++) begin : g_tmon
    always @(posedge clk) if (!rst_n) begin lin[i] = 0; lgap[i] = 100; end
    else if (ls[i]) begin
      // gtx_* as set at the previous byte time
      if (gtx_en[i]) begin : b_on
        int k, pos;
        k = bp[i] % 256;
        if (!lin[i]) begin
          if (lgap[i] < 12) fail($sformatf("MAC %0d: gap of %0d", i, lgap[i]));
          lin[i] = 1; lk[i] = 0; lcrc[i] = '1; tx_start_t[i] = $time;
          if (bp[i] == ft[i]) fail($sformatf("MAC %0d: a frame with none queued", i));
        end
        pos = lk[i] - 8;
        if (lk[i] < 7 && gtxd[i] !== 8'h55 || lk[i] == 7 && gtxd[i] !== 8'hD5) fail($sformatf("MAC %0d: preamble byte %0d = %h", i, lk[i], gtxd[i]));
        if (pos >= 0) begin : b_body
          int ln;
          ln = fl[i][k] < 60 ? 60 : fl[i][k];
          if (fu[i][k] >= 0 && pos == fu[i][k]) begin
            if (!gtx_er[i]) fail($sformatf("MAC %0d: no gtx_er at the underrun", i));
          end else if (gtx_er[i]) fail($sformatf("MAC %0d: gtx_er", i));
          else if (pos < fl[i][k]) begin
            if (gtxd[i] !== fb[i][(fo[i][k] + pos) % 65536]) fail($sformatf("MAC %0d: byte %0d = %h, expected %h", i, pos, gtxd[i], fb[i][(fo[i][k] + pos) % 65536]));
            lcrc[i] = crc8(lcrc[i], gtxd[i]);
          end else if (pos < ln) begin
            if (gtxd[i] !== 8'h00) fail($sformatf("MAC %0d: pad byte %h", i, gtxd[i]));
            lcrc[i] = crc8(lcrc[i], gtxd[i]);
          end else if (pos < ln + 4) begin
            if (gtxd[i] !== ~lcrc[i][8 * (pos - ln) +: 8]) fail($sformatf("MAC %0d: FCS byte %0d = %h", i, pos - ln, gtxd[i]));
          end else fail($sformatf("MAC %0d: frame too long", i));
        end
        lk[i]++;
      end else begin
        if (lin[i]) begin : b_end
          int k, ln;
          k = bp[i] % 256;
          ln = fu[i][k] >= 0 ? fu[i][k] + 1 : (fl[i][k] < 60 ? 60 : fl[i][k]) + 4;
          if (lk[i] - 8 != ln) fail($sformatf("MAC %0d: frame of %0d bytes, expected %0d", i, lk[i] - 8, ln));
          bp[i]++; n_tx[i]++;
          if (fu[i][k] >= 0) n_ur[i]++;
          lgap[i] = 0;
        end
        lin[i] = 0;
        lgap[i]++;
      end
    end
  end

  // ---------------- receive reference ----------------
  // expected rx bytes: {last, stat[3:0], data}
  logic [12:0] eq [0:1][0:65535];
  int          eh [0:1], et [0:1], n_frag_e [0:1], n_frag [0:1], n_rx [0:1];
  logic [12:0] aq [0:1][0:65535];
  int          ah [0:1], at [0:1];
  logic [7:0]  rb [0:1][0:4095];
  bit          rerr [0:1];
  int          rst_ [0:1], rn [0:1];       // 0 idle, 1 preamble, 2 data, 3 drop
  int          pause_q [0:1], pause_t [0:1], n_pause [0:1];
  for (genvar i = 0; i < 2; i++) begin : g_rref
    always @(posedge clk) if (!rst_n) begin rst_[i] = 0; end
    else if (ls[i]) begin
      case (rst_[i])
        0, 1: if (!rxdv[i]) begin if (rst_[i] == 1) n_frag_e[i]++; rst_[i] = 0; end
              else if (rxd[i] == 8'hD5) begin rst_[i] = 2; rn[i] = 0; rerr[i] = 0; end
              else if (rxd[i] == 8'h55) rst_[i] = 1;
              else begin rst_[i] = 3; n_frag_e[i]++; end
        2: if (rxdv[i]) begin
             if (rn[i] < 4096) rb[i][rn[i]] = rxd[i];
             rn[i]++;
             if (rxer[i]) rerr[i] = 1;
           end else begin : b_fr
             logic [47:0] da;
             logic [31:0] c;
             logic [15:0] ty;
             bit acc, ce, le, pz;
             int n;
             rst_[i] = 0;
             n = rn[i];
             if (n < 6) n_frag_e[i]++;
             else begin
               da = {rb[i][0], rb[i][1], rb[i][2], rb[i][3], rb[i][4], rb[i][5]};
               acc = promisc[i] || da == mac[i] || da == BCAST || da == PAUSE_DA;
               c = '1;
               for (int j = 0; j < n; j++) c = crc8(c, rb[i][j]);
               ty = n >= 14 ? {rb[i][12], rb[i][13]} : 16'h0000;
               ce = c != 32'hDEBB20E3;
               le = n < 64 || n > (ty == 16'h8100 ? 1522 : 1518);
               pz = n >= 18 && ty == 16'h8808 && rb[i][14] == 8'h00 && rb[i][15] == 8'h01;
               if (acc) begin
                 for (int j = 0; j <= n - 5; j++) begin
                   eq[i][et[i] % 65536] = {j == n - 5, j == n - 5 ? {pz, rerr[i], le, ce} : 4'h0, rb[i][j]};
                   et[i]++;
                 end
                 if (pz && pause_en[i] && !ce && !le && !rerr[i]) begin
                   pause_q[i] = {rb[i][16], rb[i][17]}; pause_t[i] = $time; n_pause[i]++;
                 end
               end
             end
           end
        default: if (!rxdv[i]) rst_[i] = 0;
      endcase
    end
    always @(negedge clk) if (rst_n) begin
      if (rx_frag[i]) n_frag[i]++;
      // the bytes stream out before the frame ends: compare once both are known
      if (rx_valid[i]) begin
        n_rx[i]++;
        aq[i][at[i] % 65536] = {rx_last[i], rx_last[i] ? rx_stat[i] : 4'h0, rx_data[i]}; at[i]++;
      end
      while (ah[i] != at[i] && eh[i] != et[i]) begin
        if (aq[i][ah[i] % 65536] !== eq[i][eh[i] % 65536])
          fail($sformatf("MAC %0d: rx %h, expected %h", i, aq[i][ah[i] % 65536], eq[i][eh[i] % 65536]));
        ah[i]++; eh[i]++;
      end
      if (at[i] - ah[i] > 3000) begin fail($sformatf("MAC %0d: rx bytes with none expected", i)); ah[i] = at[i]; end
    end
  end

  // ---------------- injector (A's receive lines) ----------------
  task automatic ij_byte(input logic [7:0] d, input bit dv, input bit er);
    @(negedge clk);
    while (!ls[0]) @(negedge clk);
    ij_d = d; ij_dv = dv; ij_er = er;
  endtask
  // a frame on A's receive lines: preamble of np bytes, n bytes, FCS (bad_fcs inverts it), grx_er on byte er_at
  task automatic ij_frame(input logic [47:0] da, input logic [15:0] ty, input int n, input int np, input bit bad_fcs,
                          input int er_at, input logic [15:0] q, input logic [15:0] opc = 16'h0001);
    logic [7:0] f [0:4095];
    logic [31:0] c;
    for (int j = 0; j < 6; j++) f[j] = da[47 - 8 * j -: 8];
    for (int j = 0; j < 6; j++) f[6 + j] = MB >> (40 - 8 * j);
    f[12] = ty[15:8]; f[13] = ty[7:0];
    for (int j = 14; j < n; j++) f[j] = $urandom;
    if (ty == 16'h8808) begin f[14] = opc[15:8]; f[15] = opc[7:0]; f[16] = q[15:8]; f[17] = q[7:0]; end
    c = '1;
    for (int j = 0; j < n; j++) c = crc8(c, f[j]);
    c = ~c ^ (bad_fcs ? 32'h1 : 32'h0);
    for (int j = 0; j < 4; j++) f[n + j] = c[8 * j +: 8];
    inj = 1;
    for (int j = 0; j < np; j++) ij_byte(8'h55, 1, 0);
    ij_byte(8'hD5, 1, 0);
    for (int j = 0; j < n + 4; j++) ij_byte(f[j], 1, j == er_at);
    for (int j = 0; j < 12; j++) ij_byte(8'h00, 0, 0);
  endtask
  task automatic ij_raw(input int n, input logic [7:0] first);
    inj = 1;
    ij_byte(first, 1, 0);
    for (int j = 1; j < n; j++) ij_byte(8'($urandom), 1, 0);
    for (int j = 0; j < 12; j++) ij_byte(8'h00, 0, 0);
  endtask

  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  task automatic drain;
    int g;
    g = 0;
    while ((fh[0] != ft[0] || fh[1] != ft[1] || bp[0] != ft[0] || bp[1] != ft[1] || lin[0] || lin[1] ||
            g_mac[0].u.rs != 0 || g_mac[1].u.rs != 0) && g < 2_000_000) begin @(negedge clk); g++; end
    if (g >= 2_000_000) fail($sformatf("traffic did not drain: fh %0d/%0d ft %0d/%0d bp %0d/%0d lin %b%b rs %0d %0d hp %0d %0d ts %0d %0d v %b%b st %b%b p %0d %0d", fh[0], fh[1], ft[0], ft[1], bp[0], bp[1], lin[0], lin[1], g_mac[0].u.rs, g_mac[1].u.rs, hp[0], hp[1], g_mac[0].u.ts, g_mac[1].u.ts, tx_valid[0], tx_valid[1], stopped[0], stopped[1], g_mac[0].u.pause, g_mac[1].u.pause));
    cycles(20 * (int'(cfg_div) + 1));
  endtask
  // random frames both ways
  task automatic traffic(input int n);
    for (int k = 0; k < n; k++) begin : b_t
      int i, len, d;
      logic [47:0] da;
      logic [15:0] ty;
      i = $urandom % 2;
      d = $urandom % 8;
      da = d < 4 ? mac[1 - i] : (d < 6 ? BCAST : (d == 6 ? 48'h0300_0000_0001 : 48'h0200_1234_5678));
      len = $urandom % 4 == 0 ? 14 + $urandom % 50 : 60 + $urandom % 200;
      ty = $urandom % 3 == 0 ? 16'($urandom) : 16'h0800;
      if (ty == 16'h8808 || ty == 16'h8100) ty = 16'h0800;
      send(i, da, ty, len, -1);
    end
  endtask

  // checks a PAUSE: MAC i holds its next frame for quanta x 64 byte times
  task automatic pause_check(input int q, input bit expect_hold);
    int t0, np, bt;
    np = n_pause[0];
    bt = (int'(cfg_div) + 1) * 10;
    send_pause(1, PAUSE_DA, 16'(q));
    while (bp[1] != ft[1] || lin[1]) @(negedge clk);
    cycles(8 * (int'(cfg_div) + 1));
    t0 = $time;
    send(0, MB, 16'h0800, 100, -1);
    drain();
    if (expect_hold != (n_pause[0] == np + 1)) fail("PAUSE seen / not seen");
    if (expect_hold && tx_start_t[0] - t0 < q * 64 * bt - 20 * bt)
      fail($sformatf("A started a frame %0d ns after a PAUSE of %0d", tx_start_t[0] - t0, q));
    if (!expect_hold && tx_start_t[0] - t0 > 20 * bt)
      fail("A held its frame for a PAUSE it should ignore");
  endtask

  initial begin
    for (int i = 0; i < 2; i++) begin
      promisc[i] = 0; pause_en[i] = 1; mac[i] = i == 0 ? MA : MB; tx_valid[i] = 0; tx_last[i] = 0; tx_data[i] = 0;
      fh[i] = 0; ft[i] = 0; fw[i] = 0; hp[i] = 0; bp[i] = 0; n_tx[i] = 0; n_ur[i] = 0;
      eh[i] = 0; et[i] = 0; ah[i] = 0; at[i] = 0; n_frag_e[i] = 0; n_frag[i] = 0; n_rx[i] = 0; n_pause[i] = 0; pause_t[i] = 0;
    end
    #22 rst_n = 1;
    // 1. traffic at several byte times
    for (int r = 0; r < 4; r++) begin
      cfg_div = r == 0 ? 0 : (r == 1 ? 1 : (r == 2 ? 3 : 31));
      cycles(40);
      traffic(r == 3 ? 6 : 30);
      // sizes at the edges: 59, 60, 61 and the maximum
      send(0, MB, 16'h0800, 59, -1); send(1, MA, 16'h0800, 60, -1); send(0, BCAST, 16'h0800, 61, -1);
      send(0, MB, 16'h0800, 60, -1);
      if (r < 2) begin send(1, MA, 16'h0800, 1514, -1); send(0, MB, 16'h8100, 1518, -1); end
      // a shorter byte time in the middle of frames (both ends switch together)
      if (r == 3) begin cycles(3000); while (g_mac[0].u.dc != 5'd20) @(negedge clk); cfg_div = 2; end
      drain();
    end
    cfg_div = 0;
    cycles(40);
    // 2. underruns: in the header and late in a frame
    send(0, MB, 16'h0800, 100, 3); send(0, MB, 16'h0800, 100, 70); send(1, MA, 16'h0800, 80, 30);
    send(1, MA, 16'h0800, 100, 1);
    drain();
    // 3. PAUSE: obeyed, longer, not with cfg_pause_en off
    pause_check(3, 1);
    pause_check(40, 1);
    pause_en[0] = 0; pause_check(5, 0); pause_en[0] = 1;
    // a PAUSE to A's own address, then traffic resumes
    send_pause(1, MA, 16'd2); traffic(4); drain();
    // 4. the injector: lengths, VLAN, errors, preambles, filtering
    ij_frame(MA, 16'h0800, 60, 7, 0, -1, 0);              // 64 with FCS: good
    ij_frame(MA, 16'h0800, 59, 7, 0, -1, 0);              // runt
    ij_frame(MA, 16'h0800, 1514, 7, 0, -1, 0);            // 1518: good
    ij_frame(MA, 16'h0800, 1515, 7, 0, -1, 0);            // too long
    ij_frame(MA, 16'h8100, 1518, 3, 0, -1, 0);            // VLAN 1522: good
    ij_frame(MA, 16'h8100, 1519, 1, 0, -1, 0);            // VLAN too long
    ij_frame(MA, 16'h0800, 2100, 7, 0, -1, 0);            // past the length counter
    ij_frame(MA, 16'h0800, 100, 7, 1, -1, 0);             // bad FCS
    ij_frame(MA, 16'h0800, 40, 7, 1, -1, 0);              // runt with a bad FCS
    ij_frame(MA, 16'h0800, 100, 0, 0, 20, 0);             // grx_er, no preamble before the SFD
    ij_frame(48'h02_00_00_00_00_09, 16'h0800, 100, 7, 0, -1, 0);   // another station: dropped
    ij_frame(48'h03_00_00_00_00_09, 16'h0800, 100, 7, 0, -1, 0);   // multicast: dropped
    promisc[0] = 1;
    ij_frame(48'h02_00_00_00_00_09, 16'h0800, 100, 7, 0, -1, 0);   // promiscuous: kept
    promisc[0] = 0;
    ij_frame(PAUSE_DA, 16'h8808, 60, 7, 1, -1, 16'd9);    // PAUSE with a bad FCS: ignored
    ij_frame(PAUSE_DA, 16'h8808, 40, 7, 0, -1, 16'd9);    // short PAUSE: len_err, ignored
    ij_frame(PAUSE_DA, 16'h8808, 60, 7, 0, 30, 16'd9);    // PAUSE with grx_er: ignored
    ij_frame(PAUSE_DA, 16'h8808, 60, 7, 0, -1, 16'hFFFF); // the longest PAUSE ...
    ij_frame(PAUSE_DA, 16'h8808, 60, 7, 0, -1, 16'd0);    // ... ended by a zero PAUSE
    ij_frame(MA, 16'h8808, 60, 7, 0, -1, 16'd1, 16'h0101);   // another MAC control opcode: plain frame
    ij_frame(MA, 16'h8808, 60, 7, 0, -1, 16'd1, 16'h0000);
    ij_frame(MA, 16'h8808, 15, 7, 0, -1, 16'd1);          // too short for the PAUSE fields
    ij_frame(MA, 16'h0800, 100, 7, 0, 0, 0);              // grx_er on the first byte
    ij_raw(3, 8'h55); ij_raw(5, 8'hD5); ij_raw(6, 8'hD5);  // fragments, and the shortest frame kept
    // 17 bytes with a PAUSE type and opcode: too short to count as a PAUSE
    inj = 1;
    ij_byte(8'hD5, 1, 0);
    for (int j = 0; j < 6; j++) ij_byte(MA[47 - 8 * j -: 8], 1, 0);
    for (int j = 0; j < 6; j++) ij_byte(8'h42, 1, 0);
    ij_byte(8'h88, 1, 0); ij_byte(8'h08, 1, 0); ij_byte(8'h00, 1, 0); ij_byte(8'h01, 1, 0); ij_byte(8'h00, 1, 0);
    for (int j = 0; j < 12; j++) ij_byte(8'h00, 0, 0);
    ij_raw(4, 8'hAB); ij_raw(1, 8'h55);                    // bad preamble, preamble only
    inj = 0;
    cycles(20);
    traffic(10);
    drain();
    // other station addresses (every address bit both ways)
    mac[0] = ~MA; mac[1] = ~MB;
    traffic(10); drain();
    mac[0] = MA; mac[1] = MB;
    traffic(4); drain();
    // 5. a reset in the middle of traffic
    send(0, MB, 16'h0800, 300, -1); send(1, MA, 16'h0800, 300, -1);
    cycles(150);
    rst_n = 0;
    cycles(3);
    for (int i = 0; i < 2; i++) begin fh[i] = ft[i]; bp[i] = ft[i]; eh[i] = et[i]; ah[i] = at[i]; end
    rst_n = 1;
    cycles(20);
    traffic(8);
    drain();

    for (int i = 0; i < 2; i++) if (ah[i] != at[i] || eh[i] != et[i]) fail($sformatf("MAC %0d: %0d rx bytes, %0d expected left over", i, at[i] - ah[i], et[i] - eh[i]));
    for (int i = 0; i < 2; i++) if (n_frag[i] != n_frag_e[i]) fail($sformatf("MAC %0d: %0d fragments, expected %0d", i, n_frag[i], n_frag_e[i]));
    $display("frames %0d/%0d rx bytes %0d/%0d underruns %0d pauses %0d fragments %0d",
             n_tx[0], n_tx[1], n_rx[0], n_rx[1], n_ur[0] + n_ur[1], n_pause[0], n_frag[0]);
    if (errors == 0) $display("TEST PASSED: Ethernet");
    else $display("TEST FAILED: Ethernet (%0d errors)", errors);
    $finish;
  end
  initial begin #400ms; $display("TEST FAILED: Ethernet (timeout)"); $finish; end
endmodule
