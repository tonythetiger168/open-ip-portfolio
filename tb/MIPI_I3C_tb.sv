// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_I3C_top -- I3C master model
// Checks:
//   1. reset state: SDA released high, irq=0, dyn_addr_valid=0
//   2. legacy I2C write/read on the static address (combined format), x2 regs
//   3. ENTDAA full flow: broadcast 0x7E + CCC 0x07 + Sr + 0x7E/R,
//      64-bit {PID,BCR,DCR} compare, dynamic address 0x2A assignment + ACK
//   4. post-ENTDAA write/read via the dynamic address (data compare)
//   5. direct CCC GETPID (0x8C): 6-byte PID readback compare
//   6. IBI: slave pull detected, arbitration address compare, payload compare
//   7. error injection: unknown broadcast CCC -> NACK + irq, cleared by START
//   8. consecutive transactions back-to-back
// The SDA bus is modelled as tri1 (pull-up); both ends drive open-drain/pp.
`timescale 1ns/1ps
module MIPI_I3C_tb;

  localparam int HALF = 60;          // half SCL period in ns (6 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_scl = 1;                   // master drives SCL (push-pull)
  tri1  sda;                         // bus with pull-up
  logic m_od_low = 0;                // master open-drain pull
  assign sda = m_od_low ? 1'b0 : 1'bz;

  logic       ibi_req = 0;
  logic [7:0] ibi_data = 8'h00;
  logic [6:0] dyn_addr;
  logic       dyn_addr_valid;
  logic       irq;

  int errors = 0;

  localparam logic [6:0]  SADDR = 7'h3C;
  localparam logic [47:0] PID   = 48'h0123_4567_89AB;
  localparam logic [7:0]  BCR   = 8'h06;
  localparam logic [7:0]  DCR   = 8'h5A;
  localparam logic [6:0]  DYN   = 7'h2A;

  MIPI_I3C_top #(.STATIC_ADDR(SADDR), .PID(PID), .BCR(BCR), .DCR(DCR)) dut (
    .clk(clk), .rst_n(rst_n),
    .scl(m_scl), .sda(sda),
    .ibi_req(ibi_req), .ibi_data(ibi_data),
    .dyn_addr(dyn_addr), .dyn_addr_valid(dyn_addr_valid),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_idle;
    begin
      m_od_low = 0; m_scl = 1; #(2*HALF);
    end
  endtask

  task automatic m_start;
    begin
      m_od_low = 0; m_scl = 1; #HALF;
      m_od_low = 1;            #HALF;   // SDA falls while SCL high
      m_scl    = 0;            #HALF;
    end
  endtask

  task automatic m_stop;
    begin
      m_od_low = 1; m_scl = 0; #HALF;
      m_scl    = 1;            #HALF;
      m_od_low = 0;            #HALF;   // SDA rises while SCL high
    end
  endtask

  task automatic m_wbit(input logic b);
    begin
      m_scl    = 0;
      m_od_low = ~b;           #HALF;
      m_scl    = 1;            #HALF;
      m_scl    = 0;            #HALF;
    end
  endtask

  task automatic m_rbit(output logic b);
    begin
      m_od_low = 0;
      m_scl    = 0;            #HALF;
      m_scl    = 1;            #(HALF/2);
      b        = sda;          #(HALF/2);
      m_scl    = 0;            #HALF;
    end
  endtask

  // write byte, return slave ACK (1 = ACK)
  task automatic m_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 7; i >= 0; i--) m_wbit(d[i]);
      m_od_low = 0;            #HALF;
      m_scl    = 1;            #(HALF/2);
      ack      = (sda === 1'b0);
                               #(HALF/2);
      m_scl    = 0;            #HALF;
    end
  endtask

  // read byte, then drive ACK(0)/NACK(1)
  task automatic m_rbyte(output logic [7:0] d, input logic nack);
    logic b;
    begin
      for (int i = 7; i >= 0; i--) begin m_rbit(b); d[i] = b; end
      m_wbit(nack);
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
  localparam int MI3C_FSM_TOTAL = 15; // S_IDLE..S_WAIT_STOP (rtl enum)
  logic [15:0] fsm_seen = '0;         // visited-state bitmap
  wire  [4:0] dut_state = dut.state;  // hierarchical FSM probe

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
  bit first_cycle = 1;   // skip checks on the very first posedge (DUT
                         // reset values land in that NBA region)
  logic dav_q = 0;
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(irq === 1'b0 && dyn_addr_valid === 1'b0 &&
                dut.od_low === 1'b0 && dut.pp_en === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: state register holds a legal enum encoding
      sva_check(dut_state <= 5'd14, "A2 state encoding legal");
      // A3: irq mirrors the sticky error flag
      sva_check(irq === dut.err_sticky, "A3 irq mirrors err_sticky");
      // A4: dyn_addr_valid is sticky once ENTDAA completes
      sva_check(!dav_q || dyn_addr_valid, "A4 dyn_addr_valid sticky");
      // A5: push-pull drive only in data-transmit phases
      sva_check(!dut.pp_en || (dut_state == 5'd5) || (dut_state == 5'd12),
                "A5 push-pull only in TX phases");
      // A6: bit counter never exceeds a byte phase
      sva_check(dut.bcnt <= 4'd8, "A6 bcnt within byte phase");
      // A7: the dynamic address, once valid, is the ENTDAA-assigned one
      sva_check(!dyn_addr_valid || (dyn_addr === DYN), "A7 dyn_addr stable");
      // A8: IBI pull only from IDLE
      sva_check(!dut.ibi_pull || (dut_state == 5'd0), "A8 IBI pull only in IDLE");
    end
    dav_q <= dyn_addr_valid;
  end

  // ---- inlined bit-level macros for the random phase ------------------
  // (same Verilator 5.006 scheduler rationale as the I2C pilot: chained
  // timing-task coroutines can lose wakeups after ~2k awaits, so the
  // random phase runs as ONE coroutine with plain #awaits only)
  `define MI3C_M_START \
    m_od_low = 0; m_scl = 1; #HALF; \
    m_od_low = 1;            #HALF; \
    m_scl    = 0;            #HALF;
  `define MI3C_M_STOP \
    m_od_low = 1; m_scl = 0; #HALF; \
    m_scl    = 1;            #HALF; \
    m_od_low = 0;            #HALF;
  `define MI3C_M_WBIT(b) \
    m_scl    = 0; \
    m_od_low = ~(b);         #HALF; \
    m_scl    = 1;            #HALF; \
    m_scl    = 0;            #HALF;
  `define MI3C_M_RBIT(b) \
    m_od_low = 0; \
    m_scl    = 0;            #HALF; \
    m_scl    = 1;            #(HALF/2); \
    b        = sda;          #(HALF/2); \
    m_scl    = 0;            #HALF;
  // write byte, ack returned in ack_c (1 = ACK)
  `define MI3C_M_WBYTE(d) \
    for (int i = 7; i >= 0; i--) begin bb = ((d) >> i) & 1'b1; `MI3C_M_WBIT(bb) end \
    m_od_low = 0;            #HALF; \
    m_scl    = 1;            #(HALF/2); \
    ack_c    = (sda === 1'b0); \
                             #(HALF/2); \
    m_scl    = 0;            #HALF;
`endif

  // ---------------------------------------------------------------
  // compound transactions
  // ---------------------------------------------------------------
  task automatic i2c_write(input logic [6:0] addr, input logic [7:0] regidx,
                           input logic [7:0] data);
    logic ack;
    begin
      m_start;
      m_wbyte({addr, 1'b0}, ack); check(ack, "write: addr NACKed");
      m_wbyte(regidx, ack);     check(ack, "write: regidx NACKed");
      m_wbyte(data, ack);       check(ack, "write: data NACKed");
      m_stop;
    end
  endtask

  task automatic i2c_read(input logic [6:0] addr, input logic [7:0] regidx,
                          input logic [7:0] exp);
    logic ack; logic [7:0] d;
    begin
      m_start;
      m_wbyte({addr, 1'b0}, ack); check(ack, "read: addr(W) NACKed");
      m_wbyte(regidx, ack);     check(ack, "read: regidx NACKed");
      m_start;                               // repeated START
      m_wbyte({addr, 1'b1}, ack); check(ack, "read: addr(R) NACKed");
      m_rbyte(d, 1'b1);                      // single byte + NACK
      m_stop;
      if (d !== exp) begin
        errors++;
        $display("ERROR: read @%02x got=%02x exp=%02x", regidx, d, exp);
      end
    end
  endtask

  // ---------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------
  logic       ack;
  logic [7:0] d;
  logic [63:0] daa;
  logic        b;
  logic [7:0]  arb;

  initial begin
    m_scl = 1; m_od_low = 0;
    rst_n = 0; repeat (6) @(posedge clk);
    rst_n = 1; repeat (4) @(posedge clk);

    // -- check 1: reset / idle state ------------------------------
    check(sda === 1'b1, "SDA not released after reset");
    check(irq === 1'b0, "irq asserted after reset");
    check(dyn_addr_valid === 1'b0, "dyn_addr_valid set after reset");

    m_idle;

    // -- check 2: legacy I2C write/read on static address ---------
    i2c_write(SADDR, 8'h03, 8'hA5);
    i2c_write(SADDR, 8'h07, 8'h5C);
    i2c_read (SADDR, 8'h03, 8'hA5);
    i2c_read (SADDR, 8'h07, 8'h5C);

    // -- check 3: ENTDAA full flow --------------------------------
    m_start;
    m_wbyte(8'hFC, ack); check(ack, "ENTDAA: broadcast 7E/W NACKed");
    m_wbyte(8'h07, ack); check(ack, "ENTDAA: CCC 0x07 NACKed");
    m_start;                                   // repeated START
    m_wbyte(8'hFD, ack); check(ack, "ENTDAA: 7E/R NACKed");
    for (int i = 63; i >= 0; i--) begin m_rbit(b); daa[i] = b; end
    if (daa !== {PID, BCR, DCR}) begin
      errors++;
      $display("ERROR: ENTDAA DAA got=%012x exp=%012x", daa, {PID, BCR, DCR});
    end
    m_wbyte({DYN, 1'b0}, ack); check(ack, "ENTDAA: dyn addr NACKed");
    m_stop;
    repeat (4) @(posedge clk);
    check(dyn_addr_valid === 1'b1, "dyn_addr_valid not set after ENTDAA");
    check(dyn_addr === DYN, "dyn_addr mismatch after ENTDAA");

    // -- check 4: read/write via dynamic address ------------------
    i2c_write(DYN, 8'h0A, 8'h3C);
    i2c_read (DYN, 8'h0A, 8'h3C);
    i2c_read (DYN, 8'h03, 8'hA5);   // written earlier via static address

    // -- check 5: GETPID direct CCC -------------------------------
    m_start;
    m_wbyte({DYN, 1'b0}, ack); check(ack, "GETPID: addr(W) NACKed");
    m_wbyte(8'h8C, ack);       check(ack, "GETPID: CCC 0x8C NACKed");
    m_start;
    m_wbyte({DYN, 1'b1}, ack); check(ack, "GETPID: addr(R) NACKed");
    for (int i = 5; i >= 1; i--) begin
      m_rbyte(d, 1'b0);
      if (d !== PID[i*8 +: 8]) begin
        errors++; $display("ERROR: GETPID byte %0d got=%02x", i, d);
      end
    end
    m_rbyte(d, 1'b1);            // last PID byte + NACK
    if (d !== PID[7:0]) begin
      errors++; $display("ERROR: GETPID byte 0 got=%02x exp=%02x", d, PID[7:0]);
    end
    m_stop;

    // -- check 6: IBI ---------------------------------------------
    ibi_data = 8'hA5;
    ibi_req  = 1;
`ifdef VERILATOR
    // Tool note (5.006): `disable <named begin>` inside a fork is not
    // supported; the global chunked timeout guard covers the no-pull case.
    wait (sda === 1'b0);
`else
    fork
      begin : wait_pull
        wait (sda === 1'b0);
        disable pull_timeout;
      end
      begin : pull_timeout
        #20000;
        errors++; $display("ERROR: IBI: slave never pulled SDA");
        disable wait_pull;
      end
    join
`endif
    ibi_req = 0;
    // slave is pulling SDA; master clocks the arbitration (addr + RnW)
    for (int i = 7; i >= 0; i--) begin m_rbit(b); arb[i] = b; end
    if (arb !== {DYN, 1'b1}) begin
      errors++; $display("ERROR: IBI arb got=%02x exp=%02x", arb, {DYN, 1'b1});
    end
    m_wbit(1'b0);                // master ACKs: IBI accepted
    m_rbyte(d, 1'b0);            // payload byte + ACK
    if (d !== 8'hA5) begin
      errors++; $display("ERROR: IBI payload got=%02x exp=A5", d);
    end
    m_stop;
    m_idle;

    // -- check 7: error injection -- unknown broadcast CCC --------
    m_start;
    m_wbyte(8'hFC, ack); check(ack, "badCCC: broadcast 7E/W NACKed");
    m_wbyte(8'h55, ack); check(!ack, "badCCC: unknown CCC was ACKed");
    m_stop;
    repeat (6) @(posedge clk);
    check(irq === 1'b1, "badCCC: irq not raised for unknown CCC");
    // next valid transaction clears the error flag
    i2c_read(DYN, 8'h0A, 8'h3C);
    repeat (6) @(posedge clk);
    check(irq === 1'b0, "irq not cleared by new START");

    // -- check 8: back-to-back consecutive transactions -----------
    i2c_write(DYN, 8'h01, 8'h11);
    i2c_write(DYN, 8'h02, 8'h22);
    i2c_read (DYN, 8'h01, 8'h11);
    i2c_read (DYN, 8'h02, 8'h22);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 130 randomized transactions: static/dynamic-address writes with
    // read-back (1-2 byte, register auto-increment modeled), multi-byte
    // reads, periodic GETPID and IBI flows, plus round-robin error
    // injection (unknown direct CCC, unknown broadcast CCC, broadcast
    // read without ENTDAA, wrong address NACK). Scoreboard model mirrors
    // the 16-deep register file including directed-test contents.
    // Fully inlined via the macros above (single coroutine).
    begin : crv_phase
      int n_sw = 0, n_dw = 0, n_mr = 0, n_gp = 0, n_ib = 0;
      int n_ir = 0, n_il = 0;
      int n_dc = 0, n_bc = 0, n_br = 0, n_wa = 0;
      int roll, eroll = 0;
      logic [6:0] sa_c;
      logic [3:0] rp;
      logic [7:0] v, v0, v1, rd0, rd1, arb_c, ccc;
      logic [7:0] model [0:15];
      logic       bb, ack_c;
      // scoreboard sync with the directed tests above
      for (int i = 0; i < 16; i++) model[i] = 8'h00;
      model[1] = 8'h11; model[2] = 8'h22; model[3] = 8'hA5;
      model[7] = 8'h5C; model[10] = 8'h3C;
      for (int t = 0; t < 130; t++) begin
        roll = $urandom_range(0, 19);
        v = (roll == 0) ? 8'h00 : (roll == 1) ? 8'hFF
                                              : 8'($urandom_range(0, 255));
        rp = 4'($urandom_range(0, 15));
        if (t % 10 == 9) begin
          // ---- GETPID direct CCC: 6-byte PID readback ----
          n_gp++;
          `MI3C_M_START
          `MI3C_M_WBYTE({DYN, 1'b0})
          if (!ack_c) begin errors++; $display("ERROR: CRV GETPID addr(W) NACK"); end
          `MI3C_M_WBYTE(8'h8C)
          if (!ack_c) begin errors++; $display("ERROR: CRV GETPID CCC NACK"); end
          `MI3C_M_START
          `MI3C_M_WBYTE({DYN, 1'b1})
          if (!ack_c) begin errors++; $display("ERROR: CRV GETPID addr(R) NACK"); end
          for (int k = 5; k >= 1; k--) begin
            for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
            `MI3C_M_WBIT(1'b0)                       // ACK: next byte
            if (rd0 !== PID[k*8 +: 8]) begin
              errors++; $display("ERROR: CRV GETPID byte %0d got=%h", k, rd0);
            end
          end
          for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
          `MI3C_M_WBIT(1'b1)                         // NACK: end
          if (rd0 !== PID[7:0]) begin
            errors++; $display("ERROR: CRV GETPID byte 0 got=%h", rd0);
          end
          `MI3C_M_STOP
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set after GETPID");
          end
        end else if (t % 10 == 4) begin
          // ---- IBI variants (rotate: accept / refuse-then-accept /
          //      arbitration loss). Dummy START/STOP first: IBI has no
          //      START of its own, so any sticky irq from a preceding
          //      error-class txn must be cleared.
          `MI3C_M_START
          `MI3C_M_STOP
          ibi_data = v;
          ibi_req  = 1;
          wait (sda === 1'b0);
          ibi_req  = 0;
          case ((t / 10) % 3)
            0: begin
              // standard IBI: arbitrate, ACK, payload compare
              n_ib++;
              for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) arb_c[i] = bb; end
              if (arb_c !== {DYN, 1'b1}) begin
                errors++; $display("ERROR: CRV IBI arb got=%h exp=%h", arb_c, {DYN, 1'b1});
              end
              `MI3C_M_WBIT(1'b0)                     // master ACK: accept IBI
              for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
              `MI3C_M_WBIT(1'b0)                     // ACK payload
              if (rd0 !== v) begin
                errors++; $display("ERROR: CRV IBI payload got=%h exp=%h", rd0, v);
              end
              `MI3C_M_STOP
              m_od_low = 0; m_scl = 1; #(2*HALF);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq set after IBI");
              end
            end
            1: begin
              // master NACKs the arbitration: slave keeps ibi_pend and
              // re-pulls; master re-arbitrates and accepts
              n_ir++;
              for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) arb_c[i] = bb; end
              `MI3C_M_WBIT(1'b1)                     // NACK: refuse the IBI
              `MI3C_M_STOP
              m_od_low = 0; m_scl = 1; #(2*HALF);
              if (irq !== 1'b0) begin
                errors++; $display("ERROR: CRV irq set after IBI refuse");
              end
              // slave must re-pull (ibi_pend retained)
              wait (sda === 1'b0);
              for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) arb_c[i] = bb; end
              if (arb_c !== {DYN, 1'b1}) begin
                errors++; $display("ERROR: CRV IBI retry arb got=%h", arb_c);
              end
              `MI3C_M_WBIT(1'b0)                     // accept this time
              for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
              `MI3C_M_WBIT(1'b0)
              if (rd0 !== v) begin
                errors++; $display("ERROR: CRV IBI retry payload got=%h exp=%h", rd0, v);
              end
              `MI3C_M_STOP
              m_od_low = 0; m_scl = 1; #(2*HALF);
            end
            default: begin
              // arbitration loss: master (a higher-priority device)
              // pulls SDA low during the first released ('1') bit
              n_il++;
              `MI3C_M_RBIT(bb) arb_c[7] = bb;        // bit7 = 0 (driven low)
              // bit6 = '1': slave releases; master wins by pulling low
              m_od_low = 1;
              m_scl    = 0;            #HALF;
              m_scl    = 1;            #(HALF/2);
              bb       = sda;          #(HALF/2);
              m_scl    = 0;            #HALF;
              m_od_low = 0;
              repeat (6) @(posedge clk);
              if (irq !== 1'b1) begin
                errors++; $display("ERROR: CRV IBI arb loss: irq not raised");
              end
              `MI3C_M_STOP
              m_od_low = 0; m_scl = 1; #(2*HALF);
            end
          endcase
        end else begin
          roll = $urandom_range(0, 29);
          if (roll < 8) begin
            // ---- static-address write (1-2 bytes) + read-back ----
            n_sw++;
            v0 = v; v1 = 8'($urandom_range(0, 255));
            model[rp] = v0;
            `MI3C_M_START
            `MI3C_M_WBYTE({SADDR, 1'b0})
            if (!ack_c) begin errors++; $display("ERROR: CRV swr addr NACK"); end
            `MI3C_M_WBYTE({4'h0, rp})
            if (!ack_c) begin errors++; $display("ERROR: CRV swr ptr NACK"); end
            `MI3C_M_WBYTE(v0)
            if (!ack_c) begin errors++; $display("ERROR: CRV swr data NACK"); end
            if (rp < 15) begin
              model[rp + 1] = v1;
              `MI3C_M_WBYTE(v1)                      // auto-increment byte
              if (!ack_c) begin errors++; $display("ERROR: CRV swr data2 NACK"); end
            end
            `MI3C_M_STOP
            if (irq !== 1'b0) begin
              errors++; $display("ERROR: CRV irq set during valid write");
            end
            // single-byte read-back via repeated START
            `MI3C_M_START
            `MI3C_M_WBYTE({SADDR, 1'b0})
            `MI3C_M_WBYTE({4'h0, rp})
            `MI3C_M_START
            `MI3C_M_WBYTE({SADDR, 1'b1})
            if (!ack_c) begin errors++; $display("ERROR: CRV srd addr(R) NACK"); end
            for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
            `MI3C_M_WBIT(1'b1)                       // NACK: end
            `MI3C_M_STOP
            if (rd0 !== v0) begin
              errors++; $display("ERROR: CRV sreadback @%h got=%h exp=%h", rp, rd0, v0);
            end
          end else if (roll < 14) begin
            // ---- dynamic-address write + read-back ----
            n_dw++;
            model[rp] = v;
            `MI3C_M_START
            `MI3C_M_WBYTE({DYN, 1'b0})
            if (!ack_c) begin errors++; $display("ERROR: CRV dwr addr NACK"); end
            `MI3C_M_WBYTE({4'h0, rp})
            `MI3C_M_WBYTE(v)
            `MI3C_M_STOP
            `MI3C_M_START
            `MI3C_M_WBYTE({DYN, 1'b0})
            `MI3C_M_WBYTE({4'h0, rp})
            `MI3C_M_START
            `MI3C_M_WBYTE({DYN, 1'b1})
            if (!ack_c) begin errors++; $display("ERROR: CRV drd addr(R) NACK"); end
            for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
            `MI3C_M_WBIT(1'b1)
            `MI3C_M_STOP
            if (rd0 !== v) begin
              errors++; $display("ERROR: CRV dreadback @%h got=%h exp=%h", rp, rd0, v);
            end
            if (irq !== 1'b0) begin
              errors++; $display("ERROR: CRV irq set during dyn traffic");
            end
          end else if (roll < 17) begin
            // ---- multi-byte read (2 bytes, reg_ptr auto-increment) ----
            n_mr++;
            `MI3C_M_START
            `MI3C_M_WBYTE({DYN, 1'b0})
            `MI3C_M_WBYTE({4'h0, rp})
            `MI3C_M_START
            `MI3C_M_WBYTE({DYN, 1'b1})
            for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
            `MI3C_M_WBIT(1'b0)                       // ACK: next byte
            for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd1[i] = bb; end
            `MI3C_M_WBIT(1'b1)                       // NACK: end
            `MI3C_M_STOP
            if (rd0 !== model[rp]) begin
              errors++; $display("ERROR: CRV mrd b0 @%h got=%h exp=%h", rp, rd0, model[rp]);
            end
            if (rd1 !== model[rp + 4'd1]) begin
              errors++; $display("ERROR: CRV mrd b1 @%h got=%h exp=%h",
                                 rp + 4'd1, rd1, model[rp + 4'd1]);
            end
          end else begin
            // ---- error-injection classes (round-robin) ----
            case (eroll)
              0: begin
                // unknown direct CCC (bit7=1, not GETPID): NACK + irq
                n_dc++;
                ccc = 8'h80 | 8'($urandom_range(0, 127));
                if (ccc == 8'h8C) ccc = 8'h8D;       // rejection sampling
                `MI3C_M_START
                `MI3C_M_WBYTE({DYN, 1'b0})
                if (!ack_c) begin errors++; $display("ERROR: CRV dccc addr NACK"); end
                `MI3C_M_WBYTE(ccc)
                if (ack_c) begin
                  errors++; $display("ERROR: CRV unknown direct CCC %h ACKed", ccc);
                end
                `MI3C_M_STOP
                repeat (6) @(posedge clk);
                if (irq !== 1'b1) begin
                  errors++; $display("ERROR: CRV unknown direct CCC: irq not raised");
                end
              end
              1: begin
                // unknown broadcast CCC (not ENTDAA): NACK + irq
                n_bc++;
                ccc = 8'($urandom_range(0, 255));
                if (ccc == 8'h07) ccc = 8'h55;       // rejection sampling
                `MI3C_M_START
                `MI3C_M_WBYTE(8'hFC)
                if (!ack_c) begin errors++; $display("ERROR: CRV bccc 7E/W NACK"); end
                `MI3C_M_WBYTE(ccc)
                if (ack_c) begin
                  errors++; $display("ERROR: CRV unknown broadcast CCC %h ACKed", ccc);
                end
                `MI3C_M_STOP
                repeat (6) @(posedge clk);
                if (irq !== 1'b1) begin
                  errors++; $display("ERROR: CRV unknown broadcast CCC: irq not raised");
                end
              end
              2: begin
                // broadcast read 7E/R with no ENTDAA armed: NACK + irq
                n_br++;
                `MI3C_M_START
                `MI3C_M_WBYTE(8'hFD)
                if (ack_c) begin
                  errors++; $display("ERROR: CRV 7E/R w/o DAA ACKed");
                end
                `MI3C_M_STOP
                repeat (6) @(posedge clk);
                if (irq !== 1'b1) begin
                  errors++; $display("ERROR: CRV 7E/R w/o DAA: irq not raised");
                end
              end
              default: begin
                // wrong (neither static nor dynamic) address: NACK, no irq
                n_wa++;
                sa_c = 7'($urandom_range(0, 127));
                if (sa_c == SADDR || sa_c == DYN || sa_c == 7'h7E)
                  sa_c = 7'h01;                      // rejection sampling
                `MI3C_M_START
                `MI3C_M_WBYTE({sa_c, 1'b0})
                if (ack_c) begin
                  errors++; $display("ERROR: CRV wrong addr %h ACKed", sa_c);
                end
                `MI3C_M_STOP
                repeat (6) @(posedge clk);
                if (irq !== 1'b0) begin
                  errors++; $display("ERROR: CRV wrong addr raised irq");
                end
              end
            endcase
            eroll = (eroll + 1) % 4;
          end
        end
      end
      // ---- deterministic toggle-closure sweep -------------------------
      // walk the register file with 0xFF then 0x00 so every mem bit
      // toggles both ways, with read-back of the final zeros
      for (int a = 0; a < 16; a++) begin
        for (int p = 0; p < 2; p++) begin
          v = p ? 8'h00 : 8'hFF;
          model[a] = v;
          `MI3C_M_START
          `MI3C_M_WBYTE({DYN, 1'b0})
          `MI3C_M_WBYTE({4'h0, 4'(a)})
          `MI3C_M_WBYTE(v)
          `MI3C_M_STOP
        end
        `MI3C_M_START
        `MI3C_M_WBYTE({DYN, 1'b0})
        `MI3C_M_WBYTE({4'h0, 4'(a)})
        `MI3C_M_START
        `MI3C_M_WBYTE({DYN, 1'b1})
        for (int i = 7; i >= 0; i--) begin `MI3C_M_RBIT(bb) rd0[i] = bb; end
        `MI3C_M_WBIT(1'b1)
        `MI3C_M_STOP
        if (rd0 !== 8'h00) begin
          errors++; $display("ERROR: CRV sweep readback @%h got=%h exp=00", a, rd0);
        end
      end
      if (irq !== 1'b0) begin
        errors++; $display("ERROR: CRV irq set at end of sweep");
      end
      $display("CRV: 130 txns + sweep (swr=%0d dwr=%0d mrd=%0d getpid=%0d ibi=%0d/%0dr/%0dl | dirccc=%0d bcastccc=%0d bcastrd=%0d wrongaddr=%0d)",
               n_sw, n_dw, n_mr, n_gp, n_ib, n_ir, n_il, n_dc, n_bc, n_br, n_wa);
    end
  `undef MI3C_M_START
  `undef MI3C_M_STOP
  `undef MI3C_M_WBIT
  `undef MI3C_M_RBIT
  `undef MI3C_M_WBYTE
`endif

    if (errors == 0) $display("TEST PASSED: MIPI_I3C");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < MI3C_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, MI3C_FSM_TOTAL);
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
    repeat (40000) #1000;   // 40 ms in 1-us chunks
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
