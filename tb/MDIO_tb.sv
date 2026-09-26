// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as MDIO master (Clause 22) -- SystemVerilog
`timescale 1ns/1ps
module MDIO_tb;
  logic clk = 0, rst_n = 0;
  tri1  mdio;
  logic mdc = 0;
  logic m_low = 0;
  logic md_s;
  int errors = 0;

  MDIO_top #(.PHY_ADDR(5'h0C)) dut (
    .clk(clk), .rst_n(rst_n), .mdio(mdio), .mdc(mdc), .irq());

  always #5 clk = ~clk;
  assign mdio = m_low ? 1'b0 : 1'bz;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> $urandom_range + rejection
  // sampling, hierarchical FSM probe, counted immediate assertions.
  // =====================================================================
  localparam int MDIO_FSM_TOTAL = 2;  // frame engine: 0=idle, 1=frame_act
  logic [1:0] fsm_seen = '0;
  wire        dut_fa = dut.frame_act;  // hierarchical FSM probe

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

  // FSM coverage: sample frame-engine state every clock
  always @(posedge clk) fsm_seen[dut_fa] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic [5:0] cnt_q = '0;
  int rst_cyc = 0;   // first reset posedge is sampled pre-NBA (regs still X)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: frame engine quiescent in reset
      if (rst_cyc > 0)
        sva_check(!dut_fa && !dut.read_match && (dut.cnt === 6'd0),
                  "A1 reset: engine quiescent");
      rst_cyc++;
    end else begin
      // A2: bit counter bounded by the 32-bit frame length
      sva_check(dut.cnt <= 6'd29 || !dut_fa, "A2 cnt bounded in frame");
      // A3: slave pulls mdio low only inside the read-data window
      sva_check(!dut.drive_low ||
                (dut.read_match && (dut.cnt >= 6'd14) && (dut.cnt <= 6'd29)),
                "A3 slave drive only in read window");
      // A4: irq is exactly frame_act && last-bit
      sva_check(dut.irq === (dut_fa && (dut.cnt == 6'd29)), "A4 irq definition");
      // A5: cnt steps by at most one (or clears on frame start)
      sva_check(((dut.cnt - cnt_q) <= 6'd1) || (dut.cnt === 6'd0),
                "A5 cnt steps <=1");
      // A6: a matched read window implies a read opcode was seen
      sva_check(!dut.read_match || dut.read_frame, "A6 read_match needs read_frame");
    end
    cnt_q <= dut.cnt;
  end
`endif

  task automatic mdc_bit(input logic bit_v);
    begin
      m_low = ~bit_v; #300;         // bit 0 -> pull low, bit 1 -> release (tri1)
      mdc = 1; #1;                  // sample at the rising edge: slave holds the
      md_s = mdio;                  // pre-edge drive; it advances ~30ns after
      #299;                         // the edge (sync + cnt increment)
      mdc = 0; #300;
    end
  endtask

  task automatic mdio_write(input logic [4:0] pa, input logic [4:0] ra,
                            input logic [15:0] data);
    logic b;
    begin
      for (int i = 0; i < 32; i++) begin
        b = (i == 0) ? 1'b0 :                    // ST = 01
            (i == 1) ? 1'b1 :
            (i == 2) ? 1'b0 :                    // OP = 01 (write)
            (i == 3) ? 1'b1 :
            (i <  9) ? pa[8-i] :                 // PHYAD: i=4..8
            (i < 14) ? ra[13-i] :                // REGAD: i=9..13
            (i == 14) ? 1'b1 :                   // TA = 10
            (i == 15) ? 1'b0 :
                       data[31-i];               // DATA: i=16..31
        mdc_bit(b);
      end
      m_low = 0; #600;
    end
  endtask

  task automatic mdio_read(input logic [4:0] pa, input logic [4:0] ra,
                           output logic [15:0] data);
    logic b;
    begin
      for (int i = 0; i < 14; i++) begin
        b = (i == 0) ? 1'b0 : (i == 1) ? 1'b1 :
            (i == 2) ? 1'b1 : (i == 3) ? 1'b0 :  // OP = 10 (read)
            (i <  9) ? pa[8-i] :                 // PHYAD
                       ra[13-i];                 // REGAD
        mdc_bit(b);
      end
      mdc_bit(1'b1);                            // TA bit 1: master releases
      mdc_bit(1'b1);                            // TA bit 2: slave begins driving
      for (int i = 0; i < 16; i++) begin
        mdc_bit(1'b1);                          // keep released, sample read data
        data[15-i] = md_s;
      end
      m_low = 0; #600;
    end
  endtask

  logic [15:0] rdata;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    mdio_write(5'h0C, 5'h03, 16'hBEEF);
    repeat(10) @(posedge clk);
    mdio_read (5'h0C, 5'h03, rdata);
    if (rdata !== 16'hBEEF) begin
      errors++; $display("ERROR: MDIO rw got=%h exp=BEEF", rdata);
    end

    mdio_read (5'h0C, 5'h00, rdata);            // preset PHY ID reg
    if (rdata !== 16'h1140) begin
      errors++; $display("ERROR: MDIO reg0 got=%h exp=1140", rdata);
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized frames against a shadow register model:
    //  ~45% random write (data corners 0000/FFFF biased), ~25% read-back,
    //  ~15% write+read same register (reg 0/31 boundary biased),
    //  ~10% wrong-PHY write (must be ignored; verified by read-back),
    //  ~5%  wrong-PHY read (no slave drive -> 16'hFFFF on the pullup).
    begin : crv_phase
      logic [15:0] model [0:31];
      logic [15:0] d, rd_c;
      logic [4:0]  ra, pa;
      int roll;
      int n_wr = 0, n_rd = 0, n_rw = 0, n_ww = 0, n_wr_rd = 0;
      for (int i = 0; i < 32; i++) model[i] = 16'h0000;
      model[0] = 16'h1140;                       // PHY ID preset
      model[3] = 16'hBEEF;                       // directed-phase write
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 19);
        ra   = $urandom_range(0, 31);
        if ($urandom_range(0, 7) == 0) ra = ($urandom_range(0, 1)) ? 5'd31 : 5'd0;
        d    = $urandom_range(0, 65535);
        if ($urandom_range(0, 11) == 0) d = 16'h0000;
        if ($urandom_range(0, 11) == 0) d = 16'hFFFF;
        if (roll < 9) begin
          // random write
          n_wr++;
          mdio_write(5'h0C, ra, d);
          model[ra] = d;
        end else if (roll < 14) begin
          // random read-back vs model
          n_rd++;
          mdio_read(5'h0C, ra, rd_c);
          if (rd_c !== model[ra]) begin
            errors++; $display("ERROR: CRV rd reg%0d got=%h exp=%h", ra, rd_c, model[ra]);
          end
        end else if (roll < 17) begin
          // write + read same register
          n_rw++;
          mdio_write(5'h0C, ra, d);
          model[ra] = d;
          mdio_read(5'h0C, ra, rd_c);
          if (rd_c !== d) begin
            errors++; $display("ERROR: CRV rw reg%0d got=%h exp=%h", ra, rd_c, d);
          end
        end else if (roll < 19) begin
          // wrong-PHY write must be ignored (rejection-sample pa != 0x0C)
          n_ww++;
          pa = $urandom_range(0, 31);
          if (pa == 5'h0C) pa = 5'h0D;
          mdio_write(pa, ra, d);
          mdio_read(5'h0C, ra, rd_c);
          if (rd_c !== model[ra]) begin
            errors++;
            $display("ERROR: CRV wrong-phy wr leaked: reg%0d got=%h exp=%h",
                     ra, rd_c, model[ra]);
          end
        end else begin
          // wrong-PHY read: slave stays off the bus -> all ones
          n_wr_rd++;
          pa = $urandom_range(0, 31);
          if (pa == 5'h0C) pa = 5'h0D;
          mdio_read(pa, ra, rd_c);
          if (rd_c !== 16'hFFFF) begin
            errors++; $display("ERROR: CRV wrong-phy rd got=%h exp=FFFF", rd_c);
          end
        end
      end
      $display("CRV: 120 frames (wr=%0d rd=%0d rw=%0d wrong_phy_wr=%0d wrong_phy_rd=%0d)",
               n_wr, n_rd, n_rw, n_ww, n_wr_rd);
    end
`endif

    if (errors == 0) $display("TEST PASSED: MDIO");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < MDIO_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, MDIO_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Random phase adds bus traffic: extend the guard. Chunked into 1-us
  // delays: with Verilator 5.006 a single long-pending #delay event
  // corrupts the --timing delay heap once many short-delay resumptions
  // interleave (processes lose wakeups, long event fires early).
  initial begin
    repeat (20000) #1000;   // 20 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
