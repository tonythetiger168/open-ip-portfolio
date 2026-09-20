// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for Bluetooth5_top (BLE link layer peripheral).
//  (a) reset state / ADV_IND field-by-field compare after de-whitening (x2),
//  (b) whitening seed verification (ch37 seed 7'h25: correct seed decodes,
//      wrong seed fails CRC, keystream byte check),
//  (c) SCAN_REQ -> SCAN_RSP payload compare,
//  (d) CRC24 corruption -> no SCAN_RSP + irq,
//  (e) unknown PDU type -> discard + irq,
//  (f) CONNECT_REQ -> CONNECTION state + LLData registers,
//  (g) data channel PDU exchange x4 with NESN/SN sequence checks,
//  (h) duplicate SN -> no new rx_evt, still acked,
//  (i) empty PDU keepalive on connection interval,
//  (j) bad-CRC data PDU -> no response + irq.
// TB plays the BLE central (master) with its own CRC24 + whitening model.
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module Bluetooth5_tb;

  localparam logic [31:0] ADV_AA    = 32'h8E89BED6;
  localparam logic [23:0] ADV_CRCI  = 24'h555555;
  localparam logic [6:0]  ADV_WSEED = 7'h25;
  localparam logic [31:0] CONN_AA   = 32'hC1C2C3C4;
  localparam logic [23:0] CONN_CRCI = 24'h123456;
  localparam int          CONN_INTV = 1500;
  localparam logic [5:0]  DCH       = 6'd9;
  localparam logic [6:0]  DSEED     = 7'h09;   // DCH | 1
  localparam logic        LS_CONN_CODE = 1'b1; // mirrors RTL ls_t enum
  localparam logic [7:0]  PRE_BYTE = 8'hAA;    // advertising preamble

  logic clk = 0, rst_n = 0;
  logic rxd = 0, txd, tx_act, irq;
  logic cfg_we = 0;
  logic [4:0] cfg_addr = 0;
  logic [7:0] cfg_wdata = 0;
  int   errors = 0;
  int   irq_cnt = 0;

  Bluetooth5_top #(.ADV_INTV(1200)) dut (
    .clk(clk), .rst_n(rst_n),
    .rxd(rxd), .txd(txd), .tx_act(tx_act),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
    .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSMs probed: RX engine (4) + TX engine (2) + link state (2) = 8 states.
  // =====================================================================
  localparam int BT5_FSM_TOTAL = 8;
  logic [3:0] rx_seen = '0;
  logic [1:0] tx_seen = '0;
  logic [1:0] ll_seen = '0;
  wire  [2:0] rx_st = dut.rxs;
  wire        tx_st = dut.txs;
  wire        ll_st = dut.ll_state;

  int sva_total = 0, sva_fail = 0;
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors = errors + 1;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: dual-edge probe (scheduler failure mode #3 mitigation)
  always @(posedge clk or negedge clk) begin
    if (rx_st < 3'd4) rx_seen[rx_st] <= 1'b1;
    tx_seen[tx_st] <= 1'b1;
    ll_seen[ll_st] <= 1'b1;
  end

  // output-invariant assertion suite (negedge-sampled, NBA settled)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      if (!rst_n_q)
        sva_check(txd === 1'b0 && tx_act === 1'b0 && irq === 1'b0,
                  "A1 reset: outputs quiescent");
    end else begin
      // A2: received data-payload length is bounded by the 16-byte buffer
      // (oversize packets are dropped at RXS_HDR before rx_dlen updates)
      sva_check(dut.rx_dlen <= 5'd16, "A2 rx_dlen <= 16");
      // A3: RX engine state holds a legal encoding (4 of 8 used)
      sva_check(rx_st <= 3'd3, "A3 rxs legal");
      // A4: advertising interval counter bounded by ADV_INTV
      sva_check(dut.adv_timer <= 12'd1200, "A4 adv_timer <= ADV_INTV");
      // A5: connection-event counter bounded by the negotiated interval
      sva_check(dut.conn_timer <= dut.conn_interval, "A5 conn_timer <= interval");
    end
    rst_n_q <= rst_n;
  end
`endif
  always @(posedge clk) if (rst_n && irq) irq_cnt++;

  // ---------------- reference models (same construction as DUT) ------------
  function automatic logic [6:0] white_next(input logic [6:0] l);
    white_next = {l[5:0], l[6] ^ l[3]};
  endfunction

  function automatic logic [23:0] crc24_bit(input logic [23:0] crc,
                                            input logic        b);
    logic fb;
    begin
      fb        = crc[0] ^ b;
      crc24_bit = fb ? ((crc >> 1) ^ 24'h00065B) : (crc >> 1);
    end
  endfunction

  function automatic logic [23:0] crc24_byte(input logic [23:0] crc,
                                             input logic [7:0]  d);
    logic [23:0] c;
    begin
      c = crc;
      for (int i = 0; i < 8; i++) c = crc24_bit(c, d[i]);
      crc24_byte = c;
    end
  endfunction

  // ---------------- host config port helper ---------------------------------
  task automatic cfg_write(input logic [4:0] a, input logic [7:0] d);
    begin
      @(negedge clk);
      cfg_we = 1; cfg_addr = a; cfg_wdata = d;
      @(negedge clk);
      cfg_we = 0;
    end
  endtask

  // ---------------- master (central) packet transmitter ---------------------
  logic [7:0] mp_pay [0:15];         // payload to send
  logic [7:0] wb [0:31];             // wire byte scratch

  task automatic m_send(input logic [31:0] aa,
                        input logic [7:0]  h0,
                        input logic [7:0]  h1,
                        input int          len,
                        input logic [23:0] crc_init,
                        input logic [6:0]  seed,
                        input bit          bad_crc);
    logic [23:0] c;
    logic [6:0]  wl;
    logic        ob;
    int          nw;
    begin
      c = crc24_byte(crc_init, h0);
      c = crc24_byte(c, h1);
      for (int i = 0; i < len; i++) c = crc24_byte(c, mp_pay[i]);
      if (bad_crc) c = c ^ 24'h000001;
      nw = 0;
      wb[nw] = h0; nw++;
      wb[nw] = h1; nw++;
      for (int i = 0; i < len; i++) begin wb[nw] = mp_pay[i]; nw++; end
      wb[nw] = c[7:0];   nw++;
      wb[nw] = c[15:8];  nw++;
      wb[nw] = c[23:16]; nw++;
      wl = seed;
      // preamble 8'hAA, LSB first
      for (int i = 0; i < 8; i++) begin @(negedge clk); rxd = PRE_BYTE[i]; end
      // access address, LSB first
      for (int j = 0; j < 4; j++)
        for (int i = 0; i < 8; i++) begin @(negedge clk); rxd = aa[j*8+i]; end
      // header + payload + CRC, whitened
      for (int j = 0; j < nw; j++) begin
        for (int i = 0; i < 8; i++) begin
          ob = wb[j][i] ^ wl[6];
          wl = white_next(wl);
          @(negedge clk); rxd = ob;
        end
      end
      @(negedge clk); rxd = 1'b0;
    end
  endtask

  // ---------------- DUT packet receiver / decoder ---------------------------
  logic [7:0] raw_b [0:31];          // raw on-air bytes
  logic [7:0] dec_b [0:31];          // de-whitened bytes
  int         rn;                    // bytes captured
  logic       r_got;
  logic [31:0] r_aa;
  logic [7:0]  r_h0, r_h1;

  task automatic m_recv(input int tmo, input logic [6:0] seed);
    logic [6:0] wl;
    int nb, t;
    begin
      rn    = 0;
      r_got = 0;
      t     = 0;
      @(negedge clk);
      while (!tx_act && t < tmo) begin @(negedge clk); t++; end
      if (tx_act) begin
        nb = 0;
        while (tx_act && nb < 256) begin
          raw_b[nb>>3][nb[2:0]] = txd;
          nb++;
          @(negedge clk);
        end
        rn = nb >> 3;
        if (rn >= 10) begin          // runt (preamble+AA+hdr+crc) minimum
          r_got = 1;
          for (int j = 0; j < 32; j++) dec_b[j] = raw_b[j];
          wl = seed;
          for (int j = 5; j < rn; j++)
            for (int i = 0; i < 8; i++) begin
              dec_b[j][i] = raw_b[j][i] ^ wl[6];
              wl = white_next(wl);
            end
          r_aa = {raw_b[4], raw_b[3], raw_b[2], raw_b[1]};
          r_h0 = dec_b[5];
          r_h1 = dec_b[6];
        end
      end
    end
  endtask

  // CRC24 check over dec_b: hdr0,hdr1,payload(len) vs received CRC bytes
  function automatic logic crc_ok(input int len, input logic [23:0] cin);
    logic [23:0] c;
    begin
      c = crc24_byte(cin, dec_b[5]);
      c = crc24_byte(c, dec_b[6]);
      for (int i = 0; i < len; i++) c = crc24_byte(c, dec_b[7+i]);
      crc_ok = ({dec_b[9+len], dec_b[8+len], dec_b[7+len]} == c);
    end
  endfunction

  // wait until DUT transmitter is idle, then a short gap (RX window open)
  task automatic wait_tx_idle;
    int g;
    begin
      while (tx_act) @(negedge clk);
      g = 0;
      while (g < 20) begin @(negedge clk); g++; end
    end
  endtask

  // check one decoded ADV_IND frame field-by-field
  task automatic check_adv(input logic [7:0] exp_pay0);
    begin
      if (!r_got) begin
        errors++; $display("ERROR: no ADV_IND packet received");
      end else begin
      if (r_aa !== ADV_AA) begin
        errors++; $display("ERROR: ADV AA got=%h exp=%h", r_aa, ADV_AA);
      end
      if (r_h0 !== 8'h00) begin
        errors++; $display("ERROR: ADV hdr0 got=%h exp=00 (ADV_IND)", r_h0);
      end
      if (r_h1 !== 8'd16) begin
        errors++; $display("ERROR: ADV len got=%0d exp=16", r_h1);
      end
      for (int i = 0; i < 16; i++) begin
        if (dec_b[7+i] !== (exp_pay0 + i[7:0])) begin
          errors++;
          $display("ERROR: ADV payload[%0d] got=%h exp=%h",
                   i, dec_b[7+i], exp_pay0 + i[7:0]);
        end
      end
      if (!crc_ok(16, ADV_CRCI)) begin
        errors++; $display("ERROR: ADV CRC24 check failed");
      end
      end
    end
  endtask

  // ---------------- main stimulus --------------------------------------------
  int t;
  int irq_before, evt_before;
  int scan_rsp_seen;
  logic [6:0] wk;
  logic [7:0] ks0;
  logic [7:0] exp_sn  [0:3];
  logic [7:0] exp_nesn[0:3];
  logic [7:0] mst_nesn[0:3];

  initial begin
    exp_sn[0]=0; exp_sn[1]=1; exp_sn[2]=1; exp_sn[3]=0;
    exp_nesn[0]=1; exp_nesn[1]=0; exp_nesn[2]=1; exp_nesn[3]=0;
    mst_nesn[0]=1; mst_nesn[1]=1; mst_nesn[2]=0; mst_nesn[3]=0;

    // (0) reset / initial state
    rst_n = 0;
    repeat (10) @(posedge clk);
    if (irq !== 1'b0)    begin errors++; $display("ERROR: irq high during reset"); end
    if (txd !== 1'b0)    begin errors++; $display("ERROR: txd not idle during reset"); end
    if (tx_act !== 1'b0) begin errors++; $display("ERROR: tx_act high during reset"); end
    rst_n = 1;

    // (a) configure advertising payload 8'h30+i, then decode 2 consecutive ADV_IND
    for (int i = 0; i < 16; i++) cfg_write(i[4:0], 8'h30 + i[7:0]);
    m_recv(4000, ADV_WSEED);
    check_adv(8'h30);
    m_recv(4000, ADV_WSEED);
    check_adv(8'h30);
    if (irq_cnt != 0) begin
      errors++; $display("ERROR: irq during clean advertising phase");
    end
    $display("INFO: ADV_IND x2 field-by-field OK");

    // (b) whitening seed verification (ch37 seed must be 7'h25)
    // first whitened byte on air = hdr0 XOR keystream byte 0
    wk  = ADV_WSEED;
    ks0 = 8'd0;
    for (int i = 0; i < 8; i++) begin
      ks0[i] = wk[6];
      wk     = white_next(wk);
    end
    if (raw_b[5] !== ks0) begin      // hdr0 of ADV_IND is 8'h00
      errors++;
      $display("ERROR: whitening keystream mismatch raw_hdr0=%h exp=%h (seed 7'h25)",
               raw_b[5], ks0);
    end
    // decoding the same air bytes with a wrong seed must break the CRC
    begin
      logic [6:0] wl_bad;
      logic [23:0] c_bad;
      wl_bad = 7'h26;
      for (int j = 5; j < rn; j++)
        for (int i = 0; i < 8; i++) begin
          dec_b[j][i] = raw_b[j][i] ^ wl_bad[6];
          wl_bad = white_next(wl_bad);
        end
      c_bad = crc24_byte(ADV_CRCI, dec_b[5]);
      c_bad = crc24_byte(c_bad, dec_b[6]);
      for (int i = 0; i < 16; i++) c_bad = crc24_byte(c_bad, dec_b[7+i]);
      if ({dec_b[25], dec_b[24], dec_b[23]} == c_bad) begin
        errors++;
        $display("ERROR: wrong whitening seed still yields valid CRC");
      end
    end
    m_recv(4000, ADV_WSEED);         // restore decoder state with a fresh ADV
    check_adv(8'h30);
    $display("INFO: whitening seed 7'h25 verified");

    // (c) SCAN_REQ -> SCAN_RSP
    wait_tx_idle;
    for (int i = 0; i < 12; i++) mp_pay[i] = 8'hC0 + i[7:0];
    m_send(ADV_AA, 8'h03, 8'd12, 12, ADV_CRCI, ADV_WSEED, 1'b0);
    scan_rsp_seen = 0;
    for (int n = 0; n < 4 && !scan_rsp_seen; n++) begin
      m_recv(2500, ADV_WSEED);
      if (r_got && r_h0[3:0] == 4'h4) begin
        scan_rsp_seen = 1;
        if (r_h1 !== 8'd16) begin
          errors++; $display("ERROR: SCAN_RSP len got=%0d exp=16", r_h1);
        end
        for (int i = 0; i < 16; i++) begin
          if (dec_b[7+i] !== (8'h53 + i[7:0])) begin
            errors++;
            $display("ERROR: SCAN_RSP payload[%0d] got=%h exp=%h",
                     i, dec_b[7+i], 8'h53 + i[7:0]);
          end
        end
        if (!crc_ok(16, ADV_CRCI)) begin
          errors++; $display("ERROR: SCAN_RSP CRC24 check failed");
        end
      end
    end
    if (!scan_rsp_seen) begin
      errors++; $display("ERROR: no SCAN_RSP after SCAN_REQ");
    end
    $display("INFO: SCAN_REQ -> SCAN_RSP OK");

    // (d) CRC24 corrupted SCAN_REQ -> discard + irq, no SCAN_RSP
    irq_before = irq_cnt;
    wait_tx_idle;
    m_send(ADV_AA, 8'h03, 8'd12, 12, ADV_CRCI, ADV_WSEED, 1'b1);
    scan_rsp_seen = 0;
    for (int n = 0; n < 5; n++) begin
      m_recv(2500, ADV_WSEED);
      if (r_got && r_h0[3:0] == 4'h4) scan_rsp_seen = 1;
    end
    if (scan_rsp_seen) begin
      errors++; $display("ERROR: SCAN_RSP sent for CRC-bad SCAN_REQ");
    end
    if (irq_cnt == irq_before) begin
      errors++; $display("ERROR: no irq after CRC-bad SCAN_REQ");
    end
    if (dut.crc_err_cnt < 1) begin
      errors++; $display("ERROR: crc_err_cnt did not increment");
    end
    $display("INFO: bad-CRC SCAN_REQ discarded + irq");

    // (e) unknown PDU type -> discard + irq
    irq_before = irq_cnt;
    wait_tx_idle;
    m_send(ADV_AA, 8'h09, 8'd0, 0, ADV_CRCI, ADV_WSEED, 1'b0);
    t = 0;
    while (irq_cnt == irq_before && t < 600) begin @(posedge clk); t++; end
    if (irq_cnt == irq_before) begin
      errors++; $display("ERROR: no irq after unknown PDU type");
    end
    $display("INFO: unknown PDU type discarded + irq");

    // (f) CONNECT_REQ -> CONNECTION
    wait_tx_idle;
    mp_pay[0]  = CONN_AA[7:0];    mp_pay[1]  = CONN_AA[15:8];
    mp_pay[2]  = CONN_AA[23:16];  mp_pay[3]  = CONN_AA[31:24];
    mp_pay[4]  = CONN_CRCI[7:0];  mp_pay[5]  = CONN_CRCI[15:8];
    mp_pay[6]  = CONN_CRCI[23:16];
    mp_pay[7]  = CONN_INTV[7:0];  mp_pay[8]  = CONN_INTV[15:8];
    mp_pay[9]  = 8'd0;            mp_pay[10] = 8'd0;   // latency
    mp_pay[11] = 8'hB8;           mp_pay[12] = 8'h0B;  // timeout 3000
    mp_pay[13] = 8'd5;                                 // hop increment
    mp_pay[14] = 8'd9;                                 // channel map -> ch 9
    m_send(ADV_AA, 8'h05, 8'd15, 15, ADV_CRCI, ADV_WSEED, 1'b0);
    repeat (50) @(posedge clk);
    if (dut.ll_state !== LS_CONN_CODE) begin
      errors++; $display("ERROR: no CONNECTION state after CONNECT_REQ");
    end
    if (dut.conn_aa !== CONN_AA) begin
      errors++; $display("ERROR: conn_aa got=%h exp=%h", dut.conn_aa, CONN_AA);
    end
    if (dut.conn_crci !== CONN_CRCI) begin
      errors++;
      $display("ERROR: conn_crci got=%h exp=%h", dut.conn_crci, CONN_CRCI);
    end
    if (dut.conn_interval !== 16'(CONN_INTV)) begin
      errors++;
      $display("ERROR: conn_interval got=%0d exp=%0d", dut.conn_interval, CONN_INTV);
    end
    if (dut.dch !== DCH) begin
      errors++; $display("ERROR: dch got=%0d exp=%0d", dut.dch, DCH);
    end
    $display("INFO: CONNECT_REQ -> CONNECTION, LLData stored");

    // (g) data channel PDUs x4 with NESN/SN sequence checks
    irq_before = irq_cnt;
    for (int k = 0; k < 4; k++) begin
      for (int i = 0; i < 8; i++) mp_pay[i] = 8'h40 + k[7:0]*8 + i[7:0];
      m_send(CONN_AA, {3'b000, 1'b0, mst_nesn[k][0], 1'(k[0]), 2'b01},
             8'(2+k), 2+k, CONN_CRCI, DSEED, 1'b0);
      m_recv(800, DSEED);
      if (!r_got) begin
        errors++; $display("ERROR: no response to data PDU %0d", k);
      end else begin
        if (r_aa !== CONN_AA) begin
          errors++; $display("ERROR: rsp%0d AA got=%h exp=%h", k, r_aa, CONN_AA);
        end
        if (r_h0[1:0] !== 2'b01 || r_h1 !== 8'd0) begin
          errors++;
          $display("ERROR: rsp%0d not empty LL data PDU (h0=%h h1=%h)", k, r_h0, r_h1);
        end
        if (r_h0[2] !== exp_sn[k][0]) begin
          errors++;
          $display("ERROR: rsp%0d SN got=%b exp=%b", k, r_h0[2], exp_sn[k][0]);
        end
        if (r_h0[3] !== exp_nesn[k][0]) begin
          errors++;
          $display("ERROR: rsp%0d NESN got=%b exp=%b", k, r_h0[3], exp_nesn[k][0]);
        end
        if (!crc_ok(0, CONN_CRCI)) begin
          errors++; $display("ERROR: rsp%0d CRC24 check failed", k);
        end
      end
      if (dut.rx_evt_cnt !== 16'(k+1)) begin
        errors++;
        $display("ERROR: rx_evt_cnt got=%0d exp=%0d after PDU %0d",
                 dut.rx_evt_cnt, k+1, k);
      end
      if (dut.rx_dlen !== 5'(2+k)) begin
        errors++;
        $display("ERROR: rx_dlen got=%0d exp=%0d", dut.rx_dlen, 2+k);
      end
      for (int i = 0; i < 2+k; i++) begin
        if (dut.rx_buf[i] !== (8'h40 + k[7:0]*8 + i[7:0])) begin
          errors++;
          $display("ERROR: rx_buf[%0d] got=%h exp=%h (PDU %0d)",
                   i, dut.rx_buf[i], 8'h40 + k[7:0]*8 + i[7:0], k);
        end
      end
    end
    if (dut.rx_sn !== 1'b0 || dut.tx_sn !== 1'b0) begin
      errors++;
      $display("ERROR: NESN/SN state after 4 PDUs rx_sn=%b tx_sn=%b exp=0/0",
               dut.rx_sn, dut.tx_sn);
    end
    if (irq_cnt != irq_before) begin
      errors++; $display("ERROR: unexpected irq during data phase");
    end
    $display("INFO: 4 data PDUs exchanged, NESN/SN sequence OK");

    // (h) duplicate SN retransmission -> no new rx_evt, still acked
    evt_before = dut.rx_evt_cnt;
    for (int i = 0; i < 8; i++) mp_pay[i] = 8'h77 + i[7:0];
    m_send(CONN_AA, {3'b000, 1'b0, 1'b0, 1'b1, 2'b01}, 8'd5, 5,
           CONN_CRCI, DSEED, 1'b0);
    m_recv(800, DSEED);
    if (!r_got) begin
      errors++; $display("ERROR: no ack for duplicate-SN PDU");
    end else if (r_h0[3] !== 1'b0) begin
      errors++; $display("ERROR: dup ack NESN got=%b exp=0", r_h0[3]);
    end
    if (dut.rx_evt_cnt !== 16'(evt_before)) begin
      errors++;
      $display("ERROR: duplicate-SN PDU wrongly accepted (rx_evt_cnt=%0d)",
               dut.rx_evt_cnt);
    end
    $display("INFO: duplicate-SN PDU acked but not accepted");

    // (i) empty PDU keepalive on connection interval
    m_recv(2*CONN_INTV + 1500, DSEED);
    if (!r_got) begin
      errors++; $display("ERROR: no keepalive empty PDU within 2 intervals");
    end else begin
      if (r_h0[1:0] !== 2'b01 || r_h1 !== 8'd0) begin
        errors++;
        $display("ERROR: keepalive not an empty PDU (h0=%h h1=%h)", r_h0, r_h1);
      end
      if (!crc_ok(0, CONN_CRCI)) begin
        errors++; $display("ERROR: keepalive CRC24 check failed");
      end
    end
    $display("INFO: keepalive empty PDU OK");

    // (j) bad-CRC data PDU -> no response + irq
    // first a good PDU to suppress keepalive for >= 1 interval
    for (int i = 0; i < 3; i++) mp_pay[i] = 8'h90 + i[7:0];
    m_send(CONN_AA, {3'b000, 1'b0, 1'b1, 1'b0, 2'b01}, 8'd3, 3,
           CONN_CRCI, DSEED, 1'b0);
    m_recv(800, DSEED);
    if (!r_got) begin
      errors++; $display("ERROR: no response to good PDU in phase (j)");
    end
    evt_before = dut.rx_evt_cnt;
    irq_before = irq_cnt;
    m_send(CONN_AA, {3'b000, 1'b0, 1'b1, 1'b1, 2'b01}, 8'd3, 3,
           CONN_CRCI, DSEED, 1'b1);
    m_recv(600, DSEED);              // keepalive-free window: no response allowed
    if (r_got) begin
      errors++; $display("ERROR: response sent for CRC-bad data PDU");
    end
    if (irq_cnt == irq_before) begin
      errors++; $display("ERROR: no irq after CRC-bad data PDU");
    end
    if (dut.rx_evt_cnt !== 16'(evt_before)) begin
      errors++; $display("ERROR: CRC-bad data PDU wrongly accepted");
    end
    $display("INFO: bad-CRC data PDU discarded + irq");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // Re-reset into advertising, then: random adv payloads (decode+CRC cmp),
    // random SCAN_REQ->SCAN_RSP, unknown-PDU / bad-CRC injections, reconnect,
    // random data-channel PDUs with SN tracking (ack + rx_buf payload cmp +
    // rx_evt count), reserved-LLID and bad-CRC data injections. Self-checked
    // with the shared m_send/m_recv/crc24/whitening models.
    begin : crv_phase
      int n_adv=0, n_scan=0, n_unk=0, n_badc=0, n_data=0, n_rsvd=0;
      logic [7:0] rp [0:15];
      logic [7:0] pdu_h0;
      logic       m_sn;
      int         evt_model;
      int         len_v, ib;

      // ---- re-enter advertising state ----
      rst_n = 1'b0; repeat (6) @(posedge clk);
      rst_n = 1'b1; repeat (6) @(posedge clk);

      // (a) 10 random advertising payloads -> ADV_IND decode + CRC + byte cmp
      for (int r=0; r<10; r++) begin
        for (int i=0; i<16; i++) begin rp[i]=$urandom_range(255,0); cfg_write(i[4:0], rp[i]); end
        m_recv(4000, ADV_WSEED);
        if (!r_got) begin errors++; $display("ERROR: CRV no ADV_IND r=%0d", r); end
        else begin
          if (r_aa !== ADV_AA) begin errors++; $display("ERROR: CRV adv AA %h", r_aa); end
          for (int i=0; i<16; i++)
            if (dec_b[7+i] !== rp[i]) begin
              errors++; $display("ERROR: CRV adv pay[%0d] %h exp %h", i, dec_b[7+i], rp[i]);
            end
          if (!crc_ok(16, ADV_CRCI)) begin errors++; $display("ERROR: CRV adv CRC"); end
        end
        n_adv++;
      end
      cfg_write(5'd16, 8'h00);   // adv_en=0: stop periodic ADV_IND (rx_en=!tx_act)

      // (b) 5 random SCAN_REQ -> SCAN_RSP (fixed 8'h53+i payload)
      for (int r=0; r<5; r++) begin
        wait_tx_idle;
        for (int i=0; i<12; i++) mp_pay[i]=$urandom_range(255,0);
        m_send(ADV_AA, 8'h03, 8'd12, 12, ADV_CRCI, ADV_WSEED, 1'b0);
        scan_rsp_seen = 0;
        for (int n=0; n<7 && !scan_rsp_seen; n++) begin
          m_recv(3200, ADV_WSEED);
          if (r_got && r_h0[3:0]==4'h4) begin
            scan_rsp_seen = 1;
            for (int i=0; i<16; i++)
              if (dec_b[7+i] !== (8'h53+i[7:0])) begin
                errors++; $display("ERROR: CRV scan_rsp[%0d] %h", i, dec_b[7+i]);
              end
            if (!crc_ok(16, ADV_CRCI)) begin errors++; $display("ERROR: CRV scan_rsp CRC"); end
          end
        end
        if (!scan_rsp_seen) begin errors++; $display("ERROR: CRV no SCAN_RSP r=%0d", r); end
        n_scan++;
      end

      // (c) 4 unknown advertising PDU types (7..15) -> discard + irq
      for (int r=0; r<4; r++) begin
        irq_before = irq_cnt;
        wait_tx_idle;
        m_send(ADV_AA, {4'h0, 4'(7 + $urandom_range(8,0))}, 8'd0, 0, ADV_CRCI, ADV_WSEED, 1'b0);
        t = 0;
        while (irq_cnt == irq_before && t < 1500) begin @(posedge clk); t++; end
        if (irq_cnt == irq_before) begin
          errors++; $display("ERROR: CRV no irq on unknown PDU r=%0d", r);
        end
        n_unk++;
      end

      // (d) 3 bad-CRC SCAN_REQ -> discard + irq, no SCAN_RSP
      for (int r=0; r<3; r++) begin
        irq_before = irq_cnt;
        wait_tx_idle;
        for (int i=0; i<12; i++) mp_pay[i]=$urandom_range(255,0);
        m_send(ADV_AA, 8'h03, 8'd12, 12, ADV_CRCI, ADV_WSEED, 1'b1);
        scan_rsp_seen = 0;
        for (int n=0; n<5; n++) begin
          m_recv(2500, ADV_WSEED);
          if (r_got && r_h0[3:0]==4'h4) scan_rsp_seen = 1;
        end
        if (scan_rsp_seen) begin errors++; $display("ERROR: CRV SCAN_RSP for bad CRC r=%0d", r); end
        if (irq_cnt == irq_before) begin errors++; $display("ERROR: CRV no irq bad CRC scan r=%0d", r); end
        n_badc++;
      end

      // ---- reconnect (fresh CONNECT_REQ) ----
      wait_tx_idle;
      mp_pay[0]=CONN_AA[7:0];   mp_pay[1]=CONN_AA[15:8];
      mp_pay[2]=CONN_AA[23:16]; mp_pay[3]=CONN_AA[31:24];
      mp_pay[4]=CONN_CRCI[7:0]; mp_pay[5]=CONN_CRCI[15:8]; mp_pay[6]=CONN_CRCI[23:16];
      mp_pay[7]=CONN_INTV[7:0]; mp_pay[8]=CONN_INTV[15:8];
      mp_pay[9]=8'd0; mp_pay[10]=8'd0;
      mp_pay[11]=8'hB8; mp_pay[12]=8'h0B;
      mp_pay[13]=8'd5; mp_pay[14]=8'd9;
      m_send(ADV_AA, 8'h05, 8'd15, 15, ADV_CRCI, ADV_WSEED, 1'b0);
      repeat (50) @(posedge clk);
      if (dut.ll_state !== LS_CONN_CODE) begin
        errors++; $display("ERROR: CRV no reconnect");
      end

      // (e) 30 random data-channel PDUs with SN tracking
      m_sn      = 1'b0;
      evt_model = dut.rx_evt_cnt;
      for (int k=0; k<30; k++) begin
        len_v = (k % 5 == 0) ? 16 : (1 + $urandom_range(15, 0));  // ensure len=16 hits
        for (int i=0; i<16; i++) mp_pay[i]=$urandom_range(255,0);
        // hdr0: llid=01, nesn=0 (keeps tx_sn==0), sn=m_sn; randomise the
        // md/rfu high nibble (ignored by the DUT) to toggle hdr0_r[7:4]
        pdu_h0 = {4'($urandom_range(15,0)), 1'b0, m_sn, 2'b01};
        m_send(CONN_AA, pdu_h0, 8'(len_v), len_v, CONN_CRCI, DSEED, 1'b0);
        m_recv(800, DSEED);
        if (!r_got) begin errors++; $display("ERROR: CRV no data ack k=%0d", k); end
        else begin
          if (r_h0[1:0] !== 2'b01 || r_h1 !== 8'd0) begin
            errors++; $display("ERROR: CRV data ack not empty PDU k=%0d h0=%h h1=%h", k, r_h0, r_h1);
          end
          if (!crc_ok(0, CONN_CRCI)) begin errors++; $display("ERROR: CRV data ack CRC k=%0d", k); end
        end
        evt_model = evt_model + 1;
        if (dut.rx_evt_cnt !== 16'(evt_model)) begin
          errors++; $display("ERROR: CRV rx_evt_cnt %0d exp %0d k=%0d", dut.rx_evt_cnt, evt_model, k);
        end
        if (dut.rx_dlen !== 5'(len_v)) begin
          errors++; $display("ERROR: CRV rx_dlen %0d exp %0d k=%0d", dut.rx_dlen, len_v, k);
        end
        for (int i=0; i<len_v; i++)
          if (dut.rx_buf[i] !== mp_pay[i]) begin
            errors++; $display("ERROR: CRV rx_buf[%0d] %h exp %h k=%0d", i, dut.rx_buf[i], mp_pay[i], k);
          end
        m_sn = ~m_sn;
        n_data++;
      end

      // (f) 3 reserved-LLID (2'b00) data PDUs -> protocol error + irq
      for (int r=0; r<3; r++) begin
        irq_before = irq_cnt;
        for (int i=0; i<4; i++) mp_pay[i]=$urandom_range(255,0);
        m_sn = ~m_sn;
        m_send(CONN_AA, {3'b000, 1'b0, 1'b0, m_sn, 2'b00}, 8'd4, 4, CONN_CRCI, DSEED, 1'b0);
        t = 0;
        while (irq_cnt == irq_before && t < 600) begin @(posedge clk); t++; end
        if (irq_cnt == irq_before) begin
          errors++; $display("ERROR: CRV no irq on reserved LLID r=%0d", r);
        end
        n_rsvd++;
      end

      // (g) 3 bad-CRC data PDUs -> discard + irq
      for (int r=0; r<3; r++) begin
        irq_before = irq_cnt;
        for (int i=0; i<4; i++) mp_pay[i]=$urandom_range(255,0);
        m_send(CONN_AA, {3'b000, 1'b0, 1'b0, m_sn, 2'b01}, 8'd4, 4, CONN_CRCI, DSEED, 1'b1);
        t = 0;
        while (irq_cnt == irq_before && t < 600) begin @(posedge clk); t++; end
        if (irq_cnt == irq_before) begin
          errors++; $display("ERROR: CRV no irq on bad-CRC data r=%0d", r);
        end
        n_badc++;
      end
      // (h) 8 random CONNECT_REQ cycles: each re-resets then connects with a
      // fully random LLData, toggling the captured connection-parameter
      // registers (conn_aa/crci/interval/latency/timeout/chm/hop + *_cur).
      for (int c=0; c<8; c++) begin
        rst_n = 1'b0; repeat (6) @(posedge clk);
        rst_n = 1'b1; repeat (6) @(posedge clk);
        cfg_write(5'd16, 8'h00);                 // adv off
        for (int i=0; i<15; i++) mp_pay[i]=$urandom_range(255,0);
        m_send(ADV_AA, 8'h05, 8'd15, 15, ADV_CRCI, ADV_WSEED, 1'b0);
        t = 0;
        while (dut.ll_state !== LS_CONN_CODE && t < 400) begin @(posedge clk); t++; end
        if (dut.ll_state !== LS_CONN_CODE) begin
          errors++; $display("ERROR: CRV random connect %0d failed", c);
        end
      end
            $display("CRV: adv=%0d scan=%0d unk=%0d data=%0d rsvd=%0d badc=%0d",
               n_adv, n_scan, n_unk, n_data, n_rsvd, n_badc);
    end
`endif

    // summary
    if (errors == 0) $display("TEST PASSED: Bluetooth5");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s=0; s<4; s++) visited += rx_seen[s];
      for (int s=0; s<2; s++) visited += tx_seen[s];
      for (int s=0; s<2; s++) visited += ll_seen[s];
      $display("FSM_COV: %0d/%0d", visited, BT5_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard
  initial begin
    repeat (6000) #1000;
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #4000000;
    $display("TIMEOUT");
    $finish;
  end
`endif

endmodule
