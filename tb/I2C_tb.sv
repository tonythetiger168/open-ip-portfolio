// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as I2C master (bit-bang) -- SystemVerilog
`timescale 1ns/1ps
module I2C_tb;
  logic clk = 0, rst_n = 0;
  tri1 sda;                      // open-drain bus with pullup
  logic scl = 1;
  logic master_low = 0;          // open-drain: TB pulls low or releases
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  I2C_top #(.I2C_ADDR(7'h50)) dut (
    .clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sda = master_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic i2c_start;
    begin
      master_low = 0; scl = 1; #300;
      master_low = 1;        #300;   // SDA falls while SCL high
      scl = 0;               #300;
    end
  endtask

  task automatic i2c_stop;
    begin
      master_low = 1;        #300;
      scl = 1;               #300;
      master_low = 0;        #300;   // SDA rises while SCL high
      #300;
    end
  endtask

  task automatic i2c_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 0; i < 8; i++) begin
        master_low = ~d[7-i];  #300;
        scl = 1;               #600;
        scl = 0;               #300;
      end
      master_low = 0;          #300;   // release for ACK
      scl = 1;                 #300;
      ack = (sda === 1'b0);
      #300; scl = 0;           #600;
    end
  endtask

  task automatic i2c_rbyte(input logic send_ack, output logic [7:0] d);
    begin
      master_low = 0;
      for (int i = 0; i < 8; i++) begin
        #300; scl = 1; #300;
        d[7-i] = sda;
        #300; scl = 0; #300;
      end
      master_low = send_ack;   #300;   // ACK = pull low
      scl = 1;                 #600;
      scl = 0;                 #300;
      master_low = 0;          #300;
    end
  endtask

  // ---- full read transaction with data check (MSB=0 vectors catch
  //      first-byte MSB loss at the ST_ACK->ST_TX transition) ----
  task automatic i2c_read_check(input logic [7:0] v);
    logic ack_t;
    logic [7:0] rd;
    begin
      tx_byte = v;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C no ACK on addr R (v=%h)", v); end
      i2c_rbyte(1'b0, rd);                   // NACK after byte
      if (rd !== v) begin errors++; $display("ERROR: I2C read got=%h exp=%h", rd, v); end
      i2c_stop;
      #300;
    end
  endtask

  // ---- multi-byte read coverage: exercises the ST_TXACK->ST_TX re-entry
  //      path (DUT resends tx_byte after a master ACK) ----
  // txn1: classic single-byte read terminated by a master NACK
  // txn2: master ACKs byte1, DUT walks ST_TXACK->ST_TX and resends tx_byte;
  //       byte2 must equal byte1 (tx_byte is fixed), then master NACKs
  task automatic i2c_read2_check(input logic [7:0] v1, input logic [7:0] v2);
    logic ack_t;
    logic [7:0] rd1, rd2;
    begin
      // txn1: single byte read terminated by master NACK
      tx_byte = v1;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C read2 no ACK on addr R (v=%h)", v1); end
      i2c_rbyte(1'b0, rd1);                  // NACK after byte
      if (rd1 !== v1) begin errors++; $display("ERROR: I2C read2 byte1 got=%h exp=%h", rd1, v1); end
      i2c_stop;
      #300;

      // txn2: master ACKs byte1 -> DUT re-enters ST_TX and resends tx_byte
      tx_byte = v2;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C read2 no ACK on addr R (v=%h)", v2); end
      i2c_rbyte(1'b1, rd1);                  // ACK byte1: request another byte
      if (rd1 !== v2) begin errors++; $display("ERROR: I2C read2 byte1 got=%h exp=%h", rd1, v2); end
      i2c_rbyte(1'b0, rd2);                  // NACK after byte2
      if (rd2 !== v2) begin errors++; $display("ERROR: I2C read2 byte2 got=%h exp=%h", rd2, v2); end
      i2c_stop;
      #300;
    end
  endtask

  // ---- 3-byte read in a single transaction (ACK, ACK, NACK) ----
  //      byte2/byte3 must match byte1: tx_byte is fixed and resent each time
  task automatic i2c_read3_check(input logic [7:0] v);
    logic ack_t;
    logic [7:0] rd1, rd2, rd3;
    begin
      tx_byte = v;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C read3 no ACK on addr R (v=%h)", v); end
      i2c_rbyte(1'b1, rd1);                  // ACK byte1
      if (rd1 !== v) begin errors++; $display("ERROR: I2C read3 byte1 got=%h exp=%h", rd1, v); end
      i2c_rbyte(1'b1, rd2);                  // ACK byte2
      if (rd2 !== v) begin errors++; $display("ERROR: I2C read3 byte2 got=%h exp=%h", rd2, v); end
      i2c_rbyte(1'b0, rd3);                  // NACK byte3: end of transaction
      if (rd3 !== v) begin errors++; $display("ERROR: I2C read3 byte3 got=%h exp=%h", rd3, v); end
      i2c_stop;
      #300;
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
  localparam int I2C_FSM_TOTAL = 7;  // ST_IDLE..ST_IGNORE (rtl enum)
  logic [7:0] fsm_seen = '0;         // visited-state bitmap
  wire  [2:0] dut_state = dut.state; // hierarchical FSM probe
  wire        dut_sdalo = dut.ack_low;

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

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic [7:0] rx_byte_q = '0;
  logic       rx_valid_q = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(busy === 1'b0 && rx_valid === 1'b0 && dut_sdalo === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: state register holds a legal enum encoding
      sva_check(dut_state <= 3'd6, "A2 state encoding legal");
      // A3: busy low in IDLE (no transaction in progress)
      sva_check((dut_state != 3'd0) || (busy === 1'b0), "A3 busy low in IDLE");
      // A4: DUT pulls SDA low only in ACK/TX/TXACK phases
      sva_check(!dut_sdalo || (dut_state == 3'd2) || (dut_state == 3'd4) ||
                (dut_state == 3'd5), "A4 SDA drive only in ack/tx states");
      // A5: rx_valid is a single-cycle pulse
      sva_check(!(rx_valid && rx_valid_q), "A5 rx_valid single-cycle pulse");
      // A6: rx_byte changes only on the cycle rx_valid is high
      sva_check((rx_byte === rx_byte_q) || rx_valid, "A6 rx_byte stable");
      // A7: rx_valid only mid-transaction (byte completes under busy)
      sva_check(!rx_valid || busy, "A7 rx_valid implies busy");
    end
    rx_byte_q  <= rx_byte;
    rx_valid_q <= rx_valid;
  end

  // ---- constrained-random phase -------------------------------------
  // 200 randomized transactions: ~40% write (read back rx_byte), ~40%
  // read (must return tx_byte; random data covers MSB=0/1), ~20% wrong
  // address (slave must NACK and stay idle).
  // v2.5 note (Verilator 5.006 workaround): the random phase is FULLY
  // INLINED in the initial block via the macros below -- NO timing tasks.
  // Each suspendable task call spawns a chained child coroutine, and
  // after ~2k chained awaits 5.006's timing scheduler silently drops the
  // TB coroutine (observed: parked forever inside a pure #delay task at
  // txn #45, deterministic across rebuilds). Single-coroutine awaits
  // (e.g. the clk generator) survive 8M+ suspends, so keeping this
  // initial block as ONE coroutine with only plain #awaits dodges the
  // bug. Directed tests above keep using the tasks (shorter runs, and
  // their chain depth 2-3 has not triggered the bug in ~250us).
  `define I2C_M_START \
    master_low = 0; scl = 1; #300; \
    master_low = 1;        #300; \
    scl = 0;               #300;
  `define I2C_M_STOP \
    master_low = 1;        #300; \
    scl = 1;               #300; \
    master_low = 0;        #300; \
    #300;
  `define I2C_M_WBYTE(d) \
    for (int i = 0; i < 8; i++) begin \
      master_low = ~(d[7-i]); #300; \
      scl = 1;                #600; \
      scl = 0;                #300; \
    end \
    master_low = 0;           #300; \
    scl = 1;                  #300; \
    ack_c = (sda === 1'b0); \
    #300; scl = 0;            #600;
  `define I2C_M_RBYTE(d, send_ack) \
    master_low = 0; \
    for (int i = 0; i < 8; i++) begin \
      #300; scl = 1; #300; \
      d[7-i] = sda; \
      #300; scl = 0; #300; \
    end \
    master_low = (send_ack);  #300; \
    scl = 1;                  #600; \
    scl = 0;                  #300; \
    master_low = 0;           #300;
`endif

  logic ack, rdata;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'hC3;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    // ---- write 0x5A to slave ----
    i2c_start;
    i2c_wbyte(8'hA0, ack);                 // addr 0x50 + W
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on addr W"); end
    i2c_wbyte(8'h5A, ack);
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on data"); end
    i2c_stop;
    repeat(10) @(posedge clk);
    if (!rx_seen)  begin errors++; $display("ERROR: I2C rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: I2C rx_byte=%h exp=5A", rx_byte); end

    // ---- read back (tx_byte) ----
    i2c_start;
    i2c_wbyte(8'hA1, ack);                 // addr 0x50 + R
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on addr R"); end
    i2c_rbyte(1'b0, rb);                   // NACK after byte
    if (rb !== 8'hC3) begin errors++; $display("ERROR: I2C read got=%h exp=C3", rb); end
    i2c_stop;

    // ---- MSB=0 read vectors (first-byte MSB must not be lost) ----
    i2c_read_check(8'h73);
    i2c_read_check(8'h00);
    i2c_read_check(8'h7F);

    // ---- multi-byte reads: ST_TXACK->ST_TX re-entry coverage ----
    i2c_read2_check(8'hC3, 8'h73);
    i2c_read2_check(8'h00, 8'hFF);
    i2c_read3_check(8'hA5);

    // ---- wrong address must NACK ----
    i2c_start;
    i2c_wbyte(8'hA2, ack);                 // addr 0x51: not us
    if (ack) begin errors++; $display("ERROR: I2C wrong addr ACKed"); end
    i2c_stop;

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // fully inlined via macros (no timing-task coroutine chains): see the
    // note above the macros for the Verilator 5.006 scheduler-bug rationale
    begin : crv_phase
      int n_wr = 0, n_rd = 0, n_wa = 0;
      int roll;
      logic [7:0] v;
      logic [7:0] rd_c;
      logic [7:0] wa_byte;
      logic [7:0] dat_c;   // WBYTE macro arg must be a variable (no literal[bit-select])
      logic [6:0] wa;
      logic       wa_rw;
      logic       ack_c;
      for (int t = 0; t < 200; t++) begin
        roll = $urandom_range(0, 9);
        v    = $urandom_range(0, 255);
        if (roll < 4) begin
          // random write: addr + one data byte, then compare rx_byte
          n_wr++;
          `I2C_M_START
          dat_c = 8'hA0;
          `I2C_M_WBYTE(dat_c)                    // addr 0x50 + W
          if (!ack_c) begin errors++; $display("ERROR: CRV no ACK on addr W"); end
          dat_c = v;
          `I2C_M_WBYTE(dat_c)
          if (!ack_c) begin errors++; $display("ERROR: CRV no ACK on data %h", v); end
          `I2C_M_STOP
          #120;                                  // settle
          if (rx_byte !== v) begin
            errors++; $display("ERROR: CRV rx_byte=%h exp=%h", rx_byte, v);
          end
        end else if (roll < 8) begin
          // random read: DUT must return tx_byte (self-checked inline)
          n_rd++;
          tx_byte = v;
          `I2C_M_START
          dat_c = 8'hA1;
          `I2C_M_WBYTE(dat_c)                    // addr 0x50 + R
          if (!ack_c) begin errors++; $display("ERROR: CRV no ACK on addr R"); end
          `I2C_M_RBYTE(rd_c, 1'b0)               // NACK after byte
          if (rd_c !== v) begin
            errors++; $display("ERROR: CRV read got=%h exp=%h", rd_c, v);
          end
          `I2C_M_STOP
        end else begin
          // wrong address: rejection-sample away our own address
          n_wa++;
          wa    = $urandom_range(0, 127);
          if (wa == 7'h50) wa = 7'h51;
          wa_rw = $urandom_range(0, 1);
          wa_byte = {wa, wa_rw};
          `I2C_M_START
          `I2C_M_WBYTE(wa_byte)
          if (ack_c) begin
            errors++; $display("ERROR: CRV wrong addr %h ACKed", wa);
          end
          `I2C_M_STOP
          #40;                                   // settle
          if (busy) begin
            errors++; $display("ERROR: CRV busy stuck after wrong-addr stop");
          end
        end
      end
      $display("CRV: 200 txns (wr=%0d rd=%0d wrong_addr=%0d)", n_wr, n_rd, n_wa);
    end
  `undef I2C_M_START
  `undef I2C_M_STOP
  `undef I2C_M_WBYTE
  `undef I2C_M_RBYTE
`endif

    if (errors == 0) $display("TEST PASSED: I2C");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < I2C_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, I2C_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Random phase adds ~5 ms of bus traffic: extend the guard.
  // The timeout is chunked into 1-us delays: with Verilator 5.006 a single
  // long-pending #delay event corrupts the --timing delay heap once many
  // short-delay resumptions interleave with it (processes lose wakeups and
  // the long event fires early). Chunked delays keep all heap entries
  // short-lived and avoid the corruption (verified with a minimal repro).
  initial begin
    repeat (40000) #1000;   // 40 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
