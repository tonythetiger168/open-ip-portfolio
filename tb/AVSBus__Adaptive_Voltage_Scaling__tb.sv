// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for AVSBus__Adaptive_Voltage_Scaling__top
// AVSBus master model: bit-banged sclk/sdat frames (START+addr+cmd+data+CRC4),
// ACK/NACK sampling, GET readback with CRC check. Checks: reset state,
// set-voltage ramp observation (busy) + get readback compare x3,
// illegal-address NACK, CRC-error NACK + irq, unknown-command NACK.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module AVSBus__Adaptive_Voltage_Scaling__tb;

  localparam logic [6:0] SLAVE_ADDR = 7'h55;
  localparam logic [7:0] CMD_SET    = 8'h01;
  localparam logic [7:0] CMD_GET    = 8'h02;

  logic clk = 0, rst_n = 0;
  logic sclk = 0;
  tri1  sdat;                 // bus line with pull-up
  logic mst_oe = 0, mst_bit = 0;
  logic [11:0] vdac;
  logic busy, irq;

  assign sdat = mst_oe ? mst_bit : 1'bz;

  int errors = 0;
  int irq_seen = 0;

  AVSBus__Adaptive_Voltage_Scaling__top dut (
    .clk(clk), .rst_n(rst_n),
    .sclk(sclk), .sdat(sdat),
    .vdac(vdac), .busy(busy), .irq(irq)
  );

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen++;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int AVS_FSM_TOTAL = 5;   // AV_IDLE/RX/ACK/TX/DONE
  logic [4:0] fsm_seen = '0;          // visited-state bitmap
  wire [2:0]  dut_state = dut.avstate;  // hierarchical FSM probe
  wire        dut_soe   = dut.sdat_oe;

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

  // FSM coverage: sample DUT state register every clock
  always @(posedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA).
  // rst_obs gates out the t=0 sample (this block can run before the
  // DUT's initial reset settle on the very first posedge).
  logic        p_rstn  = 1;
  logic        rst_obs = 0;
  logic        p_irq   = 0;
  logic [11:0] p_vdac  = 0;
  always @(posedge clk) begin
    if (!rst_n) rst_obs <= 1'b1;
    if (rst_obs) begin
      if (!p_rstn) begin
        // A1: outputs quiescent during reset
        sva_check(busy === 1'b0 && vdac === 12'h000 && irq === 1'b0,
                  "A1 reset: outputs quiescent");
      end else begin
        // A2: irq is a single-cycle pulse (no back-to-back)
        sva_check(!(irq && p_irq), "A2 irq single-cycle pulse");
        // A3: vdac ramp moves at most RAMP_STEP (10) per clock
        sva_check((vdac == p_vdac) ||
                  ((vdac > p_vdac) && (vdac - p_vdac) <= 12'd10) ||
                  ((vdac < p_vdac) && (p_vdac - vdac) <= 12'd10),
                  "A3 vdac ramp step <= 10/clk");
        // A4: slave drives sdat low only in ACK/TX states
        sva_check(!dut_soe || (dut_state == 3'd2) || (dut_state == 3'd3),
                  "A4 sdat drive only in ACK/TX");
        // A5: with both ends released the pulled-up line reads high
        sva_check(dut_soe || mst_oe || (sdat === 1'b1),
                  "A5 released sdat pulled high");
      end
    end
    p_rstn <= rst_n;
    p_irq  <= irq;
    p_vdac <= vdac;
  end
`endif

  // ------------------------- CRC4 (must match DUT) --------------------------
  function automatic logic [3:0] crc4_bit(input logic [3:0] c, input logic b);
    logic fb;
    begin
      fb       = b ^ c[3];
      crc4_bit = {c[2], c[1], c[0] ^ fb, fb};
    end
  endfunction

  function automatic logic [3:0] crc4_31(input logic [30:0] d);
    logic [3:0] c;
    begin
      c = 4'h0;
      for (int i = 30; i >= 0; i--) c = crc4_bit(c, d[i]);
      crc4_31 = c;
    end
  endfunction

  function automatic logic [3:0] crc4_16(input logic [15:0] d);
    logic [3:0] c;
    begin
      c = 4'h0;
      for (int i = 15; i >= 0; i--) c = crc4_bit(c, d[i]);
      crc4_16 = c;
    end
  endfunction

  // ------------------------- bit-level masters ------------------------------
  // one TX bit cell: 140 ns (clk = 10 ns -> comfortable sync margin)
  task automatic avs_tx_bit(input logic b);
    begin
      mst_oe = 1; mst_bit = b;
      #60 sclk = 1;
      #60 sclk = 0;
      #20;
    end
  endtask

  // one RX bit cell: release line, slave drives during low phase, sample high
  task automatic avs_rx_bit(output logic b);
    begin
      mst_oe = 0;
      #60 sclk = 1;
      #20 b = sdat;
      #40 sclk = 0;
      #20;
    end
  endtask

  // ------------------------- frame-level master -----------------------------
  task automatic avs_send(input  logic [6:0]  addr,
                          input  logic [7:0]  cmd,
                          input  logic [15:0] data,
                          input  bit          corrupt_crc,
                          output logic        ack,
                          output logic [15:0] rdata16);
    logic [30:0] payload;
    logic [3:0]  crc, rcrc;
    logic        rb;
    begin
      payload = {addr, cmd, data};
      crc     = crc4_31(payload);
      if (corrupt_crc) crc = crc ^ 4'h1;
      rdata16 = 16'h0000;
      rcrc    = 4'h0;

      avs_tx_bit(1'b1);                            // START
      for (int i = 30; i >= 0; i--) avs_tx_bit(payload[i]);
      for (int i = 3;  i >= 0; i--) avs_tx_bit(crc[i]);
      // ACK slot: master releases, slave drives low for ACK
      avs_rx_bit(rb);
      ack = (rb === 1'b0);
      // GET readback: 16 data bits + 4 CRC bits driven by slave
      if (ack && cmd == CMD_GET) begin
        for (int i = 15; i >= 0; i--) begin avs_rx_bit(rb); rdata16[i] = rb; end
        for (int i = 3;  i >= 0; i--) begin avs_rx_bit(rb); rcrc[i]    = rb; end
        if (rcrc !== crc4_16(rdata16)) begin
          errors++;
          $display("ERROR: AVSBus GET readback CRC mismatch: data=%h crc=%b exp=%b",
                   rdata16, rcrc, crc4_16(rdata16));
        end
      end
      mst_oe = 0;
    end
  endtask

  // ------------------------- helpers ----------------------------------------
  task automatic wait_ramp_done;
    int guard;
    begin
      guard = 0;
      while (busy && guard < 5000) begin
        @(posedge clk);
        guard++;
      end
      if (busy) begin
        errors++;
        $display("ERROR: AVSBus ramp did not complete (busy stuck)");
      end
    end
  endtask

  task automatic set_and_verify(input logic [11:0] code);
    logic        ack;
    logic [15:0] rd;
    begin
      avs_send(SLAVE_ADDR, CMD_SET, {4'h0, code}, 0, ack, rd);
      if (ack !== 1'b1) begin
        errors++;
        $display("ERROR: AVSBus SET %0d not ACKed", code);
      end
      // ramp observation: busy must be high right after the SET is accepted
      @(posedge clk);
      if (busy !== 1'b1) begin
        errors++;
        $display("ERROR: AVSBus busy not asserted during ramp to %0d", code);
      end
      wait_ramp_done();
      if (vdac !== code) begin
        errors++;
        $display("ERROR: AVSBus vdac=%0d exp=%0d after ramp", vdac, code);
      end
      // GET readback compare
      avs_send(SLAVE_ADDR, CMD_GET, 16'h0000, 0, ack, rd);
      if (ack !== 1'b1) begin
        errors++;
        $display("ERROR: AVSBus GET not ACKed");
      end
      if (rd !== {4'h0, code}) begin
        errors++;
        $display("ERROR: AVSBus GET readback=%0d exp=%0d", rd, code);
      end
    end
  endtask

  logic        ack;
  logic [15:0] rd;

  initial begin
    // ---------------- 1. reset state check ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    if (busy !== 1'b0 || vdac !== 12'h000 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: AVSBus reset state busy=%b vdac=%h irq=%b", busy, vdac, irq);
    end
    rst_n = 1; repeat (2) @(posedge clk);
    #100;

    // ---------------- 2. set voltage -> ramp -> get compare (x3) ----------
    set_and_verify(12'd2500);   // large upward ramp
    set_and_verify(12'd700);    // downward ramp
    set_and_verify(12'd1800);   // upward ramp again

    // ---------------- 3. illegal address -> NACK, no irq ------------------
    irq_seen = 0;
    avs_send(7'h12, CMD_SET, 16'h0100, 0, ack, rd);
    if (ack !== 1'b0) begin
      errors++;
      $display("ERROR: AVSBus illegal address was ACKed");
    end
    repeat (4) @(posedge clk);
    if (irq_seen != 0) begin
      errors++;
      $display("ERROR: AVSBus irq raised for foreign address (should be ignored)");
    end

    // ---------------- 4. CRC error -> NACK + irq, voltage unchanged -------
    irq_seen = 0;
    avs_send(SLAVE_ADDR, CMD_SET, {4'h0, 12'd3000}, 1, ack, rd);
    if (ack !== 1'b0) begin
      errors++;
      $display("ERROR: AVSBus corrupted-CRC frame was ACKed");
    end
    repeat (4) @(posedge clk);
    if (irq_seen == 0) begin
      errors++;
      $display("ERROR: AVSBus irq not asserted on CRC error");
    end
    if (busy !== 1'b0 || vdac !== 12'd1800) begin
      errors++;
      $display("ERROR: AVSBus voltage changed after NACKed SET: vdac=%0d busy=%b", vdac, busy);
    end

    // ---------------- 5. unknown command -> NACK + irq ---------------------
    irq_seen = 0;
    avs_send(SLAVE_ADDR, 8'h7F, 16'h0000, 0, ack, rd);
    if (ack !== 1'b0) begin
      errors++;
      $display("ERROR: AVSBus unknown command was ACKed");
    end
    repeat (4) @(posedge clk);
    if (irq_seen == 0) begin
      errors++;
      $display("ERROR: AVSBus irq not asserted on unknown command");
    end

    // ---------------- 6. final readback confirms state intact -------------
    avs_send(SLAVE_ADDR, CMD_GET, 16'h0000, 0, ack, rd);
    if (ack !== 1'b1 || rd !== 16'd1800) begin
      errors++;
      $display("ERROR: AVSBus final GET ack=%b data=%0d exp=1800", ack, rd);
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 140 randomized frames across 5 classes: valid SET (random 12-bit
    // code, ramp observed + GET readback compare), valid GET (readback
    // vs scoreboard), illegal address (NACK, no irq), corrupted CRC
    // (NACK + irq, voltage untouched), unknown command (NACK + irq).
    begin : crv_phase
      int n_set = 0, n_get = 0, n_nack = 0;
      int roll, irq0;
      logic [11:0] model_code;
      logic [11:0] c_code;
      logic [6:0]  c_addr;
      logic [7:0]  c_cmd;
      model_code = 12'd1800;   // scoreboard: last accepted SET (directed)
      for (int t = 0; t < 140; t++) begin
        roll = $urandom_range(0, 19);
        if (roll < 8) begin
          // ---- valid SET: random code -------------------------------
          c_code = 12'($urandom_range(0, 4095));
          avs_send(SLAVE_ADDR, CMD_SET, {4'h0, c_code}, 0, ack, rd);
          if (ack !== 1'b1) begin
            errors++;
            $display("ERROR: CRV SET %0d not ACKed", c_code);
          end
          model_code = c_code;
          wait_ramp_done();
          if (vdac !== c_code) begin
            errors++;
            $display("ERROR: CRV SET vdac=%0d exp=%0d after ramp", vdac, c_code);
          end
          n_set++;
        end else if (roll < 12) begin
          // ---- valid GET: readback vs scoreboard --------------------
          avs_send(SLAVE_ADDR, CMD_GET, 16'h0000, 0, ack, rd);
          if (ack !== 1'b1 || rd !== {4'h0, model_code}) begin
            errors++;
            $display("ERROR: CRV GET ack=%b data=%0d exp=%0d",
                     ack, rd, model_code);
          end
          n_get++;
        end else if (roll < 15) begin
          // ---- illegal address: NACK, no irq ------------------------
          c_addr = 7'($urandom_range(0, 127));
          if (c_addr == SLAVE_ADDR) c_addr = c_addr ^ 7'h01;  // rejection
          irq0 = irq_seen;
          avs_send(c_addr, CMD_SET, {4'h0, 12'($urandom_range(0, 4095))},
                   0, ack, rd);
          if (ack !== 1'b0) begin
            errors++;
            $display("ERROR: CRV illegal addr %h was ACKed", c_addr);
          end
          repeat (4) @(posedge clk);
          if (irq_seen != irq0) begin
            errors++;
            $display("ERROR: CRV irq raised for foreign address");
          end
          n_nack++;
        end else if (roll < 18) begin
          // ---- corrupted CRC: NACK + irq, voltage unchanged ---------
          irq0 = irq_seen;
          avs_send(SLAVE_ADDR, CMD_SET, {4'h0, 12'($urandom_range(0, 4095))},
                   1, ack, rd);
          if (ack !== 1'b0) begin
            errors++;
            $display("ERROR: CRV corrupted-CRC frame was ACKed");
          end
          repeat (4) @(posedge clk);
          if (irq_seen == irq0) begin
            errors++;
            $display("ERROR: CRV irq not asserted on CRC error");
          end
          if (busy !== 1'b0 || vdac !== model_code) begin
            errors++;
            $display("ERROR: CRV voltage changed after NACKed SET");
          end
          n_nack++;
        end else begin
          // ---- unknown command: NACK + irq --------------------------
          c_cmd = 8'($urandom_range(0, 255));
          if (c_cmd == CMD_SET || c_cmd == CMD_GET)
            c_cmd = c_cmd ^ 8'h80;   // rejection: 0x81/0x82 are unknown
          irq0 = irq_seen;
          avs_send(SLAVE_ADDR, c_cmd, 16'h0000, 0, ack, rd);
          if (ack !== 1'b0) begin
            errors++;
            $display("ERROR: CRV unknown cmd %h was ACKed", c_cmd);
          end
          repeat (4) @(posedge clk);
          if (irq_seen == irq0) begin
            errors++;
            $display("ERROR: CRV irq not asserted on unknown command");
          end
          n_nack++;
        end
      end
      $display("CRV: 140 frames (set=%0d get=%0d nack=%0d)",
               n_set, n_get, n_nack);
    end
`endif
    if (errors == 0) $display("TEST PASSED: AVSBus__Adaptive_Voltage_Scaling_");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < AVS_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, AVS_FSM_TOTAL);
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
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (4000) #1000;   // 4 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #2000000;
    $display("TIMEOUT");
    $finish;
  end
`endif
endmodule
