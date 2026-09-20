// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for D_PHY_top (MIPI D-PHY lane pair TX + RX decode)
// The TB plays the host (HS byte stream / escape requests) and loops the
// data-lane TX pads back into the same-lane RX decoder through an injection
// mux, so protocol errors can be driven directly onto the lane.
// Checks:
//   1. reset state: both lanes LP-11, HS drivers off, irq low
//   2. HS burst of 4 bytes: wire-level SoT (LP-01 -> LP-00 -> HS-0),
//      sync pattern 00011101 (8'hB8 LSB-first), payload bits LSB-first,
//      EoT (last bit inverted + hold + LP-11) -- all compared per bit;
//      clock lane HS enable + toggle; RX loopback bytes compared
//   3. second HS burst back-to-back (1 byte) after hs_tx_done
//   4. escape LPDT: entry LP-10/00/01/00 + cmd 8'h87 wire compare,
//      2 LPDT bytes looped back and compared, exit space/Mark-1/LP-11
//   5. escape ULPS: rx_ulps observed, esc_release exits to LP-11
//   6. escape Trigger-Reset 8'h46: Mark-1 hold + exit sequence
//   7. error injection: unknown escape command 8'h00 -> irq, irq_clear
//   8. error injection: bad HS sync byte -> irq, no RX bytes, irq_clear
// ============================================================================
`timescale 1ns/1ps
module D_PHY_tb;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // host interface
  logic       hs_req = 0;
  logic [7:0] hs_tx_data = 0;
  logic       hs_tx_valid = 0;
  wire        hs_tx_ready;
  wire        hs_tx_done;
  logic       esc_req = 0;
  logic [7:0] esc_cmd = 0;
  logic       esc_release = 0;
  logic [7:0] lpdt_data = 0;
  logic       lpdt_valid = 0;
  logic       lpdt_last = 0;
  wire        lpdt_ready;
  wire        esc_done;
  logic       irq_clear = 0;
  wire        irq;

  // data lane TX pads
  wire d_lp_p, d_lp_n, d_hs_p, d_hs_n, d_hs_en;
  // clock lane pads
  wire c_lp_p, c_lp_n, c_hs_p, c_hs_n, c_hs_en;

  // injection mux: TB can seize the lane feeding the RX decoder
  logic       inj = 0;
  logic       i_lp_p = 1, i_lp_n = 1;
  logic       i_hs_p = 0, i_hs_n = 1, i_hs_en = 0;
  wire r_lp_p  = inj ? i_lp_p  : d_lp_p;
  wire r_lp_n  = inj ? i_lp_n  : d_lp_n;
  wire r_hs_p  = inj ? i_hs_p  : d_hs_p;
  wire r_hs_n  = inj ? i_hs_n  : d_hs_n;
  wire r_hs_en = inj ? i_hs_en : d_hs_en;

  // RX decode outputs
  wire       rx_hs_active;
  wire [7:0] rx_data;
  wire       rx_data_valid;
  wire [7:0] rx_esc_cmd;
  wire       rx_esc_valid;
  wire       rx_ulps;

  int errors = 0;

  D_PHY_top #(.DW(32), .AW(32)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .hs_req(hs_req), .hs_tx_data(hs_tx_data), .hs_tx_valid(hs_tx_valid),
    .hs_tx_ready(hs_tx_ready), .hs_tx_done(hs_tx_done),
    .esc_req(esc_req), .esc_cmd(esc_cmd), .esc_release(esc_release),
    .lpdt_data(lpdt_data), .lpdt_valid(lpdt_valid), .lpdt_last(lpdt_last),
    .lpdt_ready(lpdt_ready), .esc_done(esc_done),
    .d_lp_p(d_lp_p), .d_lp_n(d_lp_n),
    .d_hs_p(d_hs_p), .d_hs_n(d_hs_n), .d_hs_en(d_hs_en),
    .c_lp_p(c_lp_p), .c_lp_n(c_lp_n),
    .c_hs_p(c_hs_p), .c_hs_n(c_hs_n), .c_hs_en(c_hs_en),
    .r_lp_p(r_lp_p), .r_lp_n(r_lp_n),
    .r_hs_p(r_hs_p), .r_hs_n(r_hs_n), .r_hs_en(r_hs_en),
    .rx_hs_active(rx_hs_active), .rx_data(rx_data),
    .rx_data_valid(rx_data_valid), .rx_esc_cmd(rx_esc_cmd),
    .rx_esc_valid(rx_esc_valid), .rx_ulps(rx_ulps)
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

  // expected payload bytes (shared by sender + monitor)
  logic [7:0] exp_bytes [0:63];
  int         exp_n;
  logic [7:0] exp_esc;

  // RX capture queues (plain arrays: iverilog-safe)
  logic [7:0] rxq [0:63];
  int         rxn = 0;
  logic [7:0] escq [0:15];
  int         escn = 0;
  int         rxn_mark, escn_mark;

  always @(posedge clk) begin
    if (rx_data_valid) begin
      rxq[rxn] = rx_data;
      rxn = rxn + 1;
    end
    if (rx_esc_valid) begin
      escq[escn] = rx_esc_cmd;
      escn = escn + 1;
    end
  end

  task automatic mark_rx;
    begin rxn_mark = rxn; escn_mark = escn; end
  endtask

  // compare bytes captured since mark
  task automatic check_rxq(input int n, input string tag);
    for (int i = 0; i < n; i++)
      check(rxq[rxn_mark + i] === exp_bytes[i],
            $sformatf("%s: rx byte %0d got=%h exp=%h",
                      tag, i, rxq[rxn_mark + i], exp_bytes[i]));
    check(rxn - rxn_mark === n,
          $sformatf("%s: rx byte count got=%0d exp=%0d", tag, rxn - rxn_mark, n));
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int DPHY_FSM_TOTAL = 33; // TX: 18 states + RX: 15 states
  logic [32:0] fsm_seen = '0;         // visited-state bitmap
  wire  [4:0] dut_tstate = dut.tstate;   // hierarchical FSM probes
  wire  [3:0] dut_rstate = dut.rstate;

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
    fsm_seen[dut_tstate]      <= 1'b1;
    fsm_seen[18 + dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit first_cycle = 1;   // skip the very first posedge (DUT reset values
                         // land in that NBA region)
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check({d_lp_p, d_lp_n} === 2'b11 && {c_lp_p, c_lp_n} === 2'b11 &&
                d_hs_en === 1'b0 && c_hs_en === 1'b0 && irq === 1'b0 &&
                rx_data_valid === 1'b0 && rx_esc_valid === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: irq mirrors the sticky error flag
      sva_check(irq === dut.err_sticky, "A2 irq mirrors err_sticky");
      // A3: rx_hs_active exactly while the RX FSM decodes an HS burst
      sva_check(rx_hs_active === ((dut_rstate == 4'd3) || (dut_rstate == 4'd4)),
                "A3 rx_hs_active mirrors rstate");
      // A4: rx_ulps exactly while the RX FSM sits in ULPS
      sva_check(rx_ulps === (dut_rstate == 4'd10), "A4 rx_ulps mirrors rstate");
      // A5: enabled HS drivers are always differential (data + clock lane)
      sva_check(!d_hs_en || (d_hs_n === ~d_hs_p), "A5 data lane differential");
      sva_check(!c_hs_en || (c_hs_n === ~c_hs_p), "A6 clock lane differential");
      // A7: hs_tx_ready mirrors skid-buffer occupancy and HS phase
      sva_check(hs_tx_ready === (~dut.buf_valid &
                ((dut_tstate == 5'd4) | (dut_tstate == 5'd5))),
                "A7 hs_tx_ready mirrors buf/state");
      // A8: stopped lane is LP-11 with HS drivers off
      sva_check((dut_tstate != 5'd0) ||
                ({d_lp_p, d_lp_n} === 2'b11 && d_hs_en === 1'b0),
                "A8 stop state is LP-11");
    end
  end

  // ---- passive lane recorder -------------------------------------------
  // Replaces the forked mon_* coroutines on the Verilator path: with
  // 5.006 --timing, concurrent timing coroutines lose wakeups / resume
  // ~10us late (the directed phase then misaligns with the free-running
  // DUT clock). The recorder samples the data lane every negedge (same
  // sampling point as the original monitors); checks run post-hoc from
  // the single stimulus coroutine.
  logic [1:0] rec_lp   [0:1023];
  logic       rec_hsen [0:1023];
  logic       rec_hsp  [0:1023];
  logic       rec_chen [0:1023];
  logic       rec_chsp [0:1023];
  logic       rec_rxhs [0:1023];
  int  rec_n = 0;
  bit  rec_en = 1'b0;
  int  mon_guard;
  always @(negedge clk) begin
    if (rec_en && rec_n < 1024) begin
      rec_lp[rec_n]   = {d_lp_p, d_lp_n};
      rec_hsen[rec_n] = d_hs_en;
      rec_hsp[rec_n]  = d_hs_p;
      rec_chen[rec_n] = c_hs_en;
      rec_chsp[rec_n] = c_hs_p;
      rec_rxhs[rec_n] = rx_hs_active;
      rec_n = rec_n + 1;
    end
  end

  // bounded wait until the lane shows LP-11 with HS drivers off
  task automatic wait_lane_idle;
    begin
      mon_guard = 0;
      while (!({d_lp_p, d_lp_n} === 2'b11 && d_hs_en === 1'b0) &&
             mon_guard < 2000) begin
        @(negedge clk);
        mon_guard++;
      end
      check(mon_guard < 2000, "lane did not return to LP-11");
      repeat (2) @(negedge clk);
    end
  endtask

  // post-hoc equivalent of mon_hs (works on the recorder arrays)
  task automatic pc_mon_hs(input int n, input string tag);
    logic [7:0] sh;
    logic       lb, c0;
    int         idx;
    begin
      idx = 0;
      while (idx < rec_n && rec_lp[idx] !== 2'b01) idx++;  // skip idle
      check(idx < rec_n, {tag, ": HS SoT LP-01 not seen"});
      idx = idx + 1;
      check(rec_lp[idx] === 2'b00, {tag, ": HS SoT LP-00 bridge"});
      idx = idx + 1;
      check(rec_hsen[idx] === 1'b1 && rec_hsp[idx] === 1'b0,
            {tag, ": HS SoT HS-0 entry"});
      check(rec_chen[idx] === 1'b1, {tag, ": clock lane HS enabled"});
      sh = 8'h00;
      c0 = rec_chsp[idx];
      for (int i = 0; i < 8; i++) begin
        idx = idx + 1;
        check(rec_hsen[idx] === 1'b1, {tag, ": HS sync driver enabled"});
        sh = {rec_hsp[idx], sh[7:1]};
        if (i == 1) check(rec_chsp[idx] !== rec_chsp[idx - 1],
                          {tag, ": HS clock toggles"});
      end
      check(sh === 8'hB8, {tag, ": HS sync byte"});
      check(rec_rxhs[idx] === 1'b1, {tag, ": rx_hs_active during payload"});
      for (int b = 0; b < n; b++) begin
        sh = 8'h00;
        for (int i = 0; i < 8; i++) begin
          idx = idx + 1;
          check(rec_hsen[idx] === 1'b1, {tag, ": HS data driver enabled"});
          sh = {rec_hsp[idx], sh[7:1]};
        end
        check(sh === exp_bytes[b],
              $sformatf("%s: HS wire byte %0d got=%h exp=%h",
                        tag, b, sh, exp_bytes[b]));
      end
      lb = rec_hsp[idx];
      idx = idx + 1;
      check(rec_hsen[idx] === 1'b1 && rec_hsp[idx] === ~lb,
            {tag, ": HS EoT last bit inverted"});
      idx = idx + 1;
      check(rec_hsen[idx] === 1'b1 && rec_hsp[idx] === lb,
            {tag, ": HS EoT last level held"});
      idx = idx + 1;
      check(rec_hsen[idx] === 1'b0 && rec_lp[idx] === 2'b11,
            {tag, ": HS EoT return to LP-11"});
    end
  endtask

  // common tail of an injection sequence: return the lane to LP-11,
  // release the mux, expect the sticky irq, then clear it
  task automatic inj_err_tail(input string tag);
    begin
      @(negedge clk);
      i_hs_en <= 1'b0;
      i_lp_p  <= 1'b1;
      i_lp_n  <= 1'b1;
      @(negedge clk);
      inj <= 1'b0;
      repeat (2) @(negedge clk);
      check(irq === 1'b1, {tag, ": irq not raised"});
      @(negedge clk);
      irq_clear <= 1'b1;
      @(negedge clk);
      irq_clear <= 1'b0;
      @(negedge clk);
      check(irq === 1'b0, {tag, ": irq not cleared"});
    end
  endtask

  // post-hoc equivalent of mon_esc_entry + the per-mode exit monitors
  // mode: 0 = LPDT (exp_n data bytes), 1 = ULPS, 2 = Trigger-Reset
  task automatic pc_mon_esc(input logic [7:0] cmd, input int mode,
                            input string tag);
    logic [7:0] sh;
    int         idx;
    begin
      idx = 0;
      while (idx < rec_n && rec_lp[idx] !== 2'b10) idx++;  // skip idle
      check(idx < rec_n, {tag, ": ESC entry LP-10 not seen"});
      idx = idx + 1;
      check(rec_lp[idx] === 2'b00, {tag, ": ESC entry LP-00"});
      idx = idx + 1;
      check(rec_lp[idx] === 2'b01, {tag, ": ESC entry LP-01"});
      idx = idx + 1;
      check(rec_lp[idx] === 2'b00, {tag, ": ESC entry LP-00 (2nd)"});
      sh = 8'h00;
      for (int i = 0; i < 8; i++) begin
        idx = idx + 1;
        check(rec_lp[idx] === 2'b10 || rec_lp[idx] === 2'b00,
              {tag, ": ESC cmd bit level"});
        sh = {rec_lp[idx][1], sh[7:1]};
      end
      check(sh === cmd, {tag, ": ESC cmd on wire"});
      if (mode == 0) begin
        for (int b = 0; b < exp_n; b++) begin
          sh = 8'h00;
          for (int i = 0; i < 8; i++) begin
            idx = idx + 1;
            check(rec_lp[idx] === 2'b10 || rec_lp[idx] === 2'b00,
                  {tag, ": LPDT bit level"});
            sh = {rec_lp[idx][1], sh[7:1]};
          end
          check(sh === exp_bytes[b],
                $sformatf("%s: LPDT wire byte %0d got=%h exp=%h",
                          tag, b, sh, exp_bytes[b]));
        end
        idx = idx + 1;
        check(rec_lp[idx] === 2'b01, {tag, ": LPDT exit LP-01 space"});
        idx = idx + 1;
        check(rec_lp[idx] === 2'b10, {tag, ": LPDT exit LP-10 Mark-1"});
        idx = idx + 1;
        check(rec_lp[idx] === 2'b11, {tag, ": LPDT exit LP-11 stop"});
      end else if (mode == 1) begin
        idx = idx + 1;
        check(rec_lp[idx] === 2'b00, {tag, ": ULPS lines held LP-00"});
        while (idx < rec_n && rec_lp[idx] !== 2'b10) idx++;
        check(idx < rec_n, {tag, ": ULPS exit LP-10 not seen"});
        idx = idx + 1;
        check(rec_lp[idx] === 2'b11, {tag, ": ULPS exit LP-11 stop"});
      end else begin
        for (int i = 0; i < 4; i++) begin
          idx = idx + 1;
          check(rec_lp[idx] === 2'b00, {tag, ": Trigger Mark-1 hold LP-00"});
        end
        idx = idx + 1;
        check(rec_lp[idx] === 2'b10, {tag, ": Trigger exit LP-10"});
        idx = idx + 1;
        check(rec_lp[idx] === 2'b11, {tag, ": Trigger exit LP-11 stop"});
      end
    end
  endtask
`endif

  // ------------------------------------------------------------------
  // host sender tasks
  // ------------------------------------------------------------------
  task automatic hs_push(input logic [7:0] b);
    begin
      @(negedge clk);
      hs_tx_data <= b;
      hs_tx_valid <= 1'b1;
      @(posedge clk);
      while (hs_tx_ready !== 1'b1) @(posedge clk);   // accepted at this edge
      @(negedge clk);
      hs_tx_valid <= 1'b0;
    end
  endtask

  // caller must ensure the lane is idle (LP-11) before calling
  task automatic hs_send(input int n);
    begin
      @(negedge clk);
      hs_req <= 1'b1;
      @(negedge clk);
      hs_req <= 1'b0;
      for (int i = 0; i < n; i++) hs_push(exp_bytes[i]);
    end
  endtask

  task automatic lpdt_push(input logic [7:0] b, input bit last);
    begin
      @(negedge clk);
      lpdt_data  <= b;
      lpdt_last  <= last;
      lpdt_valid <= 1'b1;
      @(posedge clk);
      while (lpdt_ready !== 1'b1) @(posedge clk);
      @(negedge clk);
      lpdt_valid <= 1'b0;
      lpdt_last  <= 1'b0;
    end
  endtask

  task automatic esc_start(input logic [7:0] cmd);
    begin
      @(negedge clk);
      esc_cmd <= cmd;
      esc_req <= 1'b1;
      @(negedge clk);
      esc_req <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // wire-level monitor tasks (sample on negedge: pads are stable)
  // ------------------------------------------------------------------
  task automatic mon_hs;
    logic [7:0] sh;
    logic       lb;
    logic       cprev;
    begin
      // SoT: LP-01 (HS request) -> LP-00 (bridge) -> HS-0
      do @(negedge clk); while ({d_lp_p, d_lp_n} !== 2'b01);
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "HS SoT: LP-00 bridge after LP-01");
      @(negedge clk);
      check(d_hs_en === 1'b1 && d_hs_p === 1'b0 && d_hs_n === 1'b1,
            "HS SoT: HS-0 differential entry");
      check(c_hs_en === 1'b1, "HS SoT: clock lane HS enabled");
      // sync byte 8'hB8 LSB-first
      sh = 8'h00;
      cprev = c_hs_p;
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        check(d_hs_en === 1'b1, "HS sync: driver still enabled");
        check(d_hs_n === ~d_hs_p, "HS sync: differential levels");
        sh = {d_hs_p, sh[7:1]};
        if (i == 1) check(c_hs_p !== cprev, "HS clock lane toggling");
        cprev = c_hs_p;
      end
      check(sh === 8'hB8, $sformatf("HS sync byte got=%h exp=B8", sh));
      check(rx_hs_active === 1'b1, "rx_hs_active during payload");
      // payload bytes
      for (int b = 0; b < exp_n; b++) begin
        sh = 8'h00;
        for (int i = 0; i < 8; i++) begin
          @(negedge clk);
          check(d_hs_en === 1'b1, "HS data: driver enabled");
          sh = {d_hs_p, sh[7:1]};
        end
        check(sh === exp_bytes[b],
              $sformatf("HS wire byte %0d got=%h exp=%h", b, sh, exp_bytes[b]));
      end
      lb = d_hs_p;
      // EoT: last bit inverted, then held, then LP-11
      @(negedge clk);
      check(d_hs_en === 1'b1 && d_hs_p === ~lb, "HS EoT: last bit inverted");
      @(negedge clk);
      check(d_hs_en === 1'b1 && d_hs_p === lb, "HS EoT: last level held");
      @(negedge clk);
      check(d_hs_en === 1'b0 && {d_lp_p, d_lp_n} === 2'b11,
            "HS EoT: return to LP-11");
    end
  endtask

  // escape entry + command; leaves the lane right after the command byte
  task automatic mon_esc_entry;
    logic [7:0] sh;
    begin
      do @(negedge clk); while ({d_lp_p, d_lp_n} !== 2'b10);
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "ESC entry: LP-00 after LP-10");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b01, "ESC entry: LP-01");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "ESC entry: LP-00");
      sh = 8'h00;
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        check(({d_lp_p, d_lp_n} === 2'b10) || ({d_lp_p, d_lp_n} === 2'b00),
              "ESC cmd: bit level is LP-10/LP-00");
        sh = {d_lp_p, sh[7:1]};
      end
      check(sh === exp_esc,
            $sformatf("ESC cmd on wire got=%h exp=%h", sh, exp_esc));
    end
  endtask

  // LPDT bytes + exit (call right after mon_esc_entry)
  task automatic mon_lpdt_exit;
    logic [7:0] sh;
    begin
      for (int b = 0; b < exp_n; b++) begin
        sh = 8'h00;
        for (int i = 0; i < 8; i++) begin
          @(negedge clk);
          check(({d_lp_p, d_lp_n} === 2'b10) || ({d_lp_p, d_lp_n} === 2'b00),
                "LPDT: bit level is LP-10/LP-00");
          sh = {d_lp_p, sh[7:1]};
        end
        check(sh === exp_bytes[b],
              $sformatf("LPDT wire byte %0d got=%h exp=%h", b, sh, exp_bytes[b]));
      end
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b01, "LPDT exit: LP-01 space");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b10, "LPDT exit: LP-10 Mark-1");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b11, "LPDT exit: LP-11 stop");
    end
  endtask

  // ULPS phase + exit (call right after mon_esc_entry)
  task automatic mon_ulps_exit;
    begin
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b00, "ULPS: lines held LP-00");
      do @(negedge clk); while ({d_lp_p, d_lp_n} !== 2'b10);
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b11, "ULPS exit: LP-11 stop");
    end
  endtask

  // Trigger Mark-1 + exit (call right after mon_esc_entry)
  task automatic mon_trig_exit;
    begin
      for (int i = 0; i < 4; i++) begin
        @(negedge clk);
        check({d_lp_p, d_lp_n} === 2'b00, "Trigger: Mark-1 hold LP-00");
      end
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b10, "Trigger exit: LP-10");
      @(negedge clk);
      check({d_lp_p, d_lp_n} === 2'b11, "Trigger exit: LP-11 stop");
    end
  endtask

  // ------------------------------------------------------------------
  // lane injection tasks (1 clk per level/bit)
  // ------------------------------------------------------------------
  task automatic inj_lp(input logic [1:0] lv);
    begin
      @(negedge clk);
      i_lp_p <= lv[1];
      i_lp_n <= lv[0];
    end
  endtask

  task automatic inj_hs_bit(input logic b);
    begin
      @(negedge clk);
      i_hs_en <= 1'b1;
      i_hs_p  <= b;
      i_hs_n  <= ~b;
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
    check({d_lp_p, d_lp_n} === 2'b11, "reset: data lane LP-11");
    check({c_lp_p, c_lp_n} === 2'b11, "reset: clock lane LP-11");
    check(d_hs_en === 1'b0 && c_hs_en === 1'b0, "reset: HS drivers off");
    check(irq === 1'b0, "reset: irq low");

    // ---- check 2: HS burst, 4 bytes, wire + loopback compare ----
    exp_bytes[0] = 8'h11;
    exp_bytes[1] = 8'h22;
    exp_bytes[2] = 8'h33;
    exp_bytes[3] = 8'h44;
    exp_n = 4;
    mark_rx;
`ifdef VERILATOR
    rec_n = 0; rec_en = 1'b1;               // single coroutine + recorder
    hs_send(4);
    wait_lane_idle;
    rec_en = 1'b0;
    pc_mon_hs(4, "HS burst #1");
`else
    fork
      hs_send(4);
      mon_hs;
    join
`endif
    repeat (2) @(negedge clk);
    check_rxq(4, "HS burst #1 loopback");

    // ---- check 3: back-to-back HS burst, 1 byte ----
    exp_bytes[0] = 8'hA5;
    exp_n = 1;
    mark_rx;
`ifdef VERILATOR
    rec_n = 0; rec_en = 1'b1;
    hs_send(1);
    wait_lane_idle;
    rec_en = 1'b0;
    pc_mon_hs(1, "HS burst #2");
`else
    fork
      hs_send(1);
      mon_hs;
    join
`endif
    repeat (2) @(negedge clk);
    check_rxq(1, "HS burst #2 loopback");

    // ---- check 4: escape LPDT (cmd 8'h87 + 2 data bytes) ----
    exp_esc = 8'h87;
    exp_bytes[0] = 8'h96;
    exp_bytes[1] = 8'h3C;
    exp_n = 2;
    mark_rx;
`ifdef VERILATOR
    rec_n = 0; rec_en = 1'b1;
    esc_start(8'h87);
    lpdt_push(8'h96, 0);
    lpdt_push(8'h3C, 1);
    mon_guard = 0;
    while (esc_done !== 1'b1 && mon_guard < 2000) begin
      @(negedge clk);
      mon_guard++;
    end
    check(esc_done === 1'b1, "LPDT: esc_done timeout");
    wait_lane_idle;
    rec_en = 1'b0;
    pc_mon_esc(8'h87, 0, "LPDT");
`else
    fork
      begin
        esc_start(8'h87);
        lpdt_push(8'h96, 0);
        lpdt_push(8'h3C, 1);
        @(posedge esc_done);
      end
      begin
        mon_esc_entry;
        mon_lpdt_exit;
      end
    join
`endif
    repeat (2) @(negedge clk);
    check_rxq(2, "LPDT loopback");
    check(escn - escn_mark === 1 && escq[escn_mark] === 8'h87,
          "LPDT: rx escape command 8'h87 decoded");

    // ---- check 5: escape ULPS ----
    exp_esc = 8'h78;
    mark_rx;
`ifdef VERILATOR
    rec_n = 0; rec_en = 1'b1;
    esc_start(8'h78);
    mon_guard = 0;
    while (rx_ulps !== 1'b1 && mon_guard < 2000) begin
      @(negedge clk);
      mon_guard++;
    end
    check(rx_ulps === 1'b1, "ULPS: rx_ulps raised");
    repeat (4) @(negedge clk);
    esc_release <= 1'b1;
    @(negedge clk);
    esc_release <= 1'b0;
    mon_guard = 0;
    while (esc_done !== 1'b1 && mon_guard < 2000) begin
      @(negedge clk);
      mon_guard++;
    end
    @(negedge clk);
    check(rx_ulps === 1'b0, "ULPS: rx_ulps cleared after exit");
    rec_en = 1'b0;
    pc_mon_esc(8'h78, 1, "ULPS");
`else
    fork
      begin
        esc_start(8'h78);
        wait (rx_ulps === 1'b1);
        check(rx_ulps === 1'b1, "ULPS: rx_ulps raised");
        repeat (4) @(negedge clk);
        esc_release <= 1'b1;
        @(negedge clk);
        esc_release <= 1'b0;
        @(posedge esc_done);
        @(negedge clk);
        check(rx_ulps === 1'b0, "ULPS: rx_ulps cleared after exit");
      end
      begin
        mon_esc_entry;
        mon_ulps_exit;
      end
    join
`endif
    check(escn - escn_mark === 1 && escq[escn_mark] === 8'h78,
          "ULPS: rx escape command 8'h78 decoded");

    // ---- check 6: escape Trigger-Reset ----
    exp_esc = 8'h46;
    mark_rx;
`ifdef VERILATOR
    rec_n = 0; rec_en = 1'b1;
    esc_start(8'h46);
    mon_guard = 0;
    while (esc_done !== 1'b1 && mon_guard < 2000) begin
      @(negedge clk);
      mon_guard++;
    end
    check(esc_done === 1'b1, "Trigger: esc_done timeout");
    wait_lane_idle;
    rec_en = 1'b0;
    pc_mon_esc(8'h46, 2, "Trigger");
`else
    fork
      begin
        esc_start(8'h46);
        @(posedge esc_done);
      end
      begin
        mon_esc_entry;
        mon_trig_exit;
      end
    join
`endif
    check(escn - escn_mark === 1 && escq[escn_mark] === 8'h46,
          "Trigger: rx escape command 8'h46 decoded");

    // ---- check 7: inject unknown escape command 8'h00 -> irq ----
    mark_rx;
    @(negedge clk);
    inj <= 1'b1;
    i_hs_en <= 1'b0;
    inj_lp(2'b10);                 // entry: LP-10
    inj_lp(2'b00);                 // LP-00
    inj_lp(2'b01);                 // LP-01
    inj_lp(2'b00);                 // LP-00
    for (int i = 0; i < 8; i++) inj_lp(2'b00);  // cmd = 8'h00 (unknown)
    inj_lp(2'b01);                 // exit space
    inj_lp(2'b10);                 // Mark-1
    inj_lp(2'b11);                 // stop
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: unknown escape cmd raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared by irq_clear");

    // ---- check 8: inject bad HS sync byte -> irq ----
    mark_rx;
    @(negedge clk);
    inj <= 1'b1;
    inj_lp(2'b01);                 // LP-01 HS request
    inj_lp(2'b00);                 // LP-00 bridge
    inj_hs_bit(1'b0);              // HS-0
    for (int i = 0; i < 8; i++) inj_hs_bit(1'b0);  // sync = 8'h00 (bad)
    @(negedge clk);
    i_hs_en <= 1'b0;               // back to LP-11
    i_lp_p  <= 1'b1;
    i_lp_n  <= 1'b1;
    @(negedge clk);
    inj <= 1'b0;
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "error injection: bad HS sync raises irq");
    check(rxn === rxn_mark, "bad HS sync: no payload byte decoded");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized transactions. Classes: HS bursts of 1-8 random bytes
    // (boundary 0x00/0xFF; every 4th burst also wire-checked post-hoc via
    // the recorder), escape LPDT with 1-4 random bytes, escape ULPS with
    // random hold length, escape Trigger-Reset, plus error injection
    // (round-robin selector): unknown escape command, bad HS sync byte,
    // LP-00 from STOP, HS abort during sync. All payloads/commands are
    // looped back and self-checked against the capture queues; irq is
    // checked after every transaction.
    begin : crv_phase
      int n_hs = 0, n_lpdt = 0, n_ulps = 0, n_trig = 0;
      int n_euc = 0, n_ebs = 0, n_e00 = 0, n_eab = 0;
      int n_ehu = 0, n_esot = 0, n_eent = 0, n_ecmd = 0, n_ephz = 0, n_eext = 0;
      int roll, eroll = 0, nb;
      logic [7:0] w_b, cmd_c;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 12) begin
          // ---- random HS burst + loopback compare ----
          // (the first burst is empty-payload: TX goes straight from
          // the sync byte to EoT, covering the no-payload arm)
          n_hs++;
          nb = (n_hs == 1) ? 0 : 1 + $urandom_range(0, 7);
          for (int i = 0; i < nb; i++) begin
            if (t == 0)      w_b = 8'h00;
            else if (t == 1) w_b = 8'hFF;
            else begin
              roll = $urandom_range(0, 9);
              w_b = (roll == 0) ? 8'h00 : (roll == 1) ? 8'hFF
                                : 8'($urandom_range(0, 255));
            end
            exp_bytes[i] = w_b;
          end
          exp_n = nb;
          mark_rx;
          if (n_hs % 4 == 1) begin
            rec_n = 0; rec_en = 1'b1;      // wire-check every 4th burst
            hs_send(nb);
            wait_lane_idle;
            rec_en = 1'b0;
            pc_mon_hs(nb, "CRV HS");
          end else begin
            hs_send(nb);
            wait_lane_idle;
          end
          check_rxq(nb, "CRV HS loopback");
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during clean HS burst");
          end
        end else if (roll < 16) begin
          // ---- random escape LPDT + loopback compare ----
          // (the first LPDT has zero bytes: host underrun at the first
          // byte boundary -> lpdt_exit LP-01 space + early T_EX_10 arm)
          n_lpdt++;
          nb = (n_lpdt == 1) ? 0 : 1 + $urandom_range(0, 3);
          for (int i = 0; i < nb; i++)
            exp_bytes[i] = 8'($urandom_range(0, 255));
          exp_n = nb;
          mark_rx;
          esc_start(8'h87);
          for (int i = 0; i < nb; i++)
            lpdt_push(exp_bytes[i], i == nb - 1);
          mon_guard = 0;
          while (esc_done !== 1'b1 && mon_guard < 2000) begin
            @(negedge clk);
            mon_guard++;
          end
          check(esc_done === 1'b1, "CRV LPDT: esc_done timeout");
          wait_lane_idle;
          check_rxq(nb, "CRV LPDT loopback");
          if (!(escn - escn_mark === 1 && escq[escn_mark] === 8'h87)) begin
            errors++; $display("ERROR: CRV LPDT: esc cmd not decoded");
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during clean LPDT");
          end
        end else if (roll < 19) begin
          // ---- escape ULPS with random hold length ----
          n_ulps++;
          mark_rx;
          esc_start(8'h78);
          mon_guard = 0;
          while (rx_ulps !== 1'b1 && mon_guard < 2000) begin
            @(negedge clk);
            mon_guard++;
          end
          check(rx_ulps === 1'b1, "CRV ULPS: rx_ulps not raised");
          repeat (1 + $urandom_range(0, 7)) @(negedge clk);
          esc_release <= 1'b1;
          @(negedge clk);
          esc_release <= 1'b0;
          mon_guard = 0;
          while (esc_done !== 1'b1 && mon_guard < 2000) begin
            @(negedge clk);
            mon_guard++;
          end
          @(negedge clk);
          check(rx_ulps === 1'b0, "CRV ULPS: rx_ulps not cleared");
          if (!(escn - escn_mark === 1 && escq[escn_mark] === 8'h78)) begin
            errors++; $display("ERROR: CRV ULPS: esc cmd not decoded");
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during clean ULPS");
          end
        end else if (roll < 22) begin
          // ---- escape Trigger-Reset ----
          n_trig++;
          mark_rx;
          esc_start(8'h46);
          mon_guard = 0;
          while (esc_done !== 1'b1 && mon_guard < 2000) begin
            @(negedge clk);
            mon_guard++;
          end
          check(esc_done === 1'b1, "CRV Trigger: esc_done timeout");
          wait_lane_idle;
          if (!(escn - escn_mark === 1 && escq[escn_mark] === 8'h46)) begin
            errors++; $display("ERROR: CRV Trigger: esc cmd not decoded");
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during clean Trigger");
          end
        end else begin
          // ---- error-injection classes (round-robin) ----
          mark_rx;
          case (eroll)
            0: begin
              // unknown escape command -> irq (TX-side just exits)
              n_euc++;
              cmd_c = 8'($urandom_range(0, 255));
              if (cmd_c == 8'h87 || cmd_c == 8'h78 || cmd_c == 8'h46)
                cmd_c = cmd_c ^ 8'h01;          // rejection sampling
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              for (int i = 0; i < 8; i++)
                inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b01);
              inj_lp(2'b10);
              inj_lp(2'b11);
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV unknown esc cmd: no irq");
              end
              @(negedge clk);
              irq_clear <= 1'b1;
              @(negedge clk);
              irq_clear <= 1'b0;
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (euc)");
              end
            end
            1: begin
              // bad HS sync byte -> irq, no payload decoded
              n_ebs++;
              cmd_c = 8'($urandom_range(0, 255));
              if (cmd_c == 8'hB8) cmd_c = 8'hB9;  // rejection sampling
              @(negedge clk);
              inj <= 1'b1;
              inj_lp(2'b01);
              inj_lp(2'b00);
              inj_hs_bit(1'b0);
              for (int i = 0; i < 8; i++) inj_hs_bit(cmd_c[i]);
              @(negedge clk);
              i_hs_en <= 1'b0;
              i_lp_p  <= 1'b1;
              i_lp_n  <= 1'b1;
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad HS sync: no irq");
              end
              if (rxn !== rxn_mark) begin
                errors++; $display("ERROR: CRV bad HS sync: payload decoded");
              end
              @(negedge clk);
              irq_clear <= 1'b1;
              @(negedge clk);
              irq_clear <= 1'b0;
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (ebs)");
              end
            end
            2: begin
              // LP-00 driven from STOP (illegal SoT) -> irq
              n_e00++;
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b00);
              inj_lp(2'b11);
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV LP-00 from STOP: no irq");
              end
              @(negedge clk);
              irq_clear <= 1'b1;
              @(negedge clk);
              irq_clear <= 1'b0;
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (e00)");
              end
            end
            3: begin
              // HS abort during the sync byte (hs_en drops) -> irq
              n_eab++;
              @(negedge clk);
              inj <= 1'b1;
              inj_lp(2'b01);
              inj_lp(2'b00);
              inj_hs_bit(1'b0);
              cmd_c = 8'hB8;
              for (int i = 0; i < 3; i++) inj_hs_bit(cmd_c[i]);
              @(negedge clk);
              i_hs_en <= 1'b0;                  // abort mid-sync
              i_lp_p  <= 1'b1;
              i_lp_n  <= 1'b1;
              @(negedge clk);
              inj <= 1'b0;
              repeat (2) @(negedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV HS abort in sync: no irq");
              end
              @(negedge clk);
              irq_clear <= 1'b1;
              @(negedge clk);
              irq_clear <= 1'b0;
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (eab)");
              end
            end
            4: begin
              // host-side unknown escape command: TX walks the entry and
              // the command, then takes the default->exit arm; the RX
              // decoder flags the unknown command (irq)
              n_ehu++;
              cmd_c = 8'($urandom_range(0, 255));
              if (cmd_c == 8'h87 || cmd_c == 8'h78 || cmd_c == 8'h46)
                cmd_c = cmd_c ^ 8'h80;          // rejection sampling
              esc_start(cmd_c);
              mon_guard = 0;
              while (esc_done !== 1'b1 && mon_guard < 2000) begin
                @(negedge clk);
                mon_guard++;
              end
              check(esc_done === 1'b1, "CRV host-unkcmd: esc_done timeout");
              wait_lane_idle;
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV host unkcmd: no irq");
              end
              @(negedge clk);
              irq_clear <= 1'b1;
              @(negedge clk);
              irq_clear <= 1'b0;
              @(negedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared (ehu)");
              end
            end
            5: begin
              // SoT violations: LP-01 followed by LP-10 (R_HS1 err),
              // then LP-01/LP-00 not followed by HS-0 (R_HS2 err)
              n_esot++;
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b01);
              inj_lp(2'b10);                    // not LP-00 -> error
              inj_err_tail("CRV hs1-violation");
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b01);
              inj_lp(2'b00);
              inj_lp(2'b00);                    // no HS-0 -> error
              inj_err_tail("CRV hs2-violation");
            end
            6: begin
              // escape-entry violations: LP-10->LP-01 (R_ESC1 err),
              // LP-10/00->LP-00 (R_ESC2 err), LP-10/00/01->LP-01 (R_ESC3)
              n_eent++;
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b01);                    // not LP-00 -> error
              inj_err_tail("CRV esc1-violation");
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b00);                    // not LP-01 -> error
              inj_err_tail("CRV esc2-violation");
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b01);                    // not LP-00 -> error
              inj_err_tail("CRV esc3-violation");
            end
            7: begin
              // LP-01 inside the escape command byte (R_ESC_CMD err)
              n_ecmd++;
              cmd_c = 8'($urandom_range(0, 255));
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              for (int i = 0; i < 3; i++)
                inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b01);                    // illegal inside cmd
              inj_err_tail("CRV cmd-violation");
            end
            8: begin
              // in-phase violations: LP-11 mid-LPDT-byte (R_LPDT err),
              // LP-01 during ULPS hold (R_ULPS err), LP-01 during the
              // Trigger Mark-1 hold (R_TRIG err)
              n_ephz++;
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              cmd_c = 8'h87;
              for (int i = 0; i < 8; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              cmd_c = 8'($urandom_range(0, 255));
              for (int i = 0; i < 3; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b11);                    // LP-11 mid-byte -> error
              inj_err_tail("CRV lpdt-violation");
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              cmd_c = 8'h78;
              for (int i = 0; i < 8; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b00);
              inj_lp(2'b01);                    // LP-01 in ULPS -> error
              inj_err_tail("CRV ulps-violation");
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              cmd_c = 8'h46;
              for (int i = 0; i < 8; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b00);
              inj_lp(2'b01);                    // LP-01 in Mark-1 -> error
              inj_err_tail("CRV trig-violation");
            end
            default: begin
              // exit-sequence violations: LP-00 after the LPDT exit
              // space (R_EX1 err), LP-00 after ULPS Mark-1 (R_EX2 err)
              n_eext++;
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              cmd_c = 8'h87;
              for (int i = 0; i < 8; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              cmd_c = 8'($urandom_range(0, 255));
              for (int i = 0; i < 8; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b01);                    // exit space (byte boundary)
              inj_lp(2'b00);                    // not LP-10 -> error
              inj_err_tail("CRV ex1-violation");
              @(negedge clk);
              inj <= 1'b1;
              i_hs_en <= 1'b0;
              inj_lp(2'b10);
              inj_lp(2'b00);
              inj_lp(2'b01);
              inj_lp(2'b00);
              cmd_c = 8'h78;
              for (int i = 0; i < 8; i++) inj_lp(cmd_c[i] ? 2'b10 : 2'b00);
              inj_lp(2'b10);                    // ULPS Mark-1 -> R_EX2
              inj_lp(2'b00);                    // not LP-11 -> error
              inj_err_tail("CRV ex2-violation");
            end
          endcase
          eroll = (eroll + 1) % 10;
        end
      end
      $display("CRV: 120 txns (hs=%0d lpdt=%0d ulps=%0d trig=%0d | unkcmd=%0d badsync=%0d lp00=%0d abort=%0d hostunk=%0d sot=%0d ent=%0d cmd=%0d phz=%0d ext=%0d)",
               n_hs, n_lpdt, n_ulps, n_trig, n_euc, n_ebs, n_e00, n_eab,
               n_ehu, n_esot, n_eent, n_ecmd, n_ephz, n_eext);
    end
`endif

    repeat (4) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: D-PHY");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < DPHY_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, DPHY_FSM_TOTAL);
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
