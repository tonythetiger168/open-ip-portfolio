// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_SPMI_top -- SPMI master model
// Checks:
//   1. reset state: SDATA released, irq=0
//   2. register 0 write/read compare x2 (cmd 0x0 / 0x2)
//   3. extended register write BC=3 (cmd 0x3) + extended read BC=3 (cmd 0x8)
//   4. error injection: bad data parity -> write dropped + irq, reg unchanged
//   5. error injection: illegal command -> NACK (no response) + irq
//   6. A-bit arbitration: read with A=1 -> slave yields (silent), then
//      normal read with A=0 works again
//   7. error injection: unknown USID -> no response + irq
//   8. back-to-back consecutive transactions
// The SDATA bus is modelled as tri1 (pull-up); the master parks it low when
// idle and releases it only while the slave drives read data.
`timescale 1ns/1ps
module MIPI_SPMI_tb;

  localparam int HALF = 50;              // half SCLK period (ns, 5 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_sclk = 0;
  tri1  sdata;
  logic m_oe = 1, m_val = 0;             // master park-low driver
  assign sdata = m_oe ? m_val : 1'bz;

  logic irq;
  int errors = 0;

  localparam logic [3:0] USID = 4'h5;

  MIPI_SPMI_top #(.USID(USID)) dut (
    .clk(clk), .rst_n(rst_n),
    .sclk(m_sclk), .sdata(sdata),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_bit(input logic b);   // one bit, full SCLK cycle
    begin
      m_sclk = 0; #1;
      m_oe   = 1; m_val = b;  #HALF;
      m_sclk = 1;             #HALF;
      m_sclk = 0;             #HALF;
    end
  endtask

  task automatic m_ssc;                  // long SDATA-high pulse while SCLK low
    begin
      m_sclk = 0; #1;
      m_oe   = 1; m_val = 1;  #(8*HALF);
    end
  endtask

  task automatic m_park;                 // bus-park cycle + park low
    begin
      m_bit(1'b0);                       // BP: SDATA low for one SCLK cycle
      m_oe = 1; m_val = 0; m_sclk = 0;  #(2*HALF);
    end
  endtask

  // 12-bit command frame {SA,C,A} + A-bit
  task automatic m_cmd(input logic [3:0] sa, input logic [3:0] c,
                       input logic [3:0] a, input logic abit);
    logic [11:0] f;
    begin
      f = {sa, c, a};
      for (int i = 11; i >= 0; i--) m_bit(f[i]);
      m_bit(abit);
    end
  endtask

  // 9-bit data frame {D,P} (even parity), optionally with wrong parity
  task automatic m_dframe(input logic [7:0] d, input logic bad_par);
    logic [8:0] f;
    begin
      f = {d, (^d) ^ bad_par};
      for (int i = 8; i >= 0; i--) m_bit(f[i]);
    end
  endtask

  // read n 9-bit data frames from the slave into rbuf
  logic [8:0] rbuf [0:7];
  task automatic m_rframes(input int n);
    begin
      m_oe = 1'b0;                       // turnaround: slave drives
      for (int k = 0; k < n; k++) begin
        for (int i = 8; i >= 0; i--) begin
          m_sclk = 0;           #HALF;
          m_sclk = 1;           #(HALF/2);
          rbuf[k][i] = sdata;   #(HALF/2);
          m_sclk = 0;           #HALF;
        end
      end
      m_oe = 1; m_val = 0;
    end
  endtask

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
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
  localparam int MSPMI_FSM_TOTAL = 8; // S_IDLE..S_PARK (rtl enum)
  logic [7:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.state;  // hierarchical FSM probe
  wire        dut_drv   = dut.drv_en;

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
  logic       err_q = 0;
  logic [2:0] state_q = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(irq === 1'b0 && dut_drv === 1'b0 && dut_state == 3'd0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: bit counter never exceeds the longest frame (12-bit cmd)
      sva_check(dut.bcnt <= 4'd11, "A2 bcnt within frame length");
      // A3: slave drives SDATA only while sending read data
      sva_check(!dut_drv || (dut_state == 3'd6), "A3 drive only in RDATA");
      // A4: when the slave drives, the bus is never floating
      sva_check(!dut_drv || (sdata !== 1'bz), "A4 driven bus not floating");
      // A5: irq mirrors the sticky error flag
      sva_check(irq === dut.err_sticky, "A5 irq mirrors err_sticky");
      // A6: irq is sticky within a transaction (clears only via SSC;
      // state_q tracks the pre-NBA state of the cycle that did the clear)
      sva_check(!(err_q && !dut.err_sticky) || (state_q == 3'd0),
                "A6 irq clears only via SSC in IDLE");
      // A7: SSC counter saturates at 6'h3F
      sva_check(dut.ssc_cnt <= 6'h3F, "A7 ssc_cnt saturated");
    end
    err_q   <= dut.err_sticky;
    state_q <= dut_state;
  end

  // ---- inlined bit-level macros for the random phase ------------------
  // (same Verilator 5.006 scheduler rationale as the I2C pilot: chained
  // timing-task coroutines can lose wakeups after ~2k awaits, so the
  // random phase runs as ONE coroutine with plain #awaits only)
  `define MSPMI_M_BIT(b) \
    m_sclk = 0; #1; \
    m_oe = 1; m_val = (b); #HALF; \
    m_sclk = 1;            #HALF; \
    m_sclk = 0;            #HALF;
  `define MSPMI_M_SSC \
    m_sclk = 0; #1; \
    m_oe = 1; m_val = 1; #(8*HALF);
  `define MSPMI_M_PARK \
    m_sclk = 0; #1; \
    m_oe = 1; m_val = 0; #HALF; \
    m_sclk = 1;            #HALF; \
    m_sclk = 0;            #HALF; \
    m_oe = 1; m_val = 0; m_sclk = 0; #(2*HALF);
  // read one slave-driven bit (post-turnaround), sampled HALF/2 after rise
  `define MSPMI_M_RBIT(b) \
    m_sclk = 0;  #HALF; \
    m_sclk = 1;  #(HALF/2); \
    b = sdata;   #(HALF/2); \
    m_sclk = 0;  #HALF;
`endif

  // ---------------------------------------------------------------
  // compound transactions
  // ---------------------------------------------------------------
  task automatic spmi_r0_write(input logic [7:0] d, input logic bad_par);
    begin
      m_ssc;
      m_cmd(USID, 4'h0, 4'h0, 1'b1);     // write: master keeps bus (A=1)
      m_dframe(d, bad_par);
      m_park;
    end
  endtask

  task automatic spmi_r0_read(input logic [7:0] exp);
    begin
      m_ssc;
      m_cmd(USID, 4'h2, 4'h0, 1'b0);     // read: grant bus to slave (A=0)
      m_rframes(1);
      m_park;
      if (rbuf[0][8:1] !== exp) begin
        errors++;
        $display("ERROR: reg0 read got=%02x exp=%02x", rbuf[0][8:1], exp);
      end
      check(rbuf[0][0] === (^rbuf[0][8:1]), "reg0 read: bad parity from slave");
    end
  endtask

  // ---------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------

  initial begin
    rst_n = 0; repeat (6) @(posedge clk);
    rst_n = 1; repeat (4) @(posedge clk);

    // -- check 1: reset / idle state ------------------------------
    check(irq === 1'b0, "irq asserted after reset");
    m_park;

    // -- check 2: register 0 write/read compare x2 ----------------
    spmi_r0_write(8'hA5, 1'b0);
    spmi_r0_read (8'hA5);
    spmi_r0_write(8'h5C, 1'b0);
    spmi_r0_read (8'h5C);
    check(irq === 1'b0, "irq set during valid traffic");

    // -- check 3: extended write BC=3 + extended read BC=3 --------
    m_ssc;
    m_cmd(USID, 4'h3, 4'd3, 1'b1);       // EXT write, BC=3, A=1
    m_dframe(8'h05, 1'b0);               // start address = 5
    m_dframe(8'h11, 1'b0);
    m_dframe(8'h22, 1'b0);
    m_dframe(8'h33, 1'b0);
    m_park;
    m_ssc;
    m_cmd(USID, 4'h8, 4'd3, 1'b0);       // EXT read, BC=3, A=0
    m_dframe(8'h05, 1'b0);               // start address = 5
    m_rframes(3);
    m_park;
    if (rbuf[0][8:1] !== 8'h11 || rbuf[1][8:1] !== 8'h22 || rbuf[2][8:1] !== 8'h33) begin
      errors++;
      $display("ERROR: ext read got=%02x %02x %02x exp=11 22 33",
               rbuf[0][8:1], rbuf[1][8:1], rbuf[2][8:1]);
    end
    check(rbuf[0][0] === (^rbuf[0][8:1]) && rbuf[1][0] === (^rbuf[1][8:1]) &&
          rbuf[2][0] === (^rbuf[2][8:1]), "ext read: bad parity from slave");

    // -- check 4: bad data parity -> write dropped + irq ----------
    spmi_r0_write(8'h77, 1'b0);          // known good value
    check(irq === 1'b0, "irq set after good write");
    spmi_r0_write(8'hAA, 1'b1);          // bad parity: must be dropped
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "bad data parity: irq not raised");
    spmi_r0_read (8'h77);                // old value retained, clears irq
    repeat (4) @(posedge clk);
    check(irq === 1'b0, "irq not cleared by next SSC");

    // -- check 5: illegal command -> NACK (no response) + irq -----
    m_ssc;
    m_cmd(USID, 4'h5, 4'h0, 1'b0);       // illegal command, read-style
    m_rframes(1);                        // slave must stay silent
    m_park;
    check(rbuf[0] === 9'h1FF, "illegal cmd: slave responded");
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "illegal cmd: irq not raised");

    // -- check 6: A-bit arbitration -- read with A=1 -> yield -----
    m_ssc;
    m_cmd(USID, 4'h2, 4'h0, 1'b1);       // read but master keeps bus
    m_rframes(1);                        // slave must yield (silent)
    m_park;
    check(rbuf[0] === 9'h1FF, "A-bit: slave did not yield to master");
    spmi_r0_read(8'h77);                 // normal read (A=0) still works

    // -- check 7: unknown USID -> no response + irq ---------------
    m_ssc;
    m_cmd(4'h9, 4'h2, 4'h0, 1'b0);       // foreign USID read
    m_rframes(1);
    m_park;
    check(rbuf[0] === 9'h1FF, "unknown USID: slave responded");
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "unknown USID: irq not raised");

    // -- check 8: back-to-back consecutive transactions -----------
    spmi_r0_write(8'hC3, 1'b0);
    spmi_r0_read (8'hC3);
    spmi_r0_write(8'h3C, 1'b0);
    spmi_r0_read (8'h3C);
    check(irq === 1'b0, "irq set at end of test");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized transactions. Classes: reg0 write + read-back,
    // extended write + extended read-back of every byte, write with A=0
    // (slave must not accept), read with A=1 (slave yields), bad data
    // parity, illegal command, unknown USID, illegal byte count, bad
    // extended-address parity, bad parity on a middle extended data
    // frame. irq checked after every frame (sticky until the next SSC).
    // Scoreboard model mirrors the 16-deep register file including the
    // directed-test contents. Fully inlined via the macros above.
    begin : crv_phase
      int n_rw = 0, n_xw = 0, n_a0 = 0, n_a1 = 0, n_ed = 0, n_ei = 0;
      int n_eu = 0, n_eb = 0, n_ea = 0, n_ex = 0;
      int roll, bc_c, xstart;
      int eroll = 0;                 // round-robin over error classes
      logic [3:0] sa_c, cmd_c;
      logic [7:0] v, model [0:15];
      logic [8:0] df;
      logic [11:0] cf;
      logic bb;
      // scoreboard sync with the directed tests above
      for (int i = 0; i < 16; i++) model[i] = 8'h00;
      model[0] = 8'h3C; model[5] = 8'h11; model[6] = 8'h22; model[7] = 8'h33;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 19);
        v = (roll == 0) ? 8'h00 : (roll == 1) ? 8'hFF
                                              : 8'($urandom_range(0, 255));
        roll = $urandom_range(0, 29);
        if (roll < 9) begin
          // ---- register 0 write + read-back compare ----
          n_rw++;
          model[0] = v;
          `MSPMI_M_SSC
          cf = {USID, 4'h0, 4'h0};
          for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
          `MSPMI_M_BIT(1'b1)                          // A=1: master keeps bus
          df = {v, ^v};
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
          `MSPMI_M_PARK
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during valid write");
          end
          // read back
          `MSPMI_M_SSC
          cf = {USID, 4'h2, 4'h0};
          for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
          `MSPMI_M_BIT(1'b0)                          // A=0: grant to slave
          m_oe = 1'b0;
          for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
          m_oe = 1; m_val = 0;
          `MSPMI_M_PARK
          if (df[8:1] !== v) begin
            errors++; $display("ERROR: CRV reg0 readback got=%h exp=%h", df[8:1], v);
          end
          if (df[0] !== (^df[8:1])) begin
            errors++; $display("ERROR: CRV reg0 readback bad slave parity");
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during valid read");
          end
        end else if (roll < 13) begin
          // ---- extended write BC=1..8 + extended read-back ----
          n_xw++;
          bc_c   = 1 + $urandom_range(0, 7);
          xstart = $urandom_range(0, 15);
          `MSPMI_M_SSC
          cf = {USID, 4'h3, 4'(bc_c)};
          for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
          `MSPMI_M_BIT(1'b1)
          df = {8'(xstart), ^8'(xstart)};             // address frame
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
          for (int k = 0; k < bc_c; k++) begin
            v = 8'($urandom_range(0, 255));
            model[4'(xstart + k)] = v;                // 4-bit wrap, mirrors RTL
            df = {v, ^v};
            for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
          end
          `MSPMI_M_PARK
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set after ext write");
          end
          // extended read-back of every written byte
          `MSPMI_M_SSC
          cf = {USID, 4'h8, 4'(bc_c)};
          for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
          `MSPMI_M_BIT(1'b0)
          df = {8'(xstart), ^8'(xstart)};
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
          m_oe = 1'b0;
          for (int k = 0; k < bc_c; k++) begin
            for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
            if (df[8:1] !== model[4'(xstart + k)]) begin
              errors++; $display("ERROR: CRV xreadback @%h got=%h exp=%h",
                                 4'(xstart + k), df[8:1], model[4'(xstart + k)]);
            end
            if (df[0] !== (^df[8:1])) begin
              errors++; $display("ERROR: CRV xreadback bad slave parity byte %0d", k);
            end
          end
          m_oe = 1; m_val = 0;
          `MSPMI_M_PARK
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set after ext read");
          end
        end else begin
          // ---- error-injection / arbitration classes ----
          // round-robin selector (not pure random) so every class is
          // guaranteed to run; all class parameters stay randomized
          case (eroll)
            0: begin
              // write with A=0: slave must not accept (no write, no irq)
              n_a0++;
              `MSPMI_M_SSC
              cf = {USID, 4'h0, 4'h0};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)                      // A=0: bus NOT kept
              df = {v, ^v};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV A=0 write raised irq");
              end
              // reg0 must still hold the model value
              `MSPMI_M_SSC
              cf = {USID, 4'h2, 4'h0};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
              if (df[8:1] !== model[0]) begin
                errors++; $display("ERROR: CRV A=0 write changed reg0");
              end
            end
            1: begin
              // read with A=1: slave yields (silent), no irq; randomly
              // reg0 read or extended read (both must yield)
              n_a1++;
              cmd_c = ($urandom_range(0, 1)) ? 4'h2 : 4'h8;
              `MSPMI_M_SSC
              cf = {USID, cmd_c, 4'h1};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b1)                      // master keeps bus
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
              if (df !== 9'h1FF) begin
                errors++; $display("ERROR: CRV A=1 read: slave did not yield");
              end
              repeat (4) @(posedge clk);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV A=1 read raised irq");
              end
            end
            2: begin
              // bad data parity on reg0 write: dropped + irq, reg unchanged
              n_ed++;
              `MSPMI_M_SSC
              cf = {USID, 4'h0, 4'h0};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b1)
              df = {v, ~(^v)};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad data parity: irq not raised");
              end
              `MSPMI_M_SSC
              cf = {USID, 4'h2, 4'h0};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
              if (df[8:1] !== model[0]) begin
                errors++; $display("ERROR: CRV dropped write changed reg0");
              end
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared by next SSC");
              end
            end
            3: begin
              // illegal command: NACK (silent) + irq
              n_ei++;
              cmd_c = 4'($urandom_range(0, 15));
              if (cmd_c == 4'h0 || cmd_c == 4'h2 || cmd_c == 4'h3 ||
                  cmd_c == 4'h8) cmd_c = 4'h5;        // rejection sampling
              `MSPMI_M_SSC
              cf = {USID, cmd_c, 4'h0};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
              if (df !== 9'h1FF) begin
                errors++; $display("ERROR: CRV illegal cmd %h: slave responded", cmd_c);
              end
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV illegal cmd %h: irq not raised", cmd_c);
              end
            end
            4: begin
              // unknown USID: NACK (silent) + irq
              n_eu++;
              sa_c = 4'($urandom_range(0, 15));
              if (sa_c == USID) sa_c = sa_c ^ 4'h1;   // rejection sampling
              `MSPMI_M_SSC
              cf = {sa_c, 4'h2, 4'h0};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
              if (df !== 9'h1FF) begin
                errors++; $display("ERROR: CRV slave answered foreign USID %h", sa_c);
              end
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV unknown USID: irq not raised");
              end
            end
            5: begin
              // illegal extended byte count (0 or >8): NACK + irq
              n_eb++;
              bc_c = ($urandom_range(0, 1)) ? 0 : 9 + $urandom_range(0, 6);
              cmd_c = ($urandom_range(0, 1)) ? 4'h3 : 4'h8;
              `MSPMI_M_SSC
              cf = {USID, cmd_c, 4'(bc_c)};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
              if (df !== 9'h1FF) begin
                errors++; $display("ERROR: CRV illegal BC=%0d: slave responded", bc_c);
              end
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV illegal BC=%0d: irq not raised", bc_c);
              end
            end
            6: begin
              // bad extended-address parity: NACK after addr frame + irq
              n_ea++;
              bc_c   = 1 + $urandom_range(0, 7);
              xstart = $urandom_range(0, 15);
              `MSPMI_M_SSC
              cf = {USID, 4'h3, 4'(bc_c)};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b1)
              df = {8'(xstart), ~(^8'(xstart))};      // WRONG addr parity
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              df = {v, ^v};                            // must be ignored
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad xaddr parity: irq not raised");
              end
            end
            default: begin
              // bad parity on a middle ext-write data frame: first byte
              // written, rest dropped + irq
              n_ex++;
              bc_c   = 2 + $urandom_range(0, 6);
              xstart = $urandom_range(0, 15);
              `MSPMI_M_SSC
              cf = {USID, 4'h3, 4'(bc_c)};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b1)
              df = {8'(xstart), ^8'(xstart)};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              v = 8'($urandom_range(0, 255));
              model[4'(xstart)] = v;                   // byte 0: good
              df = {v, ^v};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              df = {8'hA5, ~(^8'hA5)};                 // byte 1: bad parity
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              for (int k = 2; k < bc_c; k++) begin     // ignored remainder
                df = {8'h5A, ^8'h5A};
                for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              end
              `MSPMI_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad xdata parity: irq not raised");
              end
              // extended read-back: byte0 new, byte1 old
              `MSPMI_M_SSC
              cf = {USID, 4'h8, 4'h2};
              for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
              `MSPMI_M_BIT(1'b0)
              df = {8'(xstart), ^8'(xstart)};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
              m_oe = 1'b0;
              for (int k = 0; k < 2; k++) begin
                for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
                if (df[8:1] !== model[4'(xstart + k)]) begin
                  errors++; $display("ERROR: CRV xdrop readback @%h got=%h exp=%h",
                                     4'(xstart + k), df[8:1], model[4'(xstart + k)]);
                end
              end
              m_oe = 1; m_val = 0;
              `MSPMI_M_PARK
            end
          endcase
          eroll = (eroll + 1) % 8;
        end
      end
      // ---- deterministic toggle-closure sweep -------------------------
      // walk the whole register file with 0xFF then 0x00 (ext writes) so
      // every mem bit toggles both ways, then ext read-back of the zeros
      for (int a = 0; a < 16; a += 8) begin
        for (int p = 0; p < 2; p++) begin
          v = p ? 8'h00 : 8'hFF;
          `MSPMI_M_SSC
          cf = {USID, 4'h3, 4'd8};
          for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
          `MSPMI_M_BIT(1'b1)
          df = {8'(a), ^8'(a)};
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
          for (int k = 0; k < 8; k++) begin
            model[a + k] = v;
            df = {v, ^v};
            for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
          end
          `MSPMI_M_PARK
        end
      end
      `MSPMI_M_SSC
      cf = {USID, 4'h8, 4'd8};
      for (int i = 11; i >= 0; i--) begin bb = cf[i]; `MSPMI_M_BIT(bb) end
      `MSPMI_M_BIT(1'b0)
      df = {8'd8, ^8'd8};
      for (int i = 8; i >= 0; i--) begin bb = df[i]; `MSPMI_M_BIT(bb) end
      m_oe = 1'b0;
      for (int k = 0; k < 8; k++) begin
        for (int i = 8; i >= 0; i--) begin `MSPMI_M_RBIT(bb) df[i] = bb; end
        if (df[8:1] !== 8'h00) begin
          errors++; $display("ERROR: CRV sweep readback @%h got=%h exp=00", 8+k, df[8:1]);
        end
      end
      m_oe = 1; m_val = 0;
      `MSPMI_M_PARK
      if (irq !== 1'b0) begin
        errors++; $display("ERROR: CRV irq set at end of sweep");
      end
      $display("CRV: 120 txns + sweep (rw=%0d xw=%0d | a0=%0d a1=%0d badpar=%0d illcmd=%0d usid=%0d badbc=%0d badxa=%0d badxd=%0d)",
               n_rw, n_xw, n_a0, n_a1, n_ed, n_ei, n_eu, n_eb, n_ea, n_ex);
    end
  `undef MSPMI_M_BIT
  `undef MSPMI_M_SSC
  `undef MSPMI_M_PARK
  `undef MSPMI_M_RBIT
`endif

    if (errors == 0) $display("TEST PASSED: MIPI_SPMI");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < MSPMI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, MSPMI_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (30000) #1000;   // 30 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #3000000;
    $display("TIMEOUT");
    $finish;
  end
`endif

endmodule
