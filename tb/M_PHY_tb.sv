// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for M_PHY_top (MIPI M-PHY lane: 8b/10b, gears,
// HIBERN8). The TB plays the host (byte stream incl. K28.5 comma) and loops
// the serial TX line back into the RX decoder through an injection mux.
// Checks:
//   1. reset state: line DIF-N idle, hibern8/rx_locked/irq low
//   2. G1 burst: K28.5 comma acquires rx_locked; D0.0..D7.0 (all eight
//      implemented D-codes) looped back and compared with k flags
//   3. back-to-back second burst right after the first
//   4. gear switch G1->G2 while idle, burst compare (data integrity after
//      the rate change), then switch back to G1
//   5. HIBERN8: hibern8_req -> SAVE (hibern8 flag, line DIF-Z, rx_hibern),
//      wake_req -> wake burst -> normal idle, transfer works afterwards
//   6. error injection: invalid 10-bit code after comma -> irq
//   7. error injection: valid code with wrong running disparity -> irq;
//      irq_clear clears the sticky flag after each injection
// ============================================================================
`timescale 1ns/1ps
module M_PHY_tb;

  localparam logic [9:0] K28P_RDN = 10'b0011111010; // K28.5 RD- form
  localparam logic [9:0] D00_RDN  = 10'b1001110100; // D0.0  RD- form

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic       gear = 0;
  logic       hibern8_req = 0;
  logic       wake_req = 0;
  wire        hibern8;
  logic [7:0] tx_data = 0;
  logic       tx_k = 0;
  logic       tx_valid = 0;
  wire        tx_ready;
  logic       irq_clear = 0;
  wire        irq;

  wire tx_dif_p, tx_dif_n;

  // injection mux
  logic inj = 0;
  logic i_p = 0, i_n = 1;
  wire rx_dif_p = inj ? i_p : tx_dif_p;
  wire rx_dif_n = inj ? i_n : tx_dif_n;

  wire       rx_locked, rx_hibern;
  wire [7:0] rx_data;
  wire       rx_k, rx_valid;

  int errors = 0;

  M_PHY_top #(.DW(32), .AW(32)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .gear(gear),
    .hibern8_req(hibern8_req), .wake_req(wake_req), .hibern8(hibern8),
    .tx_data(tx_data), .tx_k(tx_k), .tx_valid(tx_valid),
    .tx_ready(tx_ready),
    .tx_dif_p(tx_dif_p), .tx_dif_n(tx_dif_n),
    .rx_dif_p(rx_dif_p), .rx_dif_n(rx_dif_n),
    .rx_locked(rx_locked), .rx_hibern(rx_hibern),
    .rx_data(rx_data), .rx_k(rx_k), .rx_valid(rx_valid)
  );

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (time %0t)", msg, $time);
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int MPHY_FSM_TOTAL = 7; // TX: T_IDLE..T_WAKE, RX: H_HUNT..H_HIB
  logic [6:0] fsm_seen = '0;         // visited-state bitmap
  wire  [1:0] dut_tstate = dut.tstate;  // hierarchical FSM probes
  wire  [1:0] dut_rstate = dut.rstate;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: sample both DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_tstate]     <= 1'b1;
    fsm_seen[4 + dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit first_cycle = 1;  // skip the first posedge (DUT reset values land
                        // in that NBA region)
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check({tx_dif_p, tx_dif_n} === 2'b01 && hibern8 === 1'b0 &&
                rx_locked === 1'b0 && rx_hibern === 1'b0 && irq === 1'b0 &&
                rx_valid === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: line always a legal state (DIF-N / DIF-P / DIF-Z, never 2'b11)
      sva_check({tx_dif_p, tx_dif_n} !== 2'b11, "A2 line state legal");
      // A3: hibern8 flag mirrors the TX SAVE state
      sva_check(hibern8 === (dut_tstate == 2'd2), "A3 hibern8 mirrors T_SAVE");
      // A4: rx_locked / rx_hibern mirror the RX FSM
      sva_check(rx_locked === (dut_rstate == 2'd1) &&
                rx_hibern === (dut_rstate == 2'd2),
                "A4 rx status mirrors rstate");
      // A5: irq mirrors the sticky error flags
      sva_check(irq === (dut.err_tx | dut.err_rx), "A5 irq mirrors err flags");
      // A6: tx_ready mirrors the (single-entry) buffer occupancy + TX state
      sva_check(tx_ready === (~dut.buf_valid & (dut_tstate <= 2'd1)),
                "A6 tx_ready mirrors buf_valid/tstate");
      // A7: rx_valid only while locked (comma match enters H_LOCK same cycle)
      sva_check(!rx_valid || rx_locked, "A7 rx_valid implies locked");
      // A8: counters within their documented bounds
      sva_check(dut.bit_cnt <= 4'd9 && dut.rbit_cnt <= 4'd9 &&
                dut.wake_cnt <= 4'd7 && dut.hib_cnt <= 2'd3,
                "A8 counters within bounds");
    end
  end

  // ---- inlined stimulus macros for the random phase -------------------
  // (same Verilator 5.006 scheduler rationale as the I2C pilot: chained
  // timing-task coroutines can lose wakeups after ~2k awaits, so the
  // random phase runs as ONE coroutine with plain awaits only)
  `define MPHY_TX_PUSH(d, k) \
    @(negedge clk); \
    tx_data  <= (d); \
    tx_k     <= (k); \
    tx_valid <= 1'b1; \
    do @(negedge clk); while (acc_tx !== 1'b1); \
    tx_valid <= 1'b0; \
    tx_k     <= 1'b0;
  `define MPHY_INJ_BIT(b) \
    @(negedge clk); \
    i_p <= (b); \
    i_n <= ~(b);
  `define MPHY_INJ_WORD(w) \
    for (int ib = 9; ib >= 0; ib--) begin \
      `MPHY_INJ_BIT(w[ib]) \
    end
  `define MPHY_IRQ_CLEAR \
    @(negedge clk); \
    irq_clear <= 1'b1; \
    @(negedge clk); \
    irq_clear <= 1'b0;
  `define MPHY_WAIT_RXN(target) \
    begin \
      wait_to = 0; \
      while (rxn < (target) && wait_to < 2000) begin \
        @(negedge clk); \
        wait_to++; \
      end \
      if (wait_to >= 2000) begin \
        errors++; \
        $display("ERROR: CRV rxn timeout target %0d (got %0d)", (target), rxn); \
      end \
    end

  // valid 10-bit codes (same table as the DUT decoder): 8 D-codes in both
  // RD forms + K28.5 in both RD forms; used for rejection sampling
  function automatic bit is_valid10(input logic [9:0] w);
    case (w)
      10'b1001110100, 10'b0110001011, // D0.0
      10'b0111010100, 10'b1000101011, // D1.0
      10'b1011010100, 10'b0100101011, // D2.0
      10'b1100011011, 10'b1100010100, // D3.0
      10'b1101010100, 10'b0010101011, // D4.0
      10'b1010010100, 10'b1010011011, // D5.0
      10'b0110010100, 10'b0110011011, // D6.0
      10'b1110001011, 10'b0001110100, // D7.0
      10'b0011111010, 10'b1100000101: is_valid10 = 1'b1; // K28.5
      default:                        is_valid10 = 1'b0;
    endcase
  endfunction
`endif

  // RX capture: {k, data}  (deepened for the Verilator random phase)
  logic [8:0] rxq [0:4095];
  int         rxn = 0;
  int         rxn_mark;

  always @(posedge clk) begin
    if (rx_valid) begin
      rxq[rxn] = {rx_k, rx_data};
      rxn = rxn + 1;
    end
  end

  // acceptance flag for the byte-stream handshake
  logic acc_tx;
  always @(posedge clk) acc_tx <= tx_valid & tx_ready;

  task automatic tx_push(input logic [7:0] d, input logic k);
    begin
      @(negedge clk);
      tx_data  <= d;
      tx_k     <= k;
      tx_valid <= 1'b1;
      do @(negedge clk); while (acc_tx !== 1'b1);
      tx_valid <= 1'b0;
      tx_k     <= 1'b0;
    end
  endtask

  // wait until rxn reaches target (bounded)
  task automatic wait_rxn(input int target);
    int to;
    begin
      to = 0;
      while (rxn < target && to < 1000) begin
        @(negedge clk);
        to++;
      end
      check(to < 1000, $sformatf("rx word count target %0d (got %0d)", target, rxn));
    end
  endtask

  task automatic check_word(input int idx, input logic [8:0] exp, input string tag);
    check(rxq[idx] === exp,
          $sformatf("%s: rxq[%0d] got={k=%b,d=%h} exp={k=%b,d=%h}",
                    tag, idx, rxq[idx][8], rxq[idx][7:0], exp[8], exp[7:0]));
  endtask

  // injection: one bit (G1 rate, 1 clk), bit 'a' (word[9]) first
  task automatic inj_bit(input logic b);
    begin
      @(negedge clk);
      i_p <= b;
      i_n <= ~b;
    end
  endtask

  task automatic inj_word(input logic [9:0] w);
    for (int i = 9; i >= 0; i--) inj_bit(w[i]);
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  initial begin
    // ---- reset ----
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // check 1: reset state
    check({tx_dif_p, tx_dif_n} === 2'b01, "reset: line idle DIF-N");
    check(hibern8 === 1'b0, "reset: hibern8 low");
    check(rx_locked === 1'b0, "reset: rx_locked low");
    check(irq === 1'b0, "reset: irq low");

    // ---- check 2: G1 burst, comma + all 8 D-codes ----
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);              // K28.5 comma
    for (int b = 0; b < 8; b++) tx_push(8'(b), 1'b0);
    wait_rxn(rxn_mark + 9);
    check(rx_locked === 1'b1 || rxn == rxn_mark + 9, "G1 burst decoded");
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "burst #1 comma");
    for (int b = 0; b < 8; b++)
      check_word(rxn_mark + 1 + b, {1'b0, 8'(b)}, "burst #1 D-code");

    // ---- check 3: back-to-back burst #2 ----
    repeat (12) @(negedge clk);        // let RX fall back to hunt
    check(rx_locked === 1'b0, "rx back to hunt after idle word");
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h07, 1'b0);
    tx_push(8'h06, 1'b0);
    tx_push(8'h05, 1'b0);
    tx_push(8'h04, 1'b0);
    wait_rxn(rxn_mark + 5);
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "burst #2 comma");
    check_word(rxn_mark + 1, {1'b0, 8'h07}, "burst #2");
    check_word(rxn_mark + 2, {1'b0, 8'h06}, "burst #2");
    check_word(rxn_mark + 3, {1'b0, 8'h05}, "burst #2");
    check_word(rxn_mark + 4, {1'b0, 8'h04}, "burst #2");

    // ---- check 4: gear switch to G2, data integrity ----
    repeat (12) @(negedge clk);
    gear <= 1'b1;
    @(negedge clk);
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h03, 1'b0);
    tx_push(8'h02, 1'b0);
    tx_push(8'h01, 1'b0);
    wait_rxn(rxn_mark + 4);
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "G2 burst comma");
    check_word(rxn_mark + 1, {1'b0, 8'h03}, "G2 burst");
    check_word(rxn_mark + 2, {1'b0, 8'h02}, "G2 burst");
    check_word(rxn_mark + 3, {1'b0, 8'h01}, "G2 burst");
    repeat (24) @(negedge clk);
    gear <= 1'b0;                      // back to G1 while idle
    @(negedge clk);

    // ---- check 5: HIBERN8 enter / exit ----
    @(negedge clk);
    hibern8_req <= 1'b1;
    @(negedge clk);
    hibern8_req <= 1'b0;
    repeat (2) @(negedge clk);
    check(hibern8 === 1'b1, "HIBERN8: SAVE flag raised");
    check({tx_dif_p, tx_dif_n} === 2'b00, "HIBERN8: line DIF-Z");
    repeat (3) @(negedge clk);
    check(rx_hibern === 1'b1, "HIBERN8: rx_hibern detected");
    check(rx_locked === 1'b0, "HIBERN8: rx unlocked");
    @(negedge clk);
    wake_req <= 1'b1;
    @(negedge clk);
    wake_req <= 1'b0;
    repeat (12) @(negedge clk);        // wake burst (8 clk) + settle
    check(hibern8 === 1'b0, "wake: SAVE flag cleared");
    check({tx_dif_p, tx_dif_n} === 2'b01, "wake: line back to DIF-N idle");
    check(rx_hibern === 1'b0, "wake: rx_hibern cleared");
    // transfer after wake
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h05, 1'b0);
    wait_rxn(rxn_mark + 2);
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "post-wake comma");
    check_word(rxn_mark + 1, {1'b0, 8'h05}, "post-wake byte");

    // ---- check 6: inject invalid 10-bit code -> irq ----
    repeat (12) @(negedge clk);
    rxn_mark = rxn;
    @(negedge clk);
    inj <= 1'b1;
    inj_word(K28P_RDN);                // lock the RX
    inj_word(10'b1111100000);          // not a valid code
    @(negedge clk);
    i_p <= 1'b0;                       // back to idle levels
    i_n <= 1'b1;
    @(negedge clk);
    inj <= 1'b0;
    repeat (3) @(negedge clk);
    check(irq === 1'b1, "error injection: invalid code raises irq");
    check(rxn === rxn_mark + 1, "invalid code: only the comma was decoded");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared by irq_clear");

    // ---- check 7: inject disparity violation (valid code, wrong RD) ----
    @(negedge clk);
    inj <= 1'b1;
    inj_word(K28P_RDN);                // RD- comma -> RX running disparity RD+
    inj_word(D00_RDN);                 // RD- form of D0.0: +2 block needs RD-
    @(negedge clk);
    i_p <= 1'b0;
    i_n <= 1'b1;
    @(negedge clk);
    inj <= 1'b0;
    repeat (3) @(negedge clk);
    check(irq === 1'b1, "error injection: disparity violation raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared after disparity injection");

    // ---- recovery: normal traffic still works ----
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h02, 1'b0);
    wait_rxn(rxn_mark + 2);
    check_word(rxn_mark + 1, {1'b0, 8'h02}, "post-error byte");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 126 randomized transactions, single coroutine, fully inlined via the
    // macros above. Normal class (~2/3): random burst of comma + 1-6 bytes
    // (D-codes 0x00-0x07 with 0x00/0x07 boundary forcing, occasional
    // mid-burst K28.5), RX loopback words + k flags self-checked against
    // the scoreboard queue. Error/special classes (round-robin selector,
    // all parameters randomized):
    //   0 invalid 10-bit code injected after a comma -> err_rx irq
    //   1 valid code with wrong running disparity   -> err_rx irq
    //   2 unsupported D-code byte (>=8)             -> err_tx irq
    //     (alternating T_IDLE / T_SHIFT-wrap error arms)
    //   3 unsupported K-code (!= K28.5)             -> err_tx irq (same alt)
    //   4 gear: G2 burst compare / mid-lock gear switch -> re-hunt
    //   5 HIBERN8 enter/wake + post-wake burst compare
    begin : crv_phase
      int n_burst = 0, n_inv = 0, n_disp = 0, n_badd = 0, n_badk = 0;
      int n_gear = 0, n_hib = 0;
      int roll, eroll = 0, nw_c, wait_to;
      logic [7:0] w_c;
      logic       k_c;
      logic [9:0] w10;
      logic [8:0] expq [0:7];
      for (int t = 0; t < 126; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 20) begin
          // ---- random burst + RX loopback compare ----
          n_burst++;
          nw_c = 1 + $urandom_range(0, 5);
          expq[0] = {1'b1, 8'hBC};
          for (int w = 0; w < nw_c; w++) begin
            if (t == 0)      w_c = 8'h00;                   // boundary
            else if (t == 1) w_c = 8'h07;                   // boundary
            else begin
              roll = $urandom_range(0, 19);
              w_c = (roll == 0) ? 8'h00 : (roll == 1) ? 8'h07
                                   : 8'($urandom_range(0, 7));
            end
            k_c = 1'b0;
            if (t > 1 && $urandom_range(0, 3) == 0) begin
              w_c = 8'hBC; k_c = 1'b1;      // mid-burst comma
            end
            expq[1 + w] = {k_c, w_c};
          end
          rxn_mark = rxn;
          `MPHY_TX_PUSH(8'hBC, 1'b1)
          for (int w = 0; w < nw_c; w++) begin
            w_c = expq[1 + w][7:0]; k_c = expq[1 + w][8];
            `MPHY_TX_PUSH(w_c, k_c)
          end
          `MPHY_WAIT_RXN(rxn_mark + 1 + nw_c)
          for (int i = 0; i <= nw_c; i++) begin
            if (rxq[rxn_mark + i] !== expq[i]) begin
              errors++;
              $display("ERROR: CRV burst word %0d got={k=%b,d=%h} exp={k=%b,d=%h}",
                       i, rxq[rxn_mark+i][8], rxq[rxn_mark+i][7:0],
                       expq[i][8], expq[i][7:0]);
            end
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during clean burst");
          end
          repeat (12) @(negedge clk);       // let RX fall back to hunt
        end else begin
          // ---- error / special classes (round-robin) ----
          case (eroll)
            0: begin
              // invalid 10-bit code after comma -> irq (err_rx)
              n_inv++;
              w10 = 10'($urandom_range(0, 1023));
              if (is_valid10(w10)) w10 = 10'b1111100000; // rejection: known bad
              repeat (12) @(negedge clk);
              rxn_mark = rxn;
              @(negedge clk);
              inj <= 1'b1;
              begin
                logic [9:0] cw; cw = K28P_RDN;
                `MPHY_INJ_WORD(cw)          // lock the RX
                cw = w10;
                `MPHY_INJ_WORD(cw)          // invalid -> violation
              end
              @(negedge clk);
              i_p <= 1'b0;                  // back to idle levels
              i_n <= 1'b1;
              @(negedge clk);
              inj <= 1'b0;
              repeat (3) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV invalid code: no irq (w=%b)", w10);
              end
              if (rxn !== rxn_mark + 1) begin
                errors++;
                $display("ERROR: CRV invalid code: rxn got %0d exp %0d",
                         rxn, rxn_mark + 1);
              end
              `MPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (inv)");
              end
              repeat (12) @(negedge clk);
            end
            1: begin
              // valid code, wrong running disparity -> irq (err_rx)
              n_disp++;
              repeat (12) @(negedge clk);
              @(negedge clk);
              inj <= 1'b1;
              begin
                logic [9:0] cw; cw = K28P_RDN;
                `MPHY_INJ_WORD(cw)          // RD- comma -> RX disparity RD+
                cw = D00_RDN;
                `MPHY_INJ_WORD(cw)          // RD- D0.0: +2 block needs RD-
              end
              @(negedge clk);
              i_p <= 1'b0;
              i_n <= 1'b1;
              @(negedge clk);
              inj <= 1'b0;
              repeat (3) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV disparity violation: no irq");
              end
              `MPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (disp)");
              end
              repeat (12) @(negedge clk);
            end
            2: begin
              // unsupported D-code byte -> err_tx irq (no line activity)
              n_badd++;
              w_c = 8'd8 + 8'($urandom_range(0, 247));   // outside D0.0..D7.0
              repeat (12) @(negedge clk);
              rxn_mark = rxn;
              if (n_badd % 2 == 1) begin
                // byte accepted while TX idle -> T_IDLE error arm
                `MPHY_TX_PUSH(w_c, 1'b0)
              end else begin
                // byte buffered during a comma shift -> T_SHIFT wrap error arm
                `MPHY_TX_PUSH(8'hBC, 1'b1)
                `MPHY_TX_PUSH(w_c, 1'b0)
              end
              repeat (14) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad D-code %h: no irq", w_c);
              end
              if (rxn !== rxn_mark + ((n_badd % 2 == 0) ? 1 : 0)) begin
                errors++;
                $display("ERROR: CRV bad D-code: rxn got %0d (mark %0d, it %0d)",
                         rxn, rxn_mark, n_badd);
              end
              `MPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (badd)");
              end
              repeat (12) @(negedge clk);
            end
            3: begin
              // unsupported K-code (!= K28.5) -> err_tx irq
              n_badk++;
              w_c = 8'($urandom_range(0, 255));
              if (w_c == 8'hBC) w_c = 8'hBD;             // rejection sampling
              repeat (12) @(negedge clk);
              rxn_mark = rxn;
              if (n_badk % 2 == 1) begin
                `MPHY_TX_PUSH(w_c, 1'b1)                 // T_IDLE error arm
              end else begin
                `MPHY_TX_PUSH(8'hBC, 1'b1)
                `MPHY_TX_PUSH(w_c, 1'b1)                 // T_SHIFT wrap error arm
              end
              repeat (14) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad K-code %h: no irq", w_c);
              end
              `MPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (badk)");
              end
              repeat (12) @(negedge clk);
            end
            4: begin
              // gear classes (alternate): G2 burst compare / mid-lock switch
              n_gear++;
              repeat (12) @(negedge clk);
              if (n_gear % 2 == 1) begin
                // ---- G2 burst: comma + 1-3 bytes, loopback compare ----
                nw_c = 1 + $urandom_range(0, 2);
                @(negedge clk);
                gear <= 1'b1;
                @(negedge clk);
                rxn_mark = rxn;
                expq[0] = {1'b1, 8'hBC};
                `MPHY_TX_PUSH(8'hBC, 1'b1)
                for (int w = 0; w < nw_c; w++) begin
                  w_c = 8'($urandom_range(0, 7));
                  expq[1 + w] = {1'b0, w_c};
                  `MPHY_TX_PUSH(w_c, 1'b0)
                end
                `MPHY_WAIT_RXN(rxn_mark + 1 + nw_c)
                for (int i = 0; i <= nw_c; i++) begin
                  if (rxq[rxn_mark + i] !== expq[i]) begin
                    errors++;
                    $display("ERROR: CRV G2 word %0d got=%h exp=%h",
                             i, rxq[rxn_mark + i], expq[i]);
                  end
                end
                if (irq !== 1'b0) begin
                  errors++; $display("ERROR: CRV irq set during G2 burst");
                end
                repeat (24) @(negedge clk);
                gear <= 1'b0;                            // back to G1 while idle
                @(negedge clk);
              end else begin
                // ---- gear switch while RX locked -> re-hunt arm ----
                rxn_mark = rxn;
                `MPHY_TX_PUSH(8'hBC, 1'b1)               // RX locks on comma
                wait_to = 0;          // wait until the lock actually happens
                while (rx_locked !== 1'b1 && wait_to < 200) begin
                  @(negedge clk);
                  wait_to++;
                end
                if (rx_locked !== 1'b1) begin
                  errors++; $display("ERROR: CRV gear class: RX never locked");
                end
                gear <= 1'b1;                            // switch mid-lock
                repeat (4) @(negedge clk);
                gear <= 1'b0;
                repeat (16) @(negedge clk);
                if (irq !== 1'b0) begin
                  errors++; $display("ERROR: CRV mid-lock gear switch: irq");
                end
                // recovery: clean burst decodes correctly
                rxn_mark = rxn;
                w_c = 8'($urandom_range(0, 7));
                `MPHY_TX_PUSH(8'hBC, 1'b1)
                `MPHY_TX_PUSH(w_c, 1'b0)
                `MPHY_WAIT_RXN(rxn_mark + 2)
                if (rxq[rxn_mark] !== {1'b1, 8'hBC} ||
                    rxq[rxn_mark + 1] !== {1'b0, w_c}) begin
                  errors++;
                  $display("ERROR: CRV post-gear-switch burst got=%h/%h exp BC/%h",
                           rxq[rxn_mark], rxq[rxn_mark + 1], w_c);
                end
                repeat (12) @(negedge clk);
              end
            end
            default: begin
              // HIBERN8 enter / wake / post-wake burst
              n_hib++;
              repeat (12) @(negedge clk);
              @(negedge clk);
              hibern8_req <= 1'b1;
              @(negedge clk);
              hibern8_req <= 1'b0;
              repeat (2) @(negedge clk);
              if (hibern8 !== 1'b1 || {tx_dif_p, tx_dif_n} !== 2'b00) begin
                errors++; $display("ERROR: CRV HIBERN8 enter failed");
              end
              repeat (3) @(negedge clk);
              if (rx_hibern !== 1'b1) begin
                errors++; $display("ERROR: CRV rx_hibern not detected");
              end
              @(negedge clk);
              wake_req <= 1'b1;
              @(negedge clk);
              wake_req <= 1'b0;
              repeat (12) @(negedge clk);
              if (hibern8 !== 1'b0 || {tx_dif_p, tx_dif_n} !== 2'b01 ||
                  rx_hibern !== 1'b0) begin
                errors++; $display("ERROR: CRV wake failed");
              end
              rxn_mark = rxn;
              w_c = 8'($urandom_range(0, 7));
              `MPHY_TX_PUSH(8'hBC, 1'b1)
              `MPHY_TX_PUSH(w_c, 1'b0)
              `MPHY_WAIT_RXN(rxn_mark + 2)
              if (rxq[rxn_mark] !== {1'b1, 8'hBC} ||
                  rxq[rxn_mark + 1] !== {1'b0, w_c}) begin
                errors++;
                $display("ERROR: CRV post-wake burst got=%h/%h exp BC/%h",
                         rxq[rxn_mark], rxq[rxn_mark + 1], w_c);
              end
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq set around HIBERN8");
              end
              repeat (12) @(negedge clk);
            end
          endcase
          eroll = (eroll + 1) % 6;
        end
      end
      $display("CRV: 126 txns (burst=%0d | inv=%0d disp=%0d badd=%0d badk=%0d gear=%0d hibern8=%0d)",
               n_burst, n_inv, n_disp, n_badd, n_badk, n_gear, n_hib);
    end
  `undef MPHY_TX_PUSH
  `undef MPHY_INJ_BIT
  `undef MPHY_INJ_WORD
  `undef MPHY_IRQ_CLEAR
  `undef MPHY_WAIT_RXN
`endif

    repeat (4) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: M-PHY");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < MPHY_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, MPHY_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (4000) #1000;    // 4 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #300000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
