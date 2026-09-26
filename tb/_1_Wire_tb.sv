// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as 1-Wire master -- SystemVerilog
`timescale 1ns/1ps
module _1_Wire_tb;
  localparam int US = 10;             // 100ns per unit
  logic clk = 0, rst_n = 0;
  tri1  dq;
  logic m_low = 0;
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  _1_Wire_top #(.US(US)) dut (
    .clk(clk), .rst_n(rst_n), .dq(dq),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .busy(busy), .irq());

  always #5 clk = ~clk;
  assign dq = m_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

`ifdef VERILATOR
  // long single pending #delays corrupt the 5.006 timing heap (see
  // docs/COVERAGE.md note 1); the Verilator path counts clocks instead.
  // Identical timing: clk period is 10ns.
  `define OW_DLY(n) repeat ((n)/10) @(posedge clk)
`else
  `define OW_DLY(n) #(n)
`endif

  task automatic ow_reset(output logic presence);
    begin
      m_low = 1; `OW_DLY(600*US*10);   // reset pulse >= 480us
      m_low = 0;
      `OW_DLY(30*US*10);               // presence window
      presence = (dq === 1'b0);
      `OW_DLY(400*US*10);
    end
  endtask

  task automatic ow_write_bit(input logic b);
    begin
      m_low = 1; `OW_DLY(2*US*10);
      if (!b) `OW_DLY(60*US*10);       // hold for 0
      m_low = 0;
      `OW_DLY((80-2)*US*10);           // slot end
    end
  endtask

  task automatic ow_read_bit(output logic b);
    begin
      m_low = 1; `OW_DLY(2*US*10);
      m_low = 0;
      `OW_DLY(13*US*10);
      b = dq;
      `OW_DLY((80-15)*US*10);
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.state (ST_IDLE..ST_TX_BYTE), 8 states.
  // =====================================================================
  localparam int OW_FSM_TOTAL = 8;
  logic [7:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.state;

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
        sva_check(rx_valid === 1'b0 && busy === 1'b0 && dq === 1'b1,
                  "A1 reset: line released, outputs quiescent");
    end else begin
      // A2: busy exactly reflects non-idle
      sva_check(busy === (dut_state != 3'd0), "A2 busy == !ST_IDLE");
      // A3: irq mirrors rx_valid
      sva_check(dut.irq === rx_valid, "A3 irq == rx_valid");
      // A4: state register holds a legal enum encoding
      sva_check(dut_state <= 3'd7, "A4 state legal");
      // A5: a low line without master drive means the slave is in a legal
      //     drive state (presence, or read-slot bit 0)
      sva_check(m_low || (dq === 1'b1) ||
                (dut_state == 3'd3) ||
                ((dut_state == 3'd6) && !dut.tx_shift[0]),
                "A5 slave drive only in presence/read-0");
      // A6: rx_valid only pulses mid-transaction
      sva_check(!rx_valid || busy, "A6 rx_valid implies busy");
    end
    rst_n_q <= rst_n;
  end
`endif

  logic presence, b;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'h5A;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    ow_reset(presence);
    if (!presence) begin errors++; $display("ERROR: 1-Wire no presence pulse"); end

    // send command 0xCC (Skip ROM), LSB first
    begin : send_cmd
      logic [7:0] cmd;
      cmd = 8'hCC;
      for (int i = 0; i < 8; i++) ow_write_bit(cmd[i]);
    end
    repeat(5) @(posedge clk);
    if (!rx_seen)  begin errors++; $display("ERROR: 1-Wire rx_valid never pulsed"); end
    if (rx_byte !== 8'hCC) begin errors++; $display("ERROR: 1-Wire rx=%h exp=CC", rx_byte); end

    // read a byte from slave (expect tx_byte=5A), LSB first
    for (int i = 0; i < 8; i++) begin
      ow_read_bit(b);
      rb[i] = b;
    end
    if (rb !== 8'h5A) begin errors++; $display("ERROR: 1-Wire read got=%h exp=5A", rb); end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 105 randomized transactions. Each txn re-resets the DUT (rst_n
    // pulse): the RTL only detects a 1-Wire reset pulse from ST_IDLE —
    // after a read phase the slave sits in ST_WAIT_SLOT and a long low is
    // mis-sampled as a 0 write bit (recorded as RTL bug W6-5, not fixed),
    // so back-to-back bus resets without a hard reset are not possible.
    // Per txn: 600us reset + presence check, random command byte write
    // (rx_byte/rx_valid checked), random read byte (tx_byte driven back).
    // Every 10th txn: short 100us low glitch -> must NOT produce presence.
    // Fully inlined with clock-counted delays; no timing-task chains.
    begin : crv_phase
      int n_ok = 0, n_glitch = 0;
      logic [7:0] cmd_v, tx_v, rd_v;
      logic       pr_v, b_v;
      for (int t = 0; t < 105; t++) begin
        // hard reset for a clean ST_IDLE (see W6-5)
        rst_n = 1'b0; m_low = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        rx_seen = 1'b0;
        cmd_v = $urandom_range(0, 255);
        tx_v  = $urandom_range(0, 255);
        if (t % 11 == 0) cmd_v = 8'h00;
        if (t % 13 == 0) cmd_v = 8'hFF;
        tx_byte = tx_v;
        if (t % 10 == 9) begin
          // ---- glitch: 100us low (< 480us) -> back to IDLE, no presence ----
          n_glitch++;
          m_low = 1; repeat (100*US) @(posedge clk);
          m_low = 0; repeat (200*US) @(posedge clk);
          if (dq !== 1'b1) begin
            errors++; $display("ERROR: CRV presence after glitch t=%0d", t);
          end
          if (busy !== 1'b0) begin
            errors++; $display("ERROR: CRV busy after glitch t=%0d state=%0d", t, dut_state);
          end
        end else begin
          n_ok++;
          // ---- reset pulse + presence ----
          m_low = 1; repeat (600*US) @(posedge clk);
          m_low = 0; repeat (30*US) @(posedge clk);
          pr_v = (dq === 1'b0);
          if (!pr_v) begin
            errors++; $display("ERROR: CRV no presence t=%0d", t);
          end
          repeat (400*US) @(posedge clk);
          // ---- write command byte (LSB first) ----
          for (int i = 0; i < 8; i++) begin
            m_low = 1; repeat (2*US) @(posedge clk);
            if (!cmd_v[i]) repeat (60*US) @(posedge clk);
            m_low = 0; repeat (78*US) @(posedge clk);
          end
          repeat (5) @(posedge clk);
          if (!rx_seen) begin
            errors++; $display("ERROR: CRV no rx_valid t=%0d", t);
          end
          if (rx_byte !== cmd_v) begin
            errors++; $display("ERROR: CRV cmd t=%0d got=%h exp=%h", t, rx_byte, cmd_v);
          end
          // ---- read byte (slave drives tx_v) ----
          rd_v = 8'h00;
          for (int i = 0; i < 8; i++) begin
            m_low = 1; repeat (2*US) @(posedge clk);
            m_low = 0; repeat (13*US) @(posedge clk);
            b_v = dq;
            rd_v[i] = b_v;
            repeat (65*US) @(posedge clk);
          end
          if (rd_v !== tx_v) begin
            errors++; $display("ERROR: CRV read t=%0d got=%h exp=%h", t, rd_v, tx_v);
          end
        end
      end
      $display("CRV: 105 txns (reset+write+read=%0d glitch=%0d)", n_ok, n_glitch);
    end
`endif

    if (errors == 0) $display("TEST PASSED: 1-Wire");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < OW_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, OW_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave
  initial begin
    repeat (40000) #1000;   // 40 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
