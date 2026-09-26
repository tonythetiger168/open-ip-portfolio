// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for C_PHY_top (MIPI C-PHY trio TX + RX decode)
// The TB plays the host (16-bit word stream) and loops the trio TX pads
// back into the RX decoder through an injection mux. It implements the same
// 16-bit -> 7 symbol mapping table as the DUT and compares every symbol on
// the wires.
// Checks:
//   1. reset state: trio idle (mid,mid,mid), irq low, tx_ready high
//   2. packet of 4 words (0000/FFFF/1234/BEEF): sync word + every data
//      symbol compared on the wires (same mapping table; 16'hFFFF exercises
//      the X collision marker), RX loopback words compared, rx_done pulse
//   3. back-to-back second packet (2 words) right after tx_done
//   4. error injection: adjacent identical symbols on the trio -> irq
//   5. error injection: illegal wire state (two wires equal level) -> irq
//   6. irq_clear clears the sticky flag after each injection
// ============================================================================
`timescale 1ns/1ps
module C_PHY_tb;

  localparam logic [1:0] LVL_L = 2'b00;
  localparam logic [1:0] LVL_M = 2'b01;
  localparam logic [1:0] LVL_H = 2'b10;

  localparam logic [5:0] ST_S0 = {LVL_L, LVL_M, LVL_H};
  localparam logic [5:0] ST_S1 = {LVL_L, LVL_H, LVL_M};
  localparam logic [5:0] ST_S2 = {LVL_M, LVL_L, LVL_H};
  localparam logic [5:0] ST_S3 = {LVL_M, LVL_H, LVL_L};
  localparam logic [5:0] ST_S4 = {LVL_H, LVL_L, LVL_M};
  localparam logic [5:0] ST_X  = {LVL_H, LVL_M, LVL_L};
  localparam logic [5:0] ST_MID = {LVL_M, LVL_M, LVL_M};

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // host interface
  logic [15:0] tx_data = 0;
  logic        tx_valid = 0;
  wire         tx_ready;
  logic        tx_last = 0;
  wire         tx_done;
  logic        irq_clear = 0;
  wire         irq;

  // trio TX pads
  wire [1:0] t_a, t_b, t_c;

  // injection mux
  logic       inj = 0;
  logic [1:0] i_a = LVL_M, i_b = LVL_M, i_c = LVL_M;
  wire [1:0] r_a = inj ? i_a : t_a;
  wire [1:0] r_b = inj ? i_b : t_b;
  wire [1:0] r_c = inj ? i_c : t_c;

  // RX decode outputs
  wire        rx_active;
  wire [15:0] rx_data;
  wire        rx_valid;
  wire        rx_done;

  int errors = 0;

  C_PHY_top #(.DW(32), .AW(32)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_last(tx_last), .tx_done(tx_done),
    .t_a(t_a), .t_b(t_b), .t_c(t_c),
    .r_a(r_a), .r_b(r_b), .r_c(r_c),
    .rx_active(rx_active), .rx_data(rx_data), .rx_valid(rx_valid),
    .rx_done(rx_done)
  );

  // ------------------------------------------------------------------
  // helpers + the same mapping table as the DUT
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
  localparam int CPHY_FSM_TOTAL = 8; // TX: T_IDLE..T_STOP, RX: R_IDLE..R_ERR
  logic [7:0] fsm_seen = '0;         // visited-state bitmap
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
    fsm_seen[dut_tstate]       <= 1'b1;
    fsm_seen[4 + dut_rstate]   <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit       first_cycle = 1;  // skip the first posedge (DUT reset values
                              // land in that NBA region)
  logic [5:0] trio_q = 0;
  logic [1:0] tstate_q = 0;
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check({t_a, t_b, t_c} === ST_MID && irq === 1'b0 &&
                rx_valid === 1'b0 && rx_done === 1'b0 && tx_done === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: TX trio is always a legal wire state
      sva_check(({t_a, t_b, t_c} == ST_S0) || ({t_a, t_b, t_c} == ST_S1) ||
                ({t_a, t_b, t_c} == ST_S2) || ({t_a, t_b, t_c} == ST_S3) ||
                ({t_a, t_b, t_c} == ST_S4) || ({t_a, t_b, t_c} == ST_X)  ||
                ({t_a, t_b, t_c} == ST_MID), "A2 trio legal wire state");
      // A3: change rule: consecutive emitted symbols always differ
      sva_check(!((dut_tstate == 2'd1 || dut_tstate == 2'd2) &&
                  (tstate_q  == 2'd1 || tstate_q  == 2'd2)) ||
                ({t_a, t_b, t_c} !== trio_q), "A3 symbol change rule");
      // A4: TX trio is mid whenever the TX FSM is not emitting
      sva_check((dut_tstate == 2'd1 || dut_tstate == 2'd2) ||
                ({t_a, t_b, t_c} === ST_MID), "A4 idle trio is mid");
      // A5: tx_ready mirrors the (single-entry) buffer occupancy
      sva_check(tx_ready === ~dut.buf_valid, "A5 tx_ready mirrors buf_valid");
      // A6: irq mirrors the sticky error flag
      sva_check(irq === dut.err_sticky, "A6 irq mirrors err_sticky");
      // A7: rx_active exactly while the RX FSM decodes a packet
      sva_check(rx_active === ((dut_rstate == 2'd1) || (dut_rstate == 2'd2)),
                "A7 rx_active mirrors rstate");
      // A8: RX symbol/sync counters within the 7-symbol frame
      sva_check(dut.r_sym_cnt <= 3'd6 && dut.r_spos <= 3'd6 &&
                dut.sym_cnt <= 3'd6 && dut.spos <= 3'd6,
                "A8 counters within frame");
    end
    trio_q   <= {t_a, t_b, t_c};
    tstate_q <= dut_tstate;
  end

  // ---- passive wire monitor -------------------------------------------
  // Replaces the forked mon_pkt coroutine on the Verilator path: with
  // 5.006 --timing, concurrent timing coroutines lose wakeups / resume
  // ~10us late (the directed phase then misaligns with the free-running
  // DUT clock). Same checks as mon_pkt, driven by the clock instead.
  int  mon_idx = 0;
  bit  mon_en  = 1'b0;
  int  mon_guard;
  always @(negedge clk) begin
    if (mon_en) begin
      if (mon_idx == 0) begin
        if ({t_a, t_b, t_c} !== ST_MID) begin
          check({t_a, t_b, t_c} === exp_sym[0],
                $sformatf("sym 0 (sync) got=%b exp=%b",
                          {t_a, t_b, t_c}, exp_sym[0]));
          mon_idx = 1;
        end
      end else if (mon_idx <= exp_len - 1) begin
        check({t_a, t_b, t_c} === exp_sym[mon_idx],
              $sformatf("sym %0d got=%b exp=%b",
                        mon_idx, {t_a, t_b, t_c}, exp_sym[mon_idx]));
        if (mon_idx == 2)
          check(rx_active === 1'b1, "rx_active during packet");
        check({t_a, t_b, t_c} !== exp_sym[mon_idx - 1],
              $sformatf("sym %0d equals previous symbol (change rule)",
                        mon_idx));
        mon_idx = mon_idx + 1;
      end else begin
        check({t_a, t_b, t_c} === ST_MID, "packet end: trio back to idle");
        mon_en = 1'b0;
      end
    end
  end

  // ---- inlined stimulus macros for the random phase -------------------
  // (same Verilator 5.006 scheduler rationale as the I2C pilot: chained
  // timing-task coroutines can lose wakeups after ~2k awaits, so the
  // random phase runs as ONE coroutine with plain awaits only)
  `define CPHY_TX_PUSH(w, last) \
    @(negedge clk); \
    tx_data  <= (w); \
    tx_last  <= (last); \
    tx_valid <= 1'b1; \
    do @(negedge clk); while (acc_tx !== 1'b1); \
    tx_valid <= 1'b0; \
    tx_last  <= 1'b0;
  `define CPHY_INJ(s) \
    @(negedge clk); \
    i_a <= s[5:4]; \
    i_b <= s[3:2]; \
    i_c <= s[1:0];
  `define CPHY_IRQ_CLEAR \
    @(negedge clk); \
    irq_clear <= 1'b1; \
    @(negedge clk); \
    irq_clear <= 1'b0;
`endif

  function automatic logic [5:0] state_abc(input int k);
    case (k)
      0: state_abc = ST_S0;
      1: state_abc = ST_S1;
      2: state_abc = ST_S2;
      3: state_abc = ST_S3;
      default: state_abc = ST_S4;
    endcase
  endfunction

  function automatic logic [5:0] sync_sym(input int i);
    case (i)
      0: sync_sym = ST_S1;
      1: sync_sym = ST_S3;
      2: sync_sym = ST_S0;
      3: sync_sym = ST_S2;
      4: sync_sym = ST_S4;
      5: sync_sym = ST_S1;
      default: sync_sym = ST_X;
    endcase
  endfunction

  function automatic int pow5(input int i);
    case (i)
      0: pow5 = 1;
      1: pow5 = 5;
      2: pow5 = 25;
      3: pow5 = 125;
      4: pow5 = 625;
      5: pow5 = 3125;
      default: pow5 = 15625;
    endcase
  endfunction

  // expected wire-symbol sequence for the whole packet
  logic [5:0]  exp_sym [0:255];
  int          exp_len;
  logic [15:0] exp_words [0:31];
  int          exp_nw;

  // build expected symbols: sync + 7 per word (same table as DUT)
  task automatic build_exp;
    logic [5:0] prev, cand;
    int d, k;
    begin
      exp_len = 0;
      for (int i = 0; i < 7; i++) exp_sym[exp_len++] = sync_sym(i);
      prev = sync_sym(6);
      for (int w = 0; w < exp_nw; w++) begin
        for (int i = 0; i < 7; i++) begin
          d = (exp_words[w] / pow5(i)) % 5;
          k = (d + i) % 5;
          cand = state_abc(k);
          if (cand == prev) exp_sym[exp_len] = ST_X;
          else              exp_sym[exp_len] = cand;
          prev = exp_sym[exp_len];
          exp_len++;
        end
      end
    end
  endtask

  // RX capture
  logic [15:0] rxq [0:63];
  int          rxn = 0;
  int          dones = 0;
  int          rxn_mark, done_mark;

  always @(posedge clk) begin
    if (rx_valid) begin
      rxq[rxn] = rx_data;
      rxn = rxn + 1;
    end
    if (rx_done) dones = dones + 1;
  end

  // acceptance flag for the word stream handshake
  logic acc_tx;
  always @(posedge clk) acc_tx <= tx_valid & tx_ready;

  task automatic tx_push(input logic [15:0] w, input bit last);
    begin
      @(negedge clk);
      tx_data  <= w;
      tx_last  <= last;
      tx_valid <= 1'b1;
      do @(negedge clk); while (acc_tx !== 1'b1);
      tx_valid <= 1'b0;
      tx_last  <= 1'b0;
    end
  endtask

  task automatic send_pkt;
    begin
      for (int w = 0; w < exp_nw; w++)
        tx_push(exp_words[w], w == exp_nw - 1);
    end
  endtask

  // wire-level monitor: every symbol of the packet + return to idle
  task automatic mon_pkt;
    begin
      do @(negedge clk); while ({t_a, t_b, t_c} === ST_MID);
      check({t_a, t_b, t_c} === exp_sym[0],
            $sformatf("sym 0 (sync) got=%b exp=%b", {t_a, t_b, t_c}, exp_sym[0]));
      for (int i = 1; i < exp_len; i++) begin
        @(negedge clk);
        check({t_a, t_b, t_c} === exp_sym[i],
              $sformatf("sym %0d got=%b exp=%b", i, {t_a, t_b, t_c}, exp_sym[i]));
        if (i == 2)
          check(rx_active === 1'b1, "rx_active during packet");
        if (i > 0)
          check({t_a, t_b, t_c} !== exp_sym[i-1],
                $sformatf("sym %0d equals previous symbol (change rule)", i));
      end
      @(negedge clk);
      check({t_a, t_b, t_c} === ST_MID, "packet end: trio back to idle");
    end
  endtask

  task automatic check_rxq(input string tag);
    for (int i = 0; i < exp_nw; i++)
      check(rxq[rxn_mark + i] === exp_words[i],
            $sformatf("%s: rx word %0d got=%h exp=%h",
                      tag, i, rxq[rxn_mark + i], exp_words[i]));
    check(rxn - rxn_mark === exp_nw,
          $sformatf("%s: rx word count got=%0d exp=%0d",
                    tag, rxn - rxn_mark, exp_nw));
    check(dones - done_mark === 1, $sformatf("%s: rx_done pulse", tag));
  endtask

  // drive one symbol onto the trio through the injection mux
  task automatic inj_sym(input logic [5:0] s);
    begin
      @(negedge clk);
      i_a <= s[5:4];
      i_b <= s[3:2];
      i_c <= s[1:0];
    end
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
    check({t_a, t_b, t_c} === ST_MID, "reset: trio idle (mid,mid,mid)");
    check(irq === 1'b0, "reset: irq low");
    check(tx_ready === 1'b1, "reset: tx_ready high");

    // ---- check 2: packet #1, 4 words, wire + loopback compare ----
    exp_words[0] = 16'h0000;
    exp_words[1] = 16'hFFFF;   // exercises the X collision marker
    exp_words[2] = 16'h1234;
    exp_words[3] = 16'hBEEF;
    exp_nw = 4;
    build_exp;
    rxn_mark = rxn; done_mark = dones;
`ifdef VERILATOR
    // single-coroutine sequencing + passive monitor (see monitor note)
    mon_idx = 0;
    mon_en  = 1'b1;
    send_pkt;
    mon_guard = 0;
    while (mon_en && mon_guard < 1000) begin
      @(negedge clk);
      mon_guard++;
    end
    check(!mon_en, "wire monitor did not finish");
`else
    fork
      send_pkt;
      mon_pkt;
    join
`endif
    repeat (2) @(negedge clk);
    check_rxq("packet #1");

    // ---- check 3: back-to-back packet #2 ----
    exp_words[0] = 16'h5555;
    exp_words[1] = 16'hAAAA;
    exp_nw = 2;
    build_exp;
    rxn_mark = rxn; done_mark = dones;
`ifdef VERILATOR
    // single-coroutine sequencing + passive monitor (see monitor note)
    mon_idx = 0;
    mon_en  = 1'b1;
    send_pkt;
    mon_guard = 0;
    while (mon_en && mon_guard < 1000) begin
      @(negedge clk);
      mon_guard++;
    end
    check(!mon_en, "wire monitor did not finish");
`else
    fork
      send_pkt;
      mon_pkt;
    join
`endif
    repeat (2) @(negedge clk);
    check_rxq("packet #2 (back-to-back)");

    // ---- check 4: inject adjacent identical symbols -> irq ----
    @(negedge clk);
    inj <= 1'b1;
    for (int i = 0; i < 7; i++) inj_sym(sync_sym(i));  // valid sync
    inj_sym(ST_S2);                                    // data symbol
    inj_sym(ST_S2);                                    // repeated -> violation
    inj_sym(ST_MID);                                   // back to idle
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: repeated symbol raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared by irq_clear");

    // ---- check 5: inject illegal wire state (a=b=high) -> irq ----
    @(negedge clk);
    inj <= 1'b1;
    for (int i = 0; i < 7; i++) inj_sym(sync_sym(i));
    inj_sym(ST_S2);
    inj_sym({LVL_H, LVL_H, LVL_L});                    // two wires equal
    inj_sym(ST_MID);
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: illegal wire state raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared after illegal-state injection");

    // ---- check 6: normal packet still works after error recovery ----
    exp_words[0] = 16'h0F0F;
    exp_nw = 1;
    build_exp;
    rxn_mark = rxn; done_mark = dones;
`ifdef VERILATOR
    // single-coroutine sequencing + passive monitor (see monitor note)
    mon_idx = 0;
    mon_en  = 1'b1;
    send_pkt;
    mon_guard = 0;
    while (mon_en && mon_guard < 1000) begin
      @(negedge clk);
      mon_guard++;
    end
    check(!mon_en, "wire monitor did not finish");
`else
    fork
      send_pkt;
      mon_pkt;
    join
`endif
    repeat (2) @(negedge clk);
    check_rxq("packet #3 (post-error)");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized transactions. Normal class: random packet of 1-6
    // words (boundary 0x0000/0xFFFF plus random values), RX loopback
    // words and rx_done self-checked against the scoreboard queue; the
    // clocked SVA suite continuously checks the wire-level mapping rules
    // (legal state / change rule / idle-mid) during every packet. Error
    // classes (round-robin selector, all parameters randomized):
    // repeated symbol, illegal wire state, corrupted sync, mid-word
    // stop, non-sync start -- each must raise the sticky irq and recover
    // after irq_clear. Fully inlined via the macros above.
    begin : crv_phase
      int n_pkt = 0, n_rep = 0, n_ill = 0, n_syn = 0, n_mws = 0, n_nst = 0;
      int n_und = 0;
      int roll, eroll = 0, nw_c;
      logic [15:0] w_c;
      logic [5:0]  csym, cprev;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 20) begin
          // ---- random packet + RX loopback compare ----
          n_pkt++;
          nw_c = 1 + $urandom_range(0, 5);
          for (int w = 0; w < nw_c; w++) begin
            if (t == 0)           w_c = 16'h0000;             // boundary
            else if (t == 1)      w_c = 16'hFFFF;             // boundary
            else begin
              roll = $urandom_range(0, 9);
              w_c = (roll == 0) ? 16'h0000 : (roll == 1) ? 16'hFFFF
                                   : 16'($urandom_range(0, 65535));
            end
            exp_words[w] = w_c;
          end
          exp_nw = nw_c;
          rxn_mark = rxn; done_mark = dones;
          for (int w = 0; w < nw_c; w++) begin
            w_c = exp_words[w];
            `CPHY_TX_PUSH(w_c, (w == nw_c - 1))
          end
          repeat (7 + 7 * nw_c + 6) @(negedge clk);   // drain TX + RX
          for (int i = 0; i < nw_c; i++) begin
            if (rxq[rxn_mark + i] !== exp_words[i]) begin
              errors++;
              $display("ERROR: CRV rx word %0d got=%h exp=%h",
                       i, rxq[rxn_mark + i], exp_words[i]);
            end
          end
          if (rxn - rxn_mark !== nw_c) begin
            errors++;
            $display("ERROR: CRV rx word count got=%0d exp=%0d",
                     rxn - rxn_mark, nw_c);
          end
          if (dones - done_mark !== 1) begin
            errors++; $display("ERROR: CRV rx_done pulse missing");
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during clean packet");
          end
        end else begin
          // ---- error-injection classes (round-robin) ----
          case (eroll)
            0: begin
              // repeated adjacent symbol on the trio -> irq
              n_rep++;
              csym = state_abc($urandom_range(0, 4));
              @(negedge clk);
              inj <= 1'b1;
              for (int i = 0; i < 7; i++) begin
                cprev = sync_sym(i); `CPHY_INJ(cprev)
              end
              `CPHY_INJ(csym)          // data symbol
              `CPHY_INJ(csym)          // repeated -> violation
              cprev = ST_MID; `CPHY_INJ(cprev)
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV repeated symbol: no irq");
              end
              `CPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (rep)");
              end
            end
            1: begin
              // illegal wire state (two wires equal level) -> irq
              n_ill++;
              case ($urandom_range(0, 2))
                0: csym = {LVL_H, LVL_H, LVL_L};
                1: csym = {LVL_L, LVL_L, LVL_H};
                default: csym = {LVL_H, LVL_M, LVL_H};
              endcase
              @(negedge clk);
              inj <= 1'b1;
              for (int i = 0; i < 7; i++) begin
                cprev = sync_sym(i); `CPHY_INJ(cprev)
              end
              cprev = ST_S2; `CPHY_INJ(cprev)
              `CPHY_INJ(csym)          // illegal -> violation
              cprev = ST_MID; `CPHY_INJ(cprev)
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV illegal wire state: no irq");
              end
              `CPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (ill)");
              end
            end
            2: begin
              // corrupted sync word -> irq
              n_syn++;
              roll = 1 + $urandom_range(0, 5);     // corrupt position
              @(negedge clk);
              inj <= 1'b1;
              for (int i = 0; i < 7; i++) begin
                if (i == roll) begin
                  csym = (sync_sym(i) == ST_S2) ? ST_S4 : ST_S2;
                  if (csym == sync_sym(i - 1)) csym = ST_S0; // keep legal
                  `CPHY_INJ(csym)      // wrong sync symbol
                end else begin
                  csym = sync_sym(i); `CPHY_INJ(csym)
                end
              end
              cprev = ST_MID; `CPHY_INJ(cprev)
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad sync: no irq");
              end
              `CPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (sync)");
              end
            end
            3: begin
              // mid-word stop (stop after 1-6 symbols of a word) -> irq
              n_mws++;
              @(negedge clk);
              inj <= 1'b1;
              for (int i = 0; i < 7; i++) begin
                cprev = sync_sym(i); `CPHY_INJ(cprev)
              end
              cprev = sync_sym(6);
              for (int i = 0; i < 1 + $urandom_range(0, 5); i++) begin
                csym = state_abc($urandom_range(0, 4));
                if (csym == cprev) csym = ST_X;      // keep stream legal
                `CPHY_INJ(csym)
                cprev = csym;
              end
              cprev = ST_MID; `CPHY_INJ(cprev)       // stop mid-word
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV mid-word stop: no irq");
              end
              `CPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (mws)");
              end
            end
            4: begin
              // packet not starting with the sync word -> irq
              n_nst++;
              csym = state_abc($urandom_range(0, 4));
              if (csym == sync_sym(0)) csym = ST_S0; // rejection sampling
              @(negedge clk);
              inj <= 1'b1;
              `CPHY_INJ(csym)          // non-sync symbol from idle
              cprev = ST_MID; `CPHY_INJ(cprev)
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV non-sync start: no irq");
              end
              `CPHY_IRQ_CLEAR
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (nst)");
              end
            end
            default: begin
              // host underrun: tx_last=0 with no follow-up word -> TX
              // takes the clean-stop underrun arm (rtl T_DATA else arm);
              // RX still sees a word-boundary stop (rx_done, no irq)
              n_und++;
              w_c = 16'($urandom_range(0, 65535));
              exp_words[0] = w_c;
              exp_nw = 1;
              rxn_mark = rxn; done_mark = dones;
              `CPHY_TX_PUSH(w_c, 1'b0)
              repeat (7 + 7 + 8) @(negedge clk);
              if (rxn - rxn_mark !== 1 || rxq[rxn_mark] !== w_c) begin
                errors++;
                $display("ERROR: CRV underrun word got=%h exp=%h",
                         rxq[rxn_mark], w_c);
              end
              if (dones - done_mark !== 1) begin
                errors++; $display("ERROR: CRV underrun: rx_done missing");
              end
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV underrun raised irq");
              end
            end
          endcase
          eroll = (eroll + 1) % 6;
        end
      end
      $display("CRV: 120 txns (pkt=%0d | rep=%0d ill=%0d badsync=%0d midstop=%0d nosync=%0d underrun=%0d)",
               n_pkt, n_rep, n_ill, n_syn, n_mws, n_nst, n_und);
    end
  `undef CPHY_TX_PUSH
  `undef CPHY_INJ
  `undef CPHY_IRQ_CLEAR
`endif

    repeat (4) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: C-PHY");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CPHY_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CPHY_FSM_TOTAL);
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
    repeat (2000) #1000;    // 2 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #200000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
