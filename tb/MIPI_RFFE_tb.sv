// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_RFFE_top -- RFFE master model
// Checks:
//   1. reset state: SDATA released, irq=0
//   2. register write/read compare x4 (parity checked frames)
//   3. extended register write BC=3 + readback compare of all 3 bytes
//   4. error injection: bad command parity -> frame ignored + irq
//   5. error injection: bad data parity -> write dropped + irq, reg unchanged
//   6. error injection: unknown USID read -> slave silent (reads 1s) + irq
//   7. back-to-back consecutive transactions
// The SDATA bus is modelled as tri1 (pull-up); the master parks it low when
// idle as RFFE requires, and releases it only for the read turnaround.
`timescale 1ns/1ps
module MIPI_RFFE_tb;

  localparam int HALF = 50;              // half SCLK period (ns, 5 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_sclk = 0;
  tri1  sdata;
  logic m_oe = 1, m_val = 0;             // master park-low driver
  assign sdata = m_oe ? m_val : 1'bz;

  logic irq;
  int errors = 0;

  localparam logic [3:0] USID = 4'h5;

  MIPI_RFFE_top #(.USID(USID)) dut (
    .clk(clk), .rst_n(rst_n),
    .sclk(m_sclk), .sdata(sdata),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_bit(input logic b);   // drive one bit, full SCLK cycle
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

  task automatic m_park;                 // park the bus low (idle state)
    begin
      m_oe = 1; m_val = 0; m_sclk = 0;  #(2*HALF);
    end
  endtask

  // send 13-bit command frame {SA,C,A,P}
  task automatic m_cmd(input logic [3:0] sa, input logic [2:0] c,
                       input logic [4:0] a);
    logic [12:0] f;
    begin
      f = {sa, c, a, 1'b0};
      f[0] = ^f[12:1];                   // even parity
      for (int i = 12; i >= 0; i--) m_bit(f[i]);
    end
  endtask

  // send 9-bit data frame {D,P}
  task automatic m_dframe(input logic [7:0] d);
    logic [8:0] f;
    begin
      f = {d, ^d};
      for (int i = 8; i >= 0; i--) m_bit(f[i]);
    end
  endtask

  // read 9-bit data frame from the slave (after BP), returns {D,P}
  task automatic m_rframe(output logic [8:0] f);
    begin
      // BP cycle: master drives low for one SCLK cycle, then releases
      m_bit(1'b0);
      m_oe = 1'b0;                       // turnaround: slave drives
      for (int i = 8; i >= 0; i--) begin
        m_sclk = 0;             #HALF;
        m_sclk = 1;             #(HALF/2);
        f[i] = sdata;           #(HALF/2);
        m_sclk = 0;             #HALF;
      end
      m_oe = 1; m_val = 0;               // park low again
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
  localparam int MRFFE_FSM_TOTAL = 7; // S_IDLE..S_XDATA (rtl enum)
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
  logic err_q = 0;
  logic [2:0] state_q = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(irq === 1'b0 && dut_drv === 1'b0 && dut_state == 3'd0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: state register holds a legal enum encoding
      sva_check(dut_state <= 3'd6, "A2 state encoding legal");
      // A3: slave drives SDATA only while sending read data
      sva_check(!dut_drv || (dut_state == 3'd4), "A3 drive only in RDATA");
      // A4: when the slave drives, the bus is never floating
      sva_check(!dut_drv || (sdata !== 1'bz), "A4 driven bus not floating");
      // A5: irq mirrors the sticky error flag
      sva_check(irq === dut.err_sticky, "A5 irq mirrors err_sticky");
      // A6: bit counter never exceeds the longest frame (13-bit cmd)
      sva_check(dut.bcnt <= 4'd12, "A6 bcnt within frame length");
      // A7: irq is sticky within a transaction (clears only from IDLE;
      // state_q tracks the pre-NBA state of the cycle that did the clear)
      sva_check(!(err_q && !dut.err_sticky) || (state_q == 3'd0),
                "A7 irq clears only via SSC in IDLE");
    end
    err_q   <= dut.err_sticky;
    state_q <= dut_state;
  end

  // ---- inlined bit-level macros for the random phase ------------------
  // (same Verilator 5.006 scheduler rationale as the I2C pilot: chained
  // timing-task coroutines can lose wakeups after ~2k awaits, so the
  // random phase runs as ONE coroutine with plain #awaits only)
  `define MRFFE_M_BIT(b) \
    m_sclk = 0; #1; \
    m_oe = 1; m_val = (b); #HALF; \
    m_sclk = 1;            #HALF; \
    m_sclk = 0;            #HALF;
  `define MRFFE_M_SSC \
    m_sclk = 0; #1; \
    m_oe = 1; m_val = 1; #(8*HALF);
  `define MRFFE_M_PARK \
    m_oe = 1; m_val = 0; m_sclk = 0; #(2*HALF);
  // read one slave-driven bit (post-turnaround), sampled HALF/2 after rise
  `define MRFFE_M_RBIT(b) \
    m_sclk = 0;  #HALF; \
    m_sclk = 1;  #(HALF/2); \
    b = sdata;   #(HALF/2); \
    m_sclk = 0;  #HALF;
`endif

  // ---------------------------------------------------------------
  // compound transactions
  // ---------------------------------------------------------------
  task automatic rffe_write(input logic [3:0] sa, input logic [4:0] a,
                            input logic [7:0] d);
    begin
      m_ssc;
      m_cmd(sa, 3'b010, a);
      m_dframe(d);
      m_park;
    end
  endtask

  task automatic rffe_read(input logic [3:0] sa, input logic [4:0] a,
                           input logic [7:0] exp, input logic expect_drv);
    logic [8:0] f;
    begin
      m_ssc;
      m_cmd(sa, 3'b011, a);
      m_rframe(f);
      m_park;
      if (expect_drv) begin
        if (f[8:1] !== exp) begin
          errors++;
          $display("ERROR: read @%02x got=%02x exp=%02x", a, f[8:1], exp);
        end
        check(f[0] === (^f[8:1]), "read: bad parity from slave");
      end else begin
        check(f === 9'h1FF, "read: slave responded to foreign USID");
      end
    end
  endtask

  // ---------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------
  logic [8:0] f;

  initial begin
    rst_n = 0; repeat (6) @(posedge clk);
    rst_n = 1; repeat (4) @(posedge clk);

    // -- check 1: reset / idle state ------------------------------
    check(irq === 1'b0, "irq asserted after reset");
    m_park;

    // -- check 2: register write/read compare x4 ------------------
    rffe_write(USID, 5'h03, 8'hA5);
    rffe_write(USID, 5'h07, 8'h5C);
    rffe_write(USID, 5'h0A, 8'h3C);
    rffe_write(USID, 5'h0F, 8'hC3);
    rffe_read (USID, 5'h03, 8'hA5, 1'b1);
    rffe_read (USID, 5'h07, 8'h5C, 1'b1);
    rffe_read (USID, 5'h0A, 8'h3C, 1'b1);
    rffe_read (USID, 5'h0F, 8'hC3, 1'b1);
    check(irq === 1'b0, "irq set during valid traffic");

    // -- check 3: extended register write BC=3 + readback ---------
    m_ssc;
    m_cmd(USID, 3'b110, 5'd3);           // BC=3
    m_dframe(8'h04);                     // start address = 4
    m_dframe(8'h11);
    m_dframe(8'h22);
    m_dframe(8'h33);
    m_park;
    rffe_read(USID, 5'h04, 8'h11, 1'b1);
    rffe_read(USID, 5'h05, 8'h22, 1'b1);
    rffe_read(USID, 5'h06, 8'h33, 1'b1);

    // -- check 4: bad command parity -> ignored + irq -------------
    m_ssc;
    begin
      logic [12:0] bf;
      bf = {USID, 3'b010, 5'h09, 1'b0};
      bf[0] = ~(^bf[12:1]);              // WRONG parity on purpose
      for (int i = 12; i >= 0; i--) m_bit(bf[i]);
    end
    m_dframe(8'hEE);                     // must be ignored
    m_park;
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "bad cmd parity: irq not raised");
    rffe_read(USID, 5'h09, 8'h00, 1'b1); // reg 9 never written -> reads 0
    check(irq === 1'b0, "irq not cleared by next SSC");

    // -- check 5: bad data parity -> write dropped + irq ----------
    rffe_write(USID, 5'h02, 8'h55);      // known good value first
    check(irq === 1'b0, "irq set after good write");
    m_ssc;
    m_cmd(USID, 3'b010, 5'h02);
    begin
      logic [8:0] bf;
      bf = {8'hAA, ~(^8'hAA)};           // WRONG data parity on purpose
      for (int i = 8; i >= 0; i--) m_bit(bf[i]);
    end
    m_park;
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "bad data parity: irq not raised");
    rffe_read(USID, 5'h02, 8'h55, 1'b1); // old value retained

    // -- check 6: unknown USID -> no response + irq ---------------
    rffe_read(4'h9, 5'h03, 8'h00, 1'b0); // slave must stay silent
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "unknown USID: irq not raised");

    // -- check 7: back-to-back consecutive transactions -----------
    rffe_write(USID, 5'h0B, 8'h77);
    rffe_write(USID, 5'h0C, 8'h88);
    rffe_read (USID, 5'h0B, 8'h77, 1'b1);
    rffe_read (USID, 5'h0C, 8'h88, 1'b1);
    rffe_read (USID, 5'h03, 8'hA5, 1'b1);
    check(irq === 1'b0, "irq set at end of test");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized transactions. Classes: register write + read-back
    // compare, extended write (BC 1..8, random start, wrap modeled) +
    // read-back of every byte, bad command parity, bad data parity,
    // unknown USID, illegal command. irq is checked after every frame
    // (sticky until the next SSC). Scoreboard model mirrors the 16-deep
    // register file including the directed-test contents.
    begin : crv_phase
      int n_rw = 0, n_xw = 0, n_ep = 0, n_ed = 0, n_eu = 0, n_ei = 0;
      int n_eb = 0, n_ea = 0, n_ex = 0;
      int roll, bc_c, xstart;
      logic [3:0] sa_c;
      logic [2:0] cmd_c;
      logic [4:0] ad_c;
      logic [7:0] v, model [0:15];
      logic [8:0] df;
      logic [12:0] cf;
      logic bb;
      // scoreboard sync with the directed tests above
      for (int i = 0; i < 16; i++) model[i] = 8'h00;
      model[2] = 8'h55; model[3] = 8'hA5; model[4] = 8'h11; model[5] = 8'h22;
      model[6] = 8'h33; model[7] = 8'h5C; model[10] = 8'h3C;
      model[11] = 8'h77; model[12] = 8'h88; model[15] = 8'hC3;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 19);
        v = (roll == 0) ? 8'h00 : (roll == 1) ? 8'hFF
                                              : 8'($urandom_range(0, 255));
        ad_c = 5'($urandom_range(0, 15));   // reg file is 16 deep
        roll = $urandom_range(0, 19);
        if (roll < 9) begin
          // ---- register write + read-back compare ----
          n_rw++;
          model[ad_c[3:0]] = v;
          `MRFFE_M_SSC
          cf = {USID, 3'b010, ad_c, 1'b0}; cf[0] = ^cf[12:1];
          for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
          df = {v, ^v};
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
          `MRFFE_M_PARK
          // read back
          `MRFFE_M_SSC
          cf = {USID, 3'b011, ad_c, 1'b0}; cf[0] = ^cf[12:1];
          for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
          `MRFFE_M_BIT(1'b0)                       // BP cycle
          m_oe = 1'b0;
          for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
          m_oe = 1; m_val = 0;
          `MRFFE_M_PARK
          if (df[8:1] !== v) begin
            errors++; $display("ERROR: CRV readback @%h got=%h exp=%h", ad_c, df[8:1], v);
          end
          if (df[0] !== (^df[8:1])) begin
            errors++; $display("ERROR: CRV readback bad slave parity @%h", ad_c);
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during valid traffic");
          end
        end else if (roll < 12) begin
          // ---- extended register write BC=1..8 + full read-back ----
          n_xw++;
          bc_c   = 1 + $urandom_range(0, 7);
          xstart = $urandom_range(0, 15);
          `MRFFE_M_SSC
          cf = {USID, 3'b110, 5'(bc_c), 1'b0}; cf[0] = ^cf[12:1];
          for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
          df = {8'(xstart), ^8'(xstart)};      // address frame
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
          for (int k = 0; k < bc_c; k++) begin
            v = 8'($urandom_range(0, 255));
            model[4'(xstart + k)] = v;         // 4-bit wrap, mirrors RTL
            df = {v, ^v};
            for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
          end
          `MRFFE_M_PARK
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set after ext write");
          end
          // read back every written register
          for (int k = 0; k < bc_c; k++) begin
            ad_c = 5'(4'(xstart + k));
            `MRFFE_M_SSC
            cf = {USID, 3'b011, ad_c, 1'b0}; cf[0] = ^cf[12:1];
            for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
            `MRFFE_M_BIT(1'b0)
            m_oe = 1'b0;
            for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
            m_oe = 1; m_val = 0;
            `MRFFE_M_PARK
            if (df[8:1] !== model[ad_c[3:0]]) begin
              errors++; $display("ERROR: CRV xreadback @%h got=%h exp=%h",
                                 ad_c, df[8:1], model[ad_c[3:0]]);
            end
          end
        end else begin
          // ---- error-injection classes ----
          case ($urandom_range(0, 6))
            0: begin
              // bad command parity: frame ignored + irq
              n_ep++;
              `MRFFE_M_SSC
              cf = {USID, 3'b010, ad_c, 1'b0}; cf[0] = ~(^cf[12:1]);
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              df = {v, ^v};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad cmd parity: irq not raised");
              end
            end
            1: begin
              // bad data parity: write dropped + irq, reg unchanged
              n_ed++;
              `MRFFE_M_SSC
              cf = {USID, 3'b010, ad_c, 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              df = {v, ~(^v)};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad data parity: irq not raised");
              end
              // read back: old model value must be retained
              `MRFFE_M_SSC
              cf = {USID, 3'b011, ad_c, 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MRFFE_M_PARK
              if (df[8:1] !== model[ad_c[3:0]]) begin
                errors++; $display("ERROR: CRV dropped write changed reg @%h", ad_c);
              end
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq not cleared by next SSC");
              end
            end
            2: begin
              // unknown USID read: slave silent (reads all 1s) + irq
              n_eu++;
              sa_c = 4'($urandom_range(0, 15));
              if (sa_c == USID) sa_c = sa_c ^ 4'h1;   // rejection sampling
              `MRFFE_M_SSC
              cf = {sa_c, 3'b011, ad_c, 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MRFFE_M_PARK
              if (df !== 9'h1FF) begin
                errors++; $display("ERROR: CRV slave answered foreign USID %h", sa_c);
              end
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV unknown USID: irq not raised");
              end
            end
            3: begin
              // illegal command encoding: no response + irq
              n_ei++;
              cmd_c = 3'($urandom_range(0, 7));
              if (cmd_c == 3'b010 || cmd_c == 3'b011 || cmd_c == 3'b110)
                cmd_c = 3'b000;                       // rejection sampling
              `MRFFE_M_SSC
              cf = {USID, cmd_c, ad_c, 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV illegal cmd %b: irq not raised", cmd_c);
              end
            end
            4: begin
              // illegal extended-write byte count (0 or >8): irq, no write
              n_eb++;
              bc_c = ($urandom_range(0, 1)) ? 0 : 9 + $urandom_range(0, 6);
              `MRFFE_M_SSC
              cf = {USID, 3'b110, 5'(bc_c), 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              df = {v, ^v};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV illegal BC=%0d: irq not raised", bc_c);
              end
            end
            5: begin
              // bad extended-write ADDRESS-frame parity: irq, no write
              n_ea++;
              bc_c   = 1 + $urandom_range(0, 7);
              xstart = $urandom_range(0, 15);
              `MRFFE_M_SSC
              cf = {USID, 3'b110, 5'(bc_c), 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              df = {8'(xstart), ~(^8'(xstart))};      // WRONG addr parity
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              df = {v, ^v};                            // must be ignored
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_PARK
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
              `MRFFE_M_SSC
              cf = {USID, 3'b110, 5'(bc_c), 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              df = {8'(xstart), ^8'(xstart)};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              // byte 0: good parity -> written
              v = 8'($urandom_range(0, 255));
              model[4'(xstart)] = v;
              df = {v, ^v};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              // byte 1: bad parity -> dropped, remaining bytes ignored
              df = {8'hA5, ~(^8'hA5)};
              for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              for (int k = 2; k < bc_c; k++) begin
                df = {8'h5A, ^8'h5A};
                for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
              end
              `MRFFE_M_PARK
              repeat (4) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV bad xdata parity: irq not raised");
              end
              // byte 0 must have landed; byte 1 must be unchanged
              `MRFFE_M_SSC
              ad_c = 5'(4'(xstart));
              cf = {USID, 3'b011, ad_c, 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MRFFE_M_PARK
              if (df[8:1] !== model[4'(xstart)]) begin
                errors++; $display("ERROR: CRV xdata byte0 lost @%h", ad_c);
              end
              `MRFFE_M_SSC
              ad_c = 5'(4'(xstart + 1));
              cf = {USID, 3'b011, ad_c, 1'b0}; cf[0] = ^cf[12:1];
              for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
              `MRFFE_M_BIT(1'b0)
              m_oe = 1'b0;
              for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
              m_oe = 1; m_val = 0;
              `MRFFE_M_PARK
              if (df[8:1] !== model[4'(xstart + 1)]) begin
                errors++; $display("ERROR: CRV dropped xdata changed reg @%h", ad_c);
              end
            end
          endcase
        end
      end
      // ---- deterministic toggle-closure sweep -------------------------
      // walk the whole register file with 0xFF then 0x00 so every mem bit
      // toggles both ways (random traffic alone left stray bits at 0-hit)
      for (int a = 0; a < 16; a++) begin
        for (int p = 0; p < 2; p++) begin
          v = p ? 8'h00 : 8'hFF;
          model[a] = v;
          `MRFFE_M_SSC
          cf = {USID, 3'b010, 5'(a), 1'b0}; cf[0] = ^cf[12:1];
          for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
          df = {v, ^v};
          for (int i = 8; i >= 0; i--) begin bb = df[i]; `MRFFE_M_BIT(bb) end
          `MRFFE_M_PARK
        end
        // read back final value (0x00) for self-check
        `MRFFE_M_SSC
        cf = {USID, 3'b011, 5'(a), 1'b0}; cf[0] = ^cf[12:1];
        for (int i = 12; i >= 0; i--) begin bb = cf[i]; `MRFFE_M_BIT(bb) end
        `MRFFE_M_BIT(1'b0)
        m_oe = 1'b0;
        for (int i = 8; i >= 0; i--) begin `MRFFE_M_RBIT(bb) df[i] = bb; end
        m_oe = 1; m_val = 0;
        `MRFFE_M_PARK
        if (df[8:1] !== 8'h00) begin
          errors++; $display("ERROR: CRV sweep readback @%h got=%h exp=00", a, df[8:1]);
        end
      end
      if (irq !== 1'b0) begin
        errors++; $display("ERROR: CRV irq set at end of sweep");
      end
      $display("CRV: 120 txns + 48 sweep (wr_rd=%0d ext_wr=%0d | badpar=%0d baddat=%0d usid=%0d illcmd=%0d badbc=%0d badxaddr=%0d badxdata=%0d)",
               n_rw, n_xw, n_ep, n_ed, n_eu, n_ei, n_eb, n_ea, n_ex);
    end
  `undef MRFFE_M_BIT
  `undef MRFFE_M_SSC
  `undef MRFFE_M_PARK
  `undef MRFFE_M_RBIT
`endif

    if (errors == 0) $display("TEST PASSED: MIPI_RFFE");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < MRFFE_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, MRFFE_FSM_TOTAL);
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
    repeat (20000) #1000;   // 20 ms in 1-us chunks
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
