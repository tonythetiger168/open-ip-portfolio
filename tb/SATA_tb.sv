// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SATA_top (SATA host with built-in DMA command
// sequencer). The TB is the device: OOB responder (COMINIT / COMWAKE, ALIGNp
// lock), a dword-level link layer (X_RDY / R_RDY / R_IP / R_OK / R_ERR /
// WTRM / SYNC handshakes, CRC32) and a command layer serving IDENTIFY,
// WRITE DMA EXT and READ DMA EXT from a 64-sector store. One-shot fault
// knobs break every step: OOB patterns, handshakes, CRC, frame length,
// FIS types, status, read data, timeouts, link loss.
// Checks: the host's command order and LBA walk, write data against an
// xorshift32 reference, read-back comparison (no irq on clean traffic) and
// one irq per injected fault. Under Verilator the bound checker
// (tb/cov/SATA_sva.sv) predicts tx_p, tx_n and irq on every clock.
// IP design verification v3.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module SATA_tb;

  localparam logic [31:0] P_ALIGN = 32'h7B4A_4ABC;
  localparam logic [31:0] P_SYNC  = 32'hB5B5_957C;
  localparam logic [31:0] P_XRDY  = 32'h5757_B57C;
  localparam logic [31:0] P_RRDY  = 32'h4A4A_957C;
  localparam logic [31:0] P_RIP   = 32'h5555_B57C;
  localparam logic [31:0] P_ROK   = 32'h3535_B57C;
  localparam logic [31:0] P_RERR  = 32'h5656_B57C;
  localparam logic [31:0] P_SOF   = 32'h3737_B57C;
  localparam logic [31:0] P_EOF   = 32'hD5D5_B57C;
  localparam logic [31:0] P_WTRM  = 32'h5858_B57C;

  logic clk = 0, rst_n = 0, refclk = 0;
  logic rx_p = 0, rx_n = 0;
  wire  tx_p, tx_n, irq;

  SATA_top dut (.clk(clk), .rst_n(rst_n), .tx_n(tx_n), .tx_p(tx_p), .rx_n(rx_n), .rx_p(rx_p),
                .refclk(refclk), .irq(irq));

  always #5 clk = ~clk;
  always #7 refclk = ~refclk;

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("ERROR @%0t: %s", $time, m);
  endtask

  function automatic logic [31:0] crc32_dw(input logic [31:0] c, input logic [31:0] d);
    logic [31:0] r;
    logic        fb;
    r = c;
    for (int k = 0; k < 32; k++) begin
      fb = r[0] ^ d[k];
      r  = r >> 1;
      if (fb) r = r ^ 32'hEDB8_8320;
    end
    crc32_dw = r;
  endfunction

  function automatic logic [31:0] xorshift(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    xorshift = y ^ (y << 5);
  endfunction

  int irq_cnt = 0;
  always @(posedge clk) if (rst_n && irq) irq_cnt++;

  // ------------------------------------------------------------------
  // host OOB monitor (classifies the host's bursts and gaps)
  // ------------------------------------------------------------------
  int  m_run = 0, m_gcnt = 0, m_gcls = 0;
  bit  m_act = 0, m_bok = 0;
  int  n_comreset = 0, n_comwake = 0;
  always @(negedge clk) begin
    bit a;
    a = (tx_p != tx_n);
    if (!rst_n) begin m_run = 0; m_act = 0; m_gcnt = 0; end
    else if (a == m_act) m_run++;
    else begin
      if (m_act) m_bok = (m_run >= 12 && m_run <= 20);
      else if (m_bok && m_run >= 40 && m_run <= 56) begin
        m_gcnt = (m_gcls == 1) ? m_gcnt + 1 : 1; m_gcls = 1;
      end else if (m_bok && m_run >= 12 && m_run <= 20) begin
        m_gcnt = (m_gcls == 2) ? m_gcnt + 1 : 1; m_gcls = 2;
      end else m_gcnt = 0;
      if (m_gcnt == 3) begin
        if (m_gcls == 1) n_comreset++; else n_comwake++;
        m_gcnt = 0;
      end
      m_act = a; m_run = 1;
    end
  end

  // ------------------------------------------------------------------
  // device line driver
  // ------------------------------------------------------------------
  bit          d_stream = 0;     // dword streaming on
  logic [31:0] d_sr;
  int          d_bit;

  task automatic line_idle(input int n);
    repeat (n) begin @(negedge clk); rx_p = 0; rx_n = 0; end
  endtask
  // OOB pattern: n bursts of blen clk, gaps of glen clk
  task automatic oob(input int glen, input int blen = 16, input int n = 4);
    for (int b = 0; b < n; b++) begin
      for (int i = 0; i < blen; i++) begin @(negedge clk); rx_p = i % 2; rx_n = !(i % 2); end
      line_idle(glen);
    end
  endtask

  // ------------------------------------------------------------------
  // device link + command layer
  // ------------------------------------------------------------------
  localparam int K_ID = 0, K_OK = 1, K_ERR = 2, K_DACT = 3, K_RD = 4, K_PIO = 5,
                 K_D2H_SHORT = 6, K_DATA_SHORT = 7, K_OVF = 8, K_UNS = 9;
  int          dtx = 0, drx = 0;      // device link states
  logic [31:0] f [0:15];              // frame being sent
  int          flen, fidx, q_n = 0;
  logic [31:0] fcrc;
  int          qk [0:7];
  logic [5:0]  ql [0:7];
  logic [31:0] rb [0:15];
  int          rn;
  logic [31:0] rcrc, rcrcp, rlast;
  bit          rok, exp_wdata;
  logic [5:0]  wlba;
  logic [5:0]  max_lba = 6'd63;
  int          h_aligns, d_aligns_sent, w_dw;
  bit          linked;
  // host traffic log
  int          n_cmd = 0, n_err_cmd = 0;
  logic [7:0]  last_cmd;
  logic [5:0]  last_lba;
  logic [31:0] xs_ref = 32'h2545_F491;
  logic [31:0] last_wr [0:7];
  // fault knobs (counts of occurrences to affect)
  int kn_crc = 0, kn_rerr = 0, kn_no_rrdy = 0, kn_no_rok = 0, kn_mute = 0, kn_err = 0,
      kn_rdbad = 0, kn_pio = 0, kn_d2h_short = 0, kn_data_short = 0, kn_ovf = 0,
      kn_collide = 0, kn_abort = 0, kn_hold = 0, kn_withdraw = 0, kn_stat_hold = 0,
      kn_garbage = 0, kn_rok_garbage = 0, kn_id_sts_err = 0,
      kn_wsts_err = 0, kn_wsts_mute = 0, kn_rsts_err = 0, kn_rsts_mute = 0, kn_rsts_short = 0;
  bit mute_req = 0;                   // idle the line for the dword after the first ALIGNp
  int d_mute_n = 0;
  int hold_n, stat_n, wt_n, sync_n;
  bit pio_alt = 0;
  logic [15:0] rerr_tgt = 0;           // {cmd, type} the R_ERR knob applies to, 0 = any

  task automatic enq(input int k, input logic [5:0] l = 0);
    qk[q_n] = k; ql[q_n] = l; q_n++;
  endtask
  task automatic deq;
    for (int i = 0; i < 7; i++) begin qk[i] = qk[i + 1]; ql[i] = ql[i + 1]; end
    q_n--;
  endtask

  task automatic build(input int k, input logic [5:0] l);
    for (int i = 0; i < 16; i++) f[i] = 0;
    case (k)
      K_ID: begin
        f[0] = 32'h0000_0046; flen = 9;
        f[1] = {$urandom, max_lba} ;
        for (int i = 2; i < 9; i++) f[i] = $urandom;
      end
      K_OK, K_ERR, K_UNS: begin
        f[0] = {(k == K_ERR) ? 8'h04 : 8'h00, (k == K_ERR) ? 8'h51 : 8'h50, 8'h40, 8'h34};
        if (k == K_ERR && $urandom % 2) f[0][31:24] = 8'h00;   // ERR bit alone
        if (k == K_ERR && f[0][31:24] == 0) f[0][23:16] = 8'h51;
        if (k == K_ERR && $urandom % 2) f[0][23:16] = 8'h50;    // error byte alone
        if (k == K_ERR && f[0][23:16] == 8'h50) f[0][31:24] = 8'h84;
        f[1] = $urandom; f[2] = $urandom; f[3] = $urandom; f[4] = $urandom;
        f[0][15:8] = $urandom;
        flen = 5;
      end
      K_DACT: begin f[0] = {$urandom, 8'h39} & 32'h0000_FFFF; f[0][7:0] = 8'h39; flen = 1; end
      K_PIO: begin f[0] = pio_alt ? 32'h0000_00A1 : 32'h0000_005F; pio_alt = !pio_alt; flen = 5; end
      K_D2H_SHORT: begin f[0] = 32'h0050_0034; flen = 3; end
      K_DATA_SHORT: begin f[0] = 32'h0000_0046; flen = 4; end
      K_OVF: begin for (int i = 0; i < 11; i++) f[i] = $urandom; f[0][7:0] = 8'h34; flen = 11; end
      default: ;
    endcase
  endtask

  // sector store: 8 dwords per LBA
  logic [31:0] sect [0:63][0:7];

  task automatic build_rd(input logic [5:0] l);
    int fw, fb;
    f[0] = 32'h0000_0046; flen = 9;
    for (int i = 0; i < 8; i++) f[i + 1] = sect[l][i];
    if (kn_rdbad > 0) begin
      kn_rdbad--;
      fw = 1 + $urandom % 8; fb = $urandom % 32;
      f[fw][fb] = !f[fw][fb];
    end
  endtask

  // a FIS from the host
  task automatic host_fis;
    logic [7:0] c;
    if (rb[0][7:0] == 8'h27) begin
      c = rb[0][23:16];
      n_cmd++;
      last_cmd = c;
      last_lba = rb[1][5:0];
      if (kn_mute > 0) kn_mute--;
      else if (kn_err > 0) begin kn_err--; enq(K_ERR); end
      else if (kn_pio > 0) begin kn_pio--; enq(K_PIO); end
      else if (kn_d2h_short > 0) begin kn_d2h_short--; enq(K_D2H_SHORT); end
      else if (kn_data_short > 0) begin kn_data_short--; enq(K_DATA_SHORT); end
      else
        case (c)
          8'hEC: begin
            enq(K_ID);
            if (kn_id_sts_err > 0) begin kn_id_sts_err--; enq(K_ERR); end
            else enq(K_OK);
          end
          8'h35: begin enq(K_DACT); exp_wdata = 1; wlba = rb[1][5:0]; end
          8'h25: begin
            enq(K_RD, rb[1][5:0]);
            if (kn_rsts_err > 0) begin kn_rsts_err--; enq(K_ERR); end
            else if (kn_rsts_short > 0) begin kn_rsts_short--; enq(K_D2H_SHORT); end
            else if (kn_rsts_mute > 0) kn_rsts_mute--;
            else enq(K_OK);
          end
          default: enq(K_ERR);
        endcase
    end else if (rb[0][7:0] == 8'h46 && exp_wdata) begin
      exp_wdata = 0;
      for (int i = 0; i < 8; i++) begin
        sect[wlba][i] = rb[i + 1];
        last_wr[i] = rb[i + 1];
      end
      if (kn_wsts_err > 0) begin kn_wsts_err--; enq(K_ERR); end
      else if (kn_wsts_mute > 0) kn_wsts_mute--;
      else enq(K_OK);
    end else fail($sformatf("unexpected FIS from host: %h", rb[0]));
  endtask

  // device transmit: next dword
  task automatic dev_next(output logic [31:0] dw);
    dw = P_SYNC;
    if (!linked) dw = P_ALIGN;
    else if (dtx == 0) begin
      if (drx == 1) dw = P_RRDY;
      else if (drx == 2) dw = P_RIP;
      else if (drx == 3) begin
        if (kn_rok_garbage > 0) begin kn_rok_garbage--; dw = 32'h1234_5678; end
        else if (stat_n > 0) begin stat_n--; dw = P_SYNC; end   // R_OK withheld
        else dw = rok ? P_ROK : P_RERR;
      end else if (kn_garbage > 0) begin kn_garbage--; dw = 32'hDEAD_BEEF; end
      else if (sync_n > 0) sync_n--;
      else if (q_n > 0) begin
        dtx = 1; dw = P_XRDY; hold_n = 0;
      end
    end else
      case (dtx)
        1: begin
          dw = P_XRDY;
          if (kn_hold > 0) begin
            hold_n++;
            if (hold_n == 70) begin kn_hold--; dtx = 0; dw = P_SYNC; sync_n = 3; end
          end
        end
        2: begin                                    // SOF
          dw = P_SOF; dtx = 3; fidx = 0; fcrc = 32'hFFFF_FFFF;
          if (qk[0] == K_RD) build_rd(ql[0]); else build(qk[0], ql[0]);
        end
        3: begin
          if (kn_abort > 0 && fidx == 2) begin kn_abort--; dw = P_SYNC; dtx = 0; end
          else begin
            dw = f[fidx]; fcrc = crc32_dw(fcrc, f[fidx]); fidx++;
            if (fidx == flen) dtx = 4;
          end
        end
        4: begin
          dw = ~fcrc; dtx = 5;
          if (kn_crc > 0) begin kn_crc--; dw[7] = !dw[7]; end
        end
        5: begin dw = P_EOF; dtx = 6; end
        6: dw = P_WTRM;
        default: begin                              // keep WTRM after R_OK
          dw = P_WTRM; wt_n--;
          if (wt_n == 0) begin dtx = 0; sync_n = 2; end
        end
      endcase
  endtask

  // device receive: one host dword
  task automatic dev_rx(input logic [31:0] dw);
    if (dw == P_ALIGN) h_aligns++;
    else if (dtx == 1 && dw == P_RRDY) begin
      if (kn_hold > 0) ;                                          // never start the frame
      else if (kn_withdraw > 0) begin kn_withdraw--; dtx = 0; sync_n = 3; end   // SYNC, retry later
      else dtx = 2;
    end else if (dtx == 6 && (dw == P_ROK || dw == P_RERR)) begin
      dtx = 0; sync_n = 2;
      if (dw == P_ROK) begin
        deq();
        if (kn_stat_hold > 0) begin kn_stat_hold--; dtx = 7; wt_n = 70; end
      end else if (qk[0] == K_OVF) deq();
    end else
      case (drx)
        0: if (dw == P_XRDY && dtx <= 1) begin
          if (kn_collide > 0 && dtx == 0) begin
            kn_collide--; enq(K_UNS); dtx = 1; hold_n = 0;    // answer with our own X_RDY
          end else if (dtx == 0) begin
            if (kn_no_rrdy > 0) begin
              if (dw == P_XRDY) w_dw++;
              if (w_dw == 70) begin kn_no_rrdy--; w_dw = 0; end
            end else drx = 1;
          end
        end
        1: if (dw == P_SOF) begin drx = 2; rn = 0; rcrc = 32'hFFFF_FFFF; end
           else if (dw == P_SYNC) drx = 0;
        2: if (dw == P_EOF) begin
             drx = 3;
             rok = (rn >= 2) && (rlast == ~rcrcp);
             if (kn_rerr > 0 && (rerr_tgt == 0 || rerr_tgt == {rb[0][23:16], rb[0][7:0]} ||
                                 rerr_tgt == {8'h00, rb[0][7:0]})) begin
               kn_rerr--; rok = 0;
             end
             if (kn_no_rok > 0) begin kn_no_rok--; stat_n = 70; rok = 0; end
             if (rok) host_fis();
           end else begin
             if (rn < 16) rb[rn] = dw;
             rn++; rlast = dw; rcrcp = rcrc; rcrc = crc32_dw(rcrc, dw);
           end
        default: if (dw == P_SYNC) begin drx = 0; stat_n = 0; end
      endcase
  endtask

  // dword streams (both directions), LSB first
  logic [31:0] h_sr;
  int          h_bit;
  bit          h_al;
  always @(negedge clk) begin
    if (d_stream) begin
      rx_p = d_mute_n == 0 && d_sr[0]; rx_n = d_mute_n == 0 && !d_sr[0];
      if (d_mute_n > 0) d_mute_n--;
      d_sr = d_sr >> 1;
      d_bit++;
      if (d_bit == 32) begin
        d_bit = 0;
        dev_next(d_sr);
        if (!linked && d_sr == P_ALIGN) d_aligns_sent++;
        if (mute_req && d_aligns_sent == 1) begin mute_req = 0; d_mute_n = 32; end
      end
      // host -> device
      h_sr = {tx_p, h_sr[31:1]};
      if (!h_al) begin
        if (h_sr == P_ALIGN) begin h_al = 1; h_bit = 0; dev_rx(h_sr); end
      end else begin
        h_bit++;
        if (h_bit == 32) begin h_bit = 0; dev_rx(h_sr); end
      end
      if (!linked && h_aligns >= 2 && d_aligns_sent >= 4) linked = 1;
    end
  end

  // ------------------------------------------------------------------
  // scenario helpers
  // ------------------------------------------------------------------
  task automatic dev_reset_link;
    dtx = 0; drx = 0; q_n = 0; exp_wdata = 0; stat_n = 0; hold_n = 0; w_dw = 0;
    wt_n = 0; sync_n = 0;
    h_aligns = 0; d_aligns_sent = 0; linked = 0; h_al = 0; h_sr = 0; h_bit = 0;
  endtask

  // bring the link up; mode: 0 normal, 1 no COMINIT once, 2 no COMWAKE once,
  // 3 no ALIGNp once, 4 bad patterns first
  task automatic bring_up(input int mode = 0);
    int c;
    d_stream = 0;
    @(negedge clk); rx_p = 0; rx_n = 0;
    dev_reset_link();
    c = n_comreset;
    wait (n_comreset > c);
    if (mode == 1) begin c = n_comreset; wait (n_comreset > c); end   // host retries
    if (mode == 4) begin
      oob(48, 6);                                   // bursts too short
      oob(30);                                      // gaps fit neither class
      oob(48, 16, 2); oob(16, 16, 2);               // two INIT gaps, then a WAKE gap
      line_idle(100);
    end
    oob(48);                                        // COMINIT
    c = n_comwake;
    wait (n_comwake > c);
    if (mode == 2) begin                            // no COMWAKE: host restarts
      c = n_comreset; wait (n_comreset > c);
      oob(48);
      c = n_comwake; wait (n_comwake > c);
    end
    if (mode == 4) begin
      oob(16, 16, 2); line_idle(100);               // too few bursts
      oob(48, 16, 1); oob(16, 16, 3); line_idle(100);   // INIT gap, then two WAKE gaps
    end
    oob(16);                                        // COMWAKE
    line_idle(5);
    if (mode == 3) begin                            // no ALIGNp: host restarts
      c = n_comreset; wait (n_comreset > c);
      oob(48);
      c = n_comwake; wait (n_comwake > c);
      oob(16);
      line_idle(5);
    end
    // bit-slipped garbage before the ALIGNp stream
    for (int i = 0; i < 7; i++) begin @(negedge clk); rx_p = i % 3 == 0; rx_n = !rx_p; end
    mute_req = mode == 4;                           // one idle dword between ALIGNps
    d_sr = P_ALIGN; d_bit = 0; d_stream = 1;
    wait (linked);
  endtask

  task automatic expect_irq(input int b0, input int n, input string m);
    if (irq_cnt - b0 != n) fail($sformatf("%s: %0d irq pulses, expected %0d", m, irq_cnt - b0, n));
  endtask

  // wait for the host to issue n more commands
  task automatic wait_cmds(input int n, input int to = 400000);
    int c, t;
    c = n_cmd; t = 0;
    while (n_cmd < c + n && t < to) begin @(negedge clk); t++; end
    if (n_cmd < c + n) fail("host stopped issuing commands");
  endtask

  // check the write data the host just sent against the xorshift stream
  task automatic check_wdata;
    for (int i = 0; i < 8; i++) begin
      if (last_wr[i] !== xs_ref) fail($sformatf("write dword %0d: %h exp %h", i, last_wr[i], xs_ref));
      xs_ref = xorshift(xs_ref);
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  int i0;
  logic [5:0] exp_lba;
  initial begin
    for (int i = 0; i < 64; i++) for (int j = 0; j < 8; j++) sect[i][j] = 0;
    for (int i = 0; i < 16; i++) begin f[i] = 0; rb[i] = 0; end
    for (int i = 0; i < 8; i++) begin qk[i] = 0; ql[i] = 0; last_wr[i] = 0; end
    rn = 0; rcrc = 0; rcrcp = 0; rlast = 0; rok = 0; flen = 0; fidx = 0; fcrc = 0;
    d_sr = 0; d_bit = 0; wlba = 0;
    dev_reset_link();
    repeat (4) @(negedge clk);
    if (tx_p || tx_n || irq) fail("reset state");
    rst_n = 1;

    // ---------------- bring-up with OOB faults
    bring_up(4);
    i0 = irq_cnt;
    // IDENTIFY, then WRITE/READ walking the LBAs (max LBA 5 -> wrap)
    max_lba = 6'd5;
    wait_cmds(1);
    if (last_cmd !== 8'hEC) fail("first command is not IDENTIFY");
    exp_lba = 0;
    for (int k = 0; k < 8; k++) begin
      wait_cmds(1);
      if (last_cmd !== 8'h35 || last_lba !== exp_lba) fail($sformatf("expected WRITE lba %0d, got %h lba %0d", exp_lba, last_cmd, last_lba));
      wait_cmds(1);
      check_wdata();
      if (last_cmd !== 8'h25 || last_lba !== exp_lba) fail($sformatf("expected READ lba %0d, got %h lba %0d", exp_lba, last_cmd, last_lba));
      exp_lba = (exp_lba == 5) ? 0 : exp_lba + 1;
    end
    expect_irq(i0, 0, "clean traffic");

    // ---------------- link-layer faults on host frames
    i0 = irq_cnt; kn_rerr = 1; wait_cmds(3); expect_irq(i0, 0, "one R_ERR: resend");
    rerr_tgt = 16'h3527;
    i0 = irq_cnt; kn_rerr = 3; wait_cmds(3); expect_irq(i0, 1, "three R_ERR on WRITE: give up");
    rerr_tgt = 16'h0046;
    i0 = irq_cnt; kn_rerr = 3; wait_cmds(3); expect_irq(i0, 1, "three R_ERR on data: give up");
    rerr_tgt = 16'h2527;
    i0 = irq_cnt; kn_rerr = 3; wait_cmds(3); expect_irq(i0, 1, "three R_ERR on READ: give up");
    rerr_tgt = 0;
    i0 = irq_cnt; kn_no_rrdy = 1; wait_cmds(3); expect_irq(i0, 1, "no R_RDY");
    i0 = irq_cnt; kn_no_rok = 1; wait_cmds(3); expect_irq(i0, 1, "no R_OK");
    // ---------------- link-layer faults on device frames
    i0 = irq_cnt; kn_crc = 1; wait_cmds(3); expect_irq(i0, 1, "device CRC error");
    i0 = irq_cnt; kn_abort = 1; wait_cmds(3); expect_irq(i0, 1, "device frame aborted");
    i0 = irq_cnt; enq(K_OVF); wait_cmds(3); expect_irq(i0, 1, "device frame too long");
    i0 = irq_cnt; kn_hold = 1; wait_cmds(3); expect_irq(i0, 1, "X_RDY without SOF");
    i0 = irq_cnt; kn_withdraw = 1; wait_cmds(3); expect_irq(i0, 0, "X_RDY withdrawn");
    i0 = irq_cnt; kn_stat_hold = 1; wait_cmds(3); expect_irq(i0, 1, "no SYNC after R_OK");
    i0 = irq_cnt; kn_garbage = 1; wait_cmds(3); expect_irq(i0, 1, "illegal primitive");
    i0 = irq_cnt; kn_rok_garbage = 1; wait_cmds(3); expect_irq(i0, 1, "garbage while waiting R_OK");
    i0 = irq_cnt; kn_collide = 1; wait_cmds(3); expect_irq(i0, 1, "X_RDY collision + unsolicited D2H");
    // ---------------- command-layer faults
    i0 = irq_cnt; kn_mute = 1; wait_cmds(3); expect_irq(i0, 1, "command timeout");
    i0 = irq_cnt; kn_err = 1; wait_cmds(3); expect_irq(i0, 1, "error status");
    i0 = irq_cnt; kn_pio = 1; wait_cmds(3); expect_irq(i0, 1, "unexpected FIS type");
    i0 = irq_cnt; kn_d2h_short = 1; wait_cmds(3); expect_irq(i0, 1, "short D2H");
    i0 = irq_cnt; kn_rsts_short = 1; wait_cmds(3); expect_irq(i0, 1, "short read status D2H");
    i0 = irq_cnt; kn_data_short = 1; wait_cmds(3); expect_irq(i0, 1, "short Data FIS");
    i0 = irq_cnt; kn_rdbad = 1; wait_cmds(3); expect_irq(i0, 1, "read data mismatch");
    i0 = irq_cnt; kn_wsts_err = 1; wait_cmds(3); expect_irq(i0, 1, "write status error");
    i0 = irq_cnt; kn_wsts_mute = 1; wait_cmds(3); expect_irq(i0, 1, "write status timeout");
    i0 = irq_cnt; kn_rsts_err = 1; wait_cmds(3); expect_irq(i0, 1, "read status error");
    i0 = irq_cnt; kn_rsts_mute = 1; wait_cmds(3); expect_irq(i0, 1, "read status timeout");
    for (int k = 0; k < 6; k++) begin               // every wait state: error / timeout
      i0 = irq_cnt; kn_err = 1; wait_cmds(1); wait_cmds(2); expect_irq(i0, 1, "error status walk");
      i0 = irq_cnt; kn_mute = 1; wait_cmds(1); wait_cmds(2); expect_irq(i0, 1, "timeout walk");
    end

    // ---------------- link loss and re-identification with IDENTIFY faults
    i0 = irq_cnt;
    d_stream = 0; line_idle(40);
    if (irq_cnt - i0 != 1) fail("link loss irq");
    max_lba = 6'd63;
    // IDENTIFY: R_ERR x3, no answer, error status, short Data FIS, wrong
    // FIS, error status after the data, then success
    kn_mute = 1; kn_err = 1; kn_data_short = 1; kn_pio = 1; kn_id_sts_err = 1;
    rerr_tgt = 16'hEC27; kn_rerr = 3;
    i0 = irq_cnt;
    bring_up(1);
    wait_cmds(6);
    if (last_cmd !== 8'hEC) fail("IDENTIFY retries");
    rerr_tgt = 0;
    wait_cmds(140);
    i0 = irq_cnt - i0;
    if (i0 != 6) fail($sformatf("IDENTIFY faults: %0d irq pulses", i0));
    // ---------------- mid-command link loss, device restarts with COMINIT
    d_stream = 0; oob(48);
    max_lba = 6'd0;
    bring_up(2);
    wait_cmds(6);
    if (last_lba !== 0) fail("max LBA 0");
    bring_up(3);                                    // (loss inside bring_up)
    wait_cmds(2);

    // ---------------- reset while the link is up
    @(negedge clk); rst_n = 0;
    repeat (3) @(negedge clk);
    if (tx_p || tx_n || irq) fail("reset state");
    rst_n = 1;
    repeat (10) @(negedge clk);

    $display("TEST %s: SATA (%0d commands)", errors ? "FAILED" : "PASSED", n_cmd);
    $finish;
  end

  initial begin
    #200ms;
    $display("TEST FAILED: SATA (timeout)");
    $finish;
  end

endmodule
