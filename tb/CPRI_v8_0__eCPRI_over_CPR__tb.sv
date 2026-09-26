// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for CPRI_v8_0__eCPRI_over_CPR__top -- CPRI master.
// TB plays the RE (slave) peer: full 8b/10b encode/decode, hyperframe-aligned
// K28.5 reply after the master comma (sync handshake), L1 inband version/rate
// negotiation slow stream, IQ byte stream with per-byte logging, plus
// loss-of-sync and code-violation injection.
// Checks: reset / sync handshake / hyperframe boundary (comma gap == 1024,
// 0x50 stuff bytes, TX IQ pattern) / IQ capture buffer compare / L1
// negotiation in both directions / loss-of-sync -> irq + resync recovery /
// code violation -> irq / irq clear.
`timescale 1ns/1ps
module CPRI_v8_0__eCPRI_over_CPR__tb;
  localparam int DW = 32, AW = 32;
  localparam logic [7:0] K28_5 = 8'hBC;
  localparam logic [3:0] PEER_VER  = 4'd3;
  localparam logic [3:0] PEER_RATE = 4'd5;

  logic clk = 0, rst_n = 0;
  logic [9:0]  rx_sym;
  logic [9:0]  tx_sym;
  logic        cpu_we, cpu_re;
  logic [3:0]  cpu_addr;
  logic [31:0] cpu_wdata, cpu_rdata;
  logic        irq;

  int errors = 0;

  CPRI_v8_0__eCPRI_over_CPR__top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .rx_sym(rx_sym), .tx_sym(tx_sym),
    .cpu_we(cpu_we), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.sync_st (ST_HUNT/ST_ALIGN/ST_SYNC), 3 states.
  // =====================================================================
  localparam int CPRI_FSM_TOTAL = 3;
  logic [2:0] fsm_seen = '0;          // visited-state bitmap
  wire  [1:0] dut_state = dut.sync_st;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
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

  // FSM coverage: sample DUT state register on both edges (scheduler
  // failure mode #3 mitigation: dual-edge probe tolerates lost wakeups)
  always @(posedge clk or negedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (level/comb checks, negedge-sampled
  // so all NBA updates are settled; no history-dependent properties)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(dut_state == 2'd0 && dut.iq_cnt == 6'd0 && irq === 1'b0,
                  "A1 reset: HUNT + empty buffer + no irq");
    end else begin
      // A2: state register holds a legal encoding (3 of 4 used)
      sva_check(dut_state <= 2'd2, "A2 sync_st legal");
      // A3: irq output is exactly the OR of the two sticky sources
      sva_check(irq === (dut.irq_los | dut.irq_cv), "A3 irq == los|cv");
      // A4: IQ occupancy bounded by the 32-entry buffer
      sva_check(dut.iq_cnt <= 6'd32, "A4 iq_cnt <= 32");
      // A5: loss-of-sync miss counter bounded (declares LOS at 4)
      sva_check(dut.miss_cnt <= 3'd4, "A5 miss_cnt <= 4");
    end
    rst_n_q <= rst_n;
  end
`endif

  // ------------------------------------------------------------------
  // 8b/10b model (independent copy of the line code)
  // ------------------------------------------------------------------
  function automatic logic is_bal6(input logic [5:0] c);
    logic [2:0] n;
    begin
      n = {2'b00, c[0]} + {2'b00, c[1]} + {2'b00, c[2]}
        + {2'b00, c[3]} + {2'b00, c[4]} + {2'b00, c[5]};
      is_bal6 = (n == 3'd3);
    end
  endfunction

  function automatic logic is_bal4(input logic [3:0] c);
    logic [2:0] n;
    begin
      n = {2'b00, c[0]} + {2'b00, c[1]} + {2'b00, c[2]} + {2'b00, c[3]};
      is_bal4 = (n == 3'd2);
    end
  endfunction

  function automatic logic [10:0] enc8b10b(input logic [7:0] d,
                                           input logic       k,
                                           input logic       rd);
    logic [5:0] c6;
    logic [3:0] c4;
    logic       rd1;
    begin
      if (k) c6 = rd ? 6'b110000 : 6'b001111;
      else
        case (d[4:0])
          5'd0 : c6 = rd ? 6'b011000 : 6'b100111;
          5'd1 : c6 = rd ? 6'b100010 : 6'b011101;
          5'd2 : c6 = rd ? 6'b010010 : 6'b101101;
          5'd3 : c6 = 6'b110001;
          5'd4 : c6 = rd ? 6'b001010 : 6'b110101;
          5'd5 : c6 = 6'b101001;
          5'd6 : c6 = 6'b011001;
          5'd7 : c6 = rd ? 6'b000111 : 6'b111000;
          5'd8 : c6 = rd ? 6'b000110 : 6'b111001;
          5'd9 : c6 = 6'b100101;
          5'd10: c6 = 6'b010101;
          5'd11: c6 = 6'b110100;
          5'd12: c6 = 6'b001101;
          5'd13: c6 = 6'b101100;
          5'd14: c6 = 6'b011100;
          5'd15: c6 = rd ? 6'b101000 : 6'b010111;
          5'd16: c6 = rd ? 6'b100100 : 6'b011011;
          5'd17: c6 = 6'b100011;
          5'd18: c6 = 6'b010011;
          5'd19: c6 = 6'b110010;
          5'd20: c6 = 6'b001011;
          5'd21: c6 = 6'b101010;
          5'd22: c6 = 6'b011010;
          5'd23: c6 = rd ? 6'b000101 : 6'b111010;
          5'd24: c6 = rd ? 6'b001100 : 6'b110011;
          5'd25: c6 = 6'b100110;
          5'd26: c6 = 6'b010110;
          5'd27: c6 = rd ? 6'b001001 : 6'b110110;
          5'd28: c6 = 6'b001110;
          5'd29: c6 = rd ? 6'b010001 : 6'b101110;
          5'd30: c6 = rd ? 6'b100001 : 6'b011110;
          default: c6 = rd ? 6'b010100 : 6'b101011;
        endcase
      rd1 = rd ^ ~is_bal6(c6);
      if (k && (d[7:5] == 3'd7)) c4 = rd1 ? 4'b1000 : 4'b0111;
      else
        case (d[7:5])
          3'd0 : c4 = rd1 ? 4'b0100 : 4'b1011;
          3'd1 : c4 = 4'b1001;
          3'd2 : c4 = 4'b0101;
          3'd3 : c4 = rd1 ? 4'b0011 : 4'b1100;
          3'd4 : c4 = rd1 ? 4'b0010 : 4'b1101;
          3'd5 : c4 = 4'b1010;
          3'd6 : c4 = 4'b0110;
          default: c4 = rd1 ? 4'b0001 : 4'b1110;
        endcase
      enc8b10b = {rd1 ^ ~is_bal4(c4), c6, c4};
    end
  endfunction

  function automatic logic [9:0] dec8b10b(input logic [9:0] s);
    logic [5:0] c6;
    logic [3:0] c4;
    logic       v6, v4, kk;
    logic [4:0] y;
    logic [2:0] x;
    begin
      c6 = s[9:4];
      c4 = s[3:0];
      v6 = 1'b1; kk = 1'b0; y = 5'd0;
      case (c6)
        6'b100111, 6'b011000: y = 5'd0;
        6'b011101, 6'b100010: y = 5'd1;
        6'b101101, 6'b010010: y = 5'd2;
        6'b110001:            y = 5'd3;
        6'b110101, 6'b001010: y = 5'd4;
        6'b101001:            y = 5'd5;
        6'b011001:            y = 5'd6;
        6'b111000, 6'b000111: y = 5'd7;
        6'b111001, 6'b000110: y = 5'd8;
        6'b100101:            y = 5'd9;
        6'b010101:            y = 5'd10;
        6'b110100:            y = 5'd11;
        6'b001101:            y = 5'd12;
        6'b101100:            y = 5'd13;
        6'b011100:            y = 5'd14;
        6'b010111, 6'b101000: y = 5'd15;
        6'b011011, 6'b100100: y = 5'd16;
        6'b100011:            y = 5'd17;
        6'b010011:            y = 5'd18;
        6'b110010:            y = 5'd19;
        6'b001011:            y = 5'd20;
        6'b101010:            y = 5'd21;
        6'b011010:            y = 5'd22;
        6'b111010, 6'b000101: y = 5'd23;
        6'b110011, 6'b001100: y = 5'd24;
        6'b100110:            y = 5'd25;
        6'b010110:            y = 5'd26;
        6'b110110, 6'b001001: y = 5'd27;
        6'b001110:            y = 5'd28;
        6'b001111, 6'b110000: begin y = 5'd28; kk = 1'b1; end
        6'b101110, 6'b010001: y = 5'd29;
        6'b011110, 6'b100001: y = 5'd30;
        6'b101011, 6'b010100: y = 5'd31;
        default:              v6 = 1'b0;
      endcase
      v4 = 1'b1; x = 3'd0;
      case (c4)
        4'b1011, 4'b0100:                   x = 3'd0;
        4'b1001:                            x = 3'd1;
        4'b0101:                            x = 3'd2;
        4'b1100, 4'b0011:                   x = 3'd3;
        4'b1101, 4'b0010:                   x = 3'd4;
        4'b1010:                            x = 3'd5;
        4'b0110:                            x = 3'd6;
        4'b1110, 4'b0001, 4'b0111, 4'b1000: x = 3'd7;
        default:                            v4 = 1'b0;
      endcase
      dec8b10b = {v6 & v4, kk, x, y};
    end
  endfunction

  // ------------------------------------------------------------------
  // peer (RE) model: hyperframe stream replied after master comma
  // ------------------------------------------------------------------
  bit         peer_on;
  int         los_skip;      // remaining hyperframes with comma suppressed
  bit         cv_inject;     // inject one invalid code group at wcnt 500
  logic       peer_rd;
  int         peer_wcnt;     // 0..1023 position inside peer hyperframe
  int         peer_hf;       // hyperframe counter since peer start
  int         peer_hfi;      // 0..15 L1 slow-stream position
  int         iqsent;
  int         iq_base;       // iqsent value at DUT sync entry
  logic [7:0] iq_log [0:8191];
  logic [7:0] pb_b;
  logic       pb_isk;

  function automatic logic [7:0] peer_l1(input int hfi);
    begin
      case (hfi)
        0      : peer_l1 = 8'h5A;
        1      : peer_l1 = {4'h0, PEER_VER};
        2      : peer_l1 = {4'd1, PEER_RATE};        // {pointer p, rate}
        15     : peer_l1 = {4'h0, PEER_VER} ^ {4'd1, PEER_RATE} ^ 8'hA5;
        default: peer_l1 = 8'h00;
      endcase
    end
  endfunction

  function automatic logic [7:0] iq_pat(input int i);
    begin
      iq_pat = ((i * 53) + 17) & 8'hFF;
    end
  endfunction

  initial begin
    peer_on   = 0;
    los_skip  = 0;
    cv_inject = 0;
    peer_rd   = 0;
    peer_wcnt = 0;
    peer_hf   = 0;
    peer_hfi  = 0;
    iqsent    = 0;
    iq_base   = -1;
    rx_sym    = 10'h0;
  end

  // peer stream driver (one symbol per clock, driven on negedge)
  always @(negedge clk) begin
    if (peer_on) begin
      pb_b   = 8'h00;
      pb_isk = 1'b0;
      if ((peer_wcnt & 15) == 0) begin
        if ((peer_wcnt >> 4) == 0) begin
          if (los_skip == 0) begin pb_isk = 1'b1; pb_b = K28_5; end
        end else if ((peer_wcnt >> 4) == 1) pb_b = peer_l1(peer_hfi);
        else if ((peer_wcnt >> 4) == 4) pb_b = 8'h5C;          // vendor byte
      end else if ((peer_wcnt >> 4) == 0 && (peer_wcnt & 15) <= 2) begin
        pb_b = 8'h50;                                          // sync stuff
      end else begin
        pb_b = iq_pat(iqsent);                                 // IQ byte
        iq_log[iqsent & 8191] = pb_b;
        if (peer_hf == 2 && peer_wcnt == 3 && iq_base < 0)
          iq_base = iqsent;      // DUT enters SYNC at 3rd peer comma
        iqsent = iqsent + 1;
      end
      if (cv_inject && peer_wcnt == 500) begin
        rx_sym    = 10'b00_0000_0000;   // invalid code group
        cv_inject = 0;
      end else begin
        {peer_rd, rx_sym} = enc8b10b(pb_b, pb_isk, peer_rd);
      end
      if (peer_wcnt == 1023) begin
        peer_wcnt = 0;
        peer_hf   = peer_hf + 1;
        peer_hfi  = (peer_hfi + 1) & 15;
        if (los_skip > 0) los_skip = los_skip - 1;
      end else begin
        peer_wcnt = peer_wcnt + 1;
      end
    end else begin
      {peer_rd, rx_sym} = enc8b10b(8'h00, 1'b0, peer_rd);      // idle D0.0
    end
  end

  // ------------------------------------------------------------------
  // master line monitor: comma gaps, stuff bytes, L1 stream, IQ pattern
  // ------------------------------------------------------------------
  int         cyc;
  int         m_phase;       // expected position of the symbol being sampled
  int         last_comma;
  int         first_comma;
  int         ngaps;
  int         comma_gaps [0:7];
  int         ml1_n;
  logic [7:0] ml1 [0:63];
  logic [9:0] dec;
  bit         iqpat_checked;

  initial begin
    cyc = 0; m_phase = -1; last_comma = -1; first_comma = -1;
    ngaps = 0; ml1_n = 0; iqpat_checked = 0;
  end

  always @(posedge clk) begin
    cyc = cyc + 1;
    dec = dec8b10b(tx_sym);
    if (dec[9] && dec[8] && dec[7:0] == K28_5) begin
      if (first_comma < 0) first_comma = cyc;
      if (last_comma >= 0 && ngaps < 8) begin
        comma_gaps[ngaps] = cyc - last_comma;
        ngaps = ngaps + 1;
      end
      last_comma = cyc;
      m_phase = 1;
    end else begin
      if (m_phase == 1 || m_phase == 2) begin
        if (!(dec[9] && !dec[8] && dec[7:0] == 8'h50)) begin
          errors = errors + 1;
          $display("ERROR: CPRI sync stuff byte @pos %0d = %h exp 50",
                   m_phase, dec[7:0]);
        end
      end
      if (m_phase == 16 && ml1_n < 64) begin
        if (dec[9] && !dec[8]) begin
          ml1[ml1_n] = dec[7:0];
          ml1_n = ml1_n + 1;
        end
      end
      if (m_phase == 20 && !iqpat_checked) begin
        // basic frame #1 word #4: TX IQ pattern = {bf[3:0],wpos} = 8'h14
        iqpat_checked = 1;
        if (!(dec[9] && !dec[8] && dec[7:0] == 8'h14)) begin
          errors = errors + 1;
          $display("ERROR: CPRI tx IQ pattern = %h exp 14", dec[7:0]);
        end
      end
      if (m_phase > 0) m_phase = (m_phase == 1023) ? 0 : m_phase + 1;
    end
  end

  // ------------------------------------------------------------------
  // cpu port helpers
  // ------------------------------------------------------------------
  task automatic cpu_wr(input logic [3:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      cpu_we = 1; cpu_addr = a; cpu_wdata = d;
      @(negedge clk);
      cpu_we = 0;
    end
  endtask

  task automatic cpu_rd(input logic [3:0] a, output logic [31:0] d);
    begin
      @(negedge clk);
      cpu_re = 1; cpu_addr = a;
      #1 d = cpu_rdata;
      @(negedge clk);
      cpu_re = 0;
    end
  endtask

  task automatic wait_state(input logic [1:0] st, input int maxc);
    int n;
    logic [31:0] r;
    begin
      n = 0; r = 32'hFFFF_FFFF;
      while (r[1:0] !== st && n < maxc) begin
        cpu_rd(4'd8, r);
        n = n + 1;
      end
      if (r[1:0] !== st) begin
        errors = errors + 1;
        $display("ERROR: CPRI timeout waiting sync state %0d (got %b)", st, r[1:0]);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // TIMEOUT guard
  // ------------------------------------------------------------------
`ifdef VERILATOR
  // chunked timeout guard
  initial begin
    repeat (4000) #1000;
    $display("ERROR: CPRI TB TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #3000000;
    $display("ERROR: CPRI TB TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

  // ------------------------------------------------------------------
  // main test sequence
  // ------------------------------------------------------------------
  logic [31:0] rd, exp;
  int          i, k, found;

  initial begin
    cpu_we = 0; cpu_re = 0; cpu_addr = 0; cpu_wdata = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // CHECK 1: reset state (HUNT, empty IQ buffer, no irq)
    cpu_rd(4'd8, rd);
    if (rd[1:0] !== 2'b00) begin
      errors++; $display("ERROR: CPRI state after reset = %b exp HUNT", rd[1:0]);
    end
    if (rd[11:6] !== 6'd0) begin
      errors++; $display("ERROR: CPRI iq_cnt after reset = %0d exp 0", rd[11:6]);
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: CPRI irq asserted after reset");
    end

    // CHECK 2: sync handshake -- master sends K28.5, peer replies
    k = cyc;
    wait (first_comma >= 0);
    if (first_comma - k > 1100) begin
      errors++;
      $display("ERROR: CPRI master comma late by %0d clocks", first_comma - k);
    end
    peer_on = 1;                 // RE replies with hyperframe-aligned K28.5
    wait_state(2'b10, 4000);     // SYNC

    // CHECK 3: hyperframe boundary -- comma gap exactly 1024 symbols
    wait (ngaps >= 4);
    for (i = 0; i < 4; i++) begin
      if (comma_gaps[i] !== 1024) begin
        errors++;
        $display("ERROR: CPRI comma gap[%0d] = %0d exp 1024", i, comma_gaps[i]);
      end
    end

    // CHECK 4: peer -> master L1 inband negotiation (16-hyperframe stream)
    wait (peer_hf >= 34);
    cpu_rd(4'd8, rd);
    if (rd[2] !== 1'b1) begin
      errors++; $display("ERROR: CPRI l1_done not set after 34 hyperframes");
    end
    if (rd[15:12] !== PEER_VER) begin
      errors++; $display("ERROR: CPRI peer_ver = %0d exp %0d", rd[15:12], PEER_VER);
    end
    cpu_rd(4'd9, rd);
    if (rd[3:0] !== 4'd3) begin
      errors++; $display("ERROR: CPRI neg_ver = %0d exp 3", rd[3:0]);
    end
    if (rd[7:4] !== 4'd5) begin
      errors++; $display("ERROR: CPRI neg_rate = %0d exp 5", rd[7:4]);
    end
    cpu_rd(4'd12, rd);
    if (rd[7:0] !== 8'h5C) begin
      errors++; $display("ERROR: CPRI vendor byte = %h exp 5C", rd[7:0]);
    end

    // CHECK 5: master -> peer L1 slow-stream byte-by-byte compare
    wait (ml1_n >= 40);
    found = -1;
    for (i = 0; i < 25; i++)
      if (ml1[i] == 8'h5A && found < 0) found = i;
    if (found < 0) begin
      errors++; $display("ERROR: CPRI master L1 stream has no start mark 5A");
    end else begin
      for (k = 0; k < 16; k++) begin
        case (k)
          0      : exp = 32'h5A;
          1      : exp = 32'h04;             // local version 4
          2      : exp = 32'h2A;             // {pointer p=2, rate=10}
          15     : exp = 32'h8B;             // check byte 2A^04^A5
          default: exp = 32'h00;
        endcase
        if ({24'h0, ml1[found + k]} !== exp) begin
          errors++;
          $display("ERROR: CPRI master L1[%0d] = %h exp %h", k, ml1[found+k], exp[7:0]);
        end
      end
    end

    // CHECK 6: IQ capture -- pop 16 {I,Q} samples and compare with the
    // byte stream the peer put on the line
    if (iq_base < 0) begin
      errors++; $display("ERROR: CPRI iq_base not captured (no sync entry?)");
    end
    rd = 0; k = 0;
    while (rd[5:0] !== 6'd32 && k < 2000) begin
      cpu_rd(4'd11, rd);
      k = k + 1;
    end
    if (rd[5:0] !== 6'd32) begin
      errors++; $display("ERROR: CPRI iq_cnt = %0d exp 32 (full)", rd[5:0]);
    end
    for (k = 0; k < 16; k++) begin
      cpu_rd(4'd10, rd);
      exp = {iq_log[(iq_base + 4*k + 0) & 8191],
             iq_log[(iq_base + 4*k + 1) & 8191],
             iq_log[(iq_base + 4*k + 2) & 8191],
             iq_log[(iq_base + 4*k + 3) & 8191]};
      if (rd !== exp) begin
        errors++;
        $display("ERROR: CPRI iq[%0d] = %h exp %h", k, rd, exp);
      end
    end

    // CHECK 7: code-violation injection -> irq, then irq clear
    cv_inject = 1;
    wait (cv_inject == 0);
    repeat (4) @(negedge clk);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: CPRI no irq after code violation");
    end
    cpu_rd(4'd13, rd);
    if (rd[1] !== 1'b1) begin
      errors++; $display("ERROR: CPRI irq_cv status bit not set");
    end
    cpu_wr(4'd13, 32'h2);
    repeat (2) @(negedge clk);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: CPRI irq_cv not cleared");
    end

    // CHECK 8: loss of sync -- suppress 5 peer commas, DUT must declare
    // LOS after 4 consecutive missed hyperframes, then re-sync on resume
    los_skip = 5;
    wait_state(2'b00, 9000);                 // HUNT
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: CPRI no irq after loss of sync");
    end
    cpu_rd(4'd13, rd);
    if (rd[0] !== 1'b1) begin
      errors++; $display("ERROR: CPRI irq_los status bit not set");
    end
    wait_state(2'b10, 9000);                 // recovered to SYNC
    cpu_wr(4'd13, 32'h1);
    repeat (2) @(negedge clk);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: CPRI irq_los not cleared");
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // Random stimulus: (b) 80 random config-register write+readback txns,
    // (c) 30 random status/reserved reads, (d) 8 random code-violation
    // injections with sticky-irq set/clear. All cpu transactions self-checked.
    // (The peer IQ stream stays the deterministic iq_pat: the TB's iq_log is
    // an 8192-entry circular model, so only a 256-periodic stream aliases
    // correctly across wraps -- a $urandom stream cannot be self-checked by
    // CHECK 6. The config-register randomisation below varies the L1/vendor
    // bytes the DUT transmits instead.)
    begin : crv_phase
      int n_cfg = 0, n_rd = 0, n_cv = 0;
      logic [3:0]  a_v;
      logic [31:0] w_v;
      logic [31:0] rr;
      // (b) random config writes + readback (cfg[0..7] hold the low byte).
      // Full 32-bit random wdata toggles every cpu_wdata input bit; the DUT
      // stores only cpu_wdata[7:0], so readback is checked against w_v[7:0].
      for (int t = 0; t < 80; t++) begin
        a_v = $urandom_range(7, 0);
        w_v = $urandom;
        cpu_wr(a_v, w_v);
        cpu_rd(a_v, rr);
        n_cfg++;
        if (rr !== {24'h0, w_v[7:0]}) begin
          errors++; $display("ERROR: CRV cfg[%0d] rd %h exp %02h", a_v, rr, w_v[7:0]);
        end
      end
      // (c) random status / vendor / reserved reads (read-mux coverage)
      for (int t = 0; t < 30; t++) begin
        a_v = $urandom_range(15, 8);
        cpu_rd(a_v, rr);
        n_rd++;
        if (a_v >= 4'd14 && rr !== 32'h0) begin
          errors++; $display("ERROR: CRV reserved addr %0d rd %h exp 0", a_v, rr);
        end
        if (^rr === 1'bx) begin
          errors++; $display("ERROR: CRV X on read addr %0d", a_v);
        end
      end
      // (d2) random iq-buffer reads (addr 10) toggle the wide read-mux bits
      for (int t = 0; t < 24; t++) begin
        cpu_rd(4'd10, rr);
        n_rd++;
        if (^rr === 1'bx) begin
          errors++; $display("ERROR: CRV X on iq read t=%0d", t);
        end
      end
      // (d) random code-violation injections -> irq_cv set, then clear
      for (int t = 0; t < 8; t++) begin
        cv_inject = 1;
        wait (cv_inject == 0);
        repeat (4) @(negedge clk);
        if (irq !== 1'b1) begin
          errors++; $display("ERROR: CRV no irq on code violation t=%0d", t);
        end
        cpu_rd(4'd13, rr);
        if (rr[1] !== 1'b1) begin
          errors++; $display("ERROR: CRV irq_cv status not set t=%0d", t);
        end
        cpu_wr(4'd13, 32'h2);
        repeat (2) @(negedge clk);
        n_cv++;
      end
      $display("CRV: cfg=%0d rd=%0d cv=%0d (total %0d txns)",
               n_cfg, n_rd, n_cv, n_cfg + n_rd + n_cv);
    end
`endif

    if (errors == 0) $display("TEST PASSED: CPRI_v8_0__eCPRI_over_CPR_");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CPRI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CPRI_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

endmodule
