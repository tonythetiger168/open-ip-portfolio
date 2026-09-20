// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for DFI_5_0__MC_PHY_Interface__top -- MC model
// The TB plays the DFI MC: it drives the command/write-data channels and
// checks the PHY model outputs.
// Checks:
//   1. reset state: init_complete=0, rddata_valid=0, lp_ack=0, irq=0
//   2. error injection: RD/WR commands before init -> ignored (no
//      rddata_valid) + sticky irq
//   3. init handshake: init_start -> init_complete after ~32 cycles,
//      complete drops when init_start is released
//   4. write -> read-back compare x2 (different bank/row), rddata_valid
//      exactly t_phy_rdlat(=5) cycles after dfi_rddata_en
//   5. write delay-line precision: decoy data 3 cycles after wrdata_en
//      must be ignored, data at exactly t_phy_wrlat(=4) is committed
//   6. byte mask: dfi_wrdata_mask=4'b0101 keeps bytes 0/2
//   7. back-to-back consecutive transactions x3
//   8. lp_ctrl handshake: req -> ack -> command in LP ignored + irq ->
//      release -> ack drops
`timescale 1ns/1ps
module DFI_5_0__MC_PHY_Interface__tb;

  localparam int T_PHY_WRLAT = 4;
  localparam int T_PHY_RDLAT = 5;

  logic clk = 0, rst_n = 0;
  logic [16:0] dfi_address;
  logic [2:0]  dfi_bank;
  logic        dfi_ras_n, dfi_cas_n, dfi_we_n, dfi_cs_n;
  logic        dfi_cke, dfi_odt;
  logic        dfi_wrdata_en;
  logic [31:0] dfi_wrdata;
  logic [3:0]  dfi_wrdata_mask;
  logic        dfi_rddata_en;
  logic        dfi_rddata_valid;
  logic [31:0] dfi_rddata;
  logic        dfi_init_start, dfi_init_complete;
  logic        dfi_lp_ctrl, dfi_lp_ctrl_ack;
  logic        irq;

  int errors = 0;

  DFI_5_0__MC_PHY_Interface__top dut (
    .clk(clk), .rst_n(rst_n),
    .dfi_address(dfi_address), .dfi_bank(dfi_bank),
    .dfi_ras_n(dfi_ras_n), .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n),
    .dfi_cs_n(dfi_cs_n), .dfi_cke(dfi_cke), .dfi_odt(dfi_odt),
    .dfi_wrdata_en(dfi_wrdata_en), .dfi_wrdata(dfi_wrdata),
    .dfi_wrdata_mask(dfi_wrdata_mask),
    .dfi_rddata_en(dfi_rddata_en),
    .dfi_rddata_valid(dfi_rddata_valid), .dfi_rddata(dfi_rddata),
    .dfi_init_start(dfi_init_start), .dfi_init_complete(dfi_init_complete),
    .dfi_lp_ctrl(dfi_lp_ctrl), .dfi_lp_ctrl_ack(dfi_lp_ctrl_ack),
    .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probes, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  //
  // FSM probe paths (DUT is not a wrapper; probe the RTL directly):
  //   dut.init_st (INIT_IDLE/RUN/DONE, 3 states)
  //   dut.lp_st   (LP_RUN/REQ/SLEEP/EXIT, 4 states)
  // =====================================================================
  localparam int CRV_INIT_FSM = 3;
  localparam int CRV_LP_FSM   = 4;
  localparam int CRV_FSM_TOTAL = CRV_INIT_FSM + CRV_LP_FSM;
  logic [2:0] init_seen = '0;         // init-FSM visited-state bitmap
  logic [3:0] lp_seen   = '0;         // lp-FSM visited-state bitmap
  wire  [1:0] dut_init_st = dut.init_st;
  wire  [1:0] dut_lp_st   = dut.lp_st;

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
    init_seen[dut_init_st] <= 1'b1;
    lp_seen[dut_lp_st]     <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic p_rdv = 0, p_irq = 0;
  int rst_cyc = 0;   // consecutive reset clocks (skip the fall-edge cycle:
                     // rst_n drops mid-step and the async clear lands NBA)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (checked from the 2nd reset
      // clock on: the pre-NBA sample then reflects the reset branch)
      if (rst_cyc >= 1) begin
        sva_check(dfi_init_complete === 1'b0, "A1a reset: init_complete low");
        sva_check(dfi_rddata_valid === 1'b0,  "A1b reset: rddata_valid low");
        sva_check(dfi_lp_ctrl_ack === 1'b0,   "A1c reset: lp_ack low");
        sva_check(irq === 1'b0,               "A1d reset: irq low");
      end
      rst_cyc <= rst_cyc + 1;
    end else begin
      rst_cyc <= 0;
      // A2: init FSM holds a legal enum encoding
      sva_check(dut_init_st <= 2'd2, "A2 init_st encoding legal");
      // A3: rddata gated to 0 when not valid
      sva_check(dfi_rddata_valid || (dfi_rddata === 32'd0),
                "A3 rddata gated when not valid");
      // A4: rddata_valid is a single-cycle pulse
      sva_check(!(p_rdv && dfi_rddata_valid), "A4 rddata_valid single pulse");
      // A5: lp ack only outside LP_RUN (REQ/SLEEP/EXIT handshake states)
      sva_check(!dfi_lp_ctrl_ack || (dut_lp_st != 2'd0),
                "A5 lp_ack only outside LP_RUN");
      // A6: irq is sticky until reset
      sva_check(!p_irq || irq, "A6 irq sticky");
      // A7: init_complete only while the init FSM is out of IDLE
      sva_check(!dfi_init_complete || (dut_init_st != 2'd0),
                "A7 init_complete implies init active");
    end
    p_rdv <= dfi_rddata_valid;
    p_irq <= irq;
  end
`endif

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
    end
  endtask

  // drive one command for exactly one dfi cycle (sampled at next posedge)
  task automatic dfi_cmd(input logic [2:0] cmd, input logic [2:0] bank,
                         input logic [4:0] row);
    begin
      @(negedge clk);
      dfi_cs_n    = 1'b0;
      dfi_ras_n   = cmd[2];
      dfi_cas_n   = cmd[1];
      dfi_we_n    = cmd[0];
      dfi_bank    = bank;
      dfi_address = {12'd0, row};
      @(negedge clk);
      dfi_cs_n    = 1'b1;               // DES
      dfi_ras_n   = 1'b1;
      dfi_cas_n   = 1'b1;
      dfi_we_n    = 1'b1;
    end
  endtask

  localparam logic [2:0] CMD_RD  = 3'b101;
  localparam logic [2:0] CMD_WR  = 3'b100;
  localparam logic [2:0] CMD_NOP = 3'b111;

  // DFI write: WR command, then dfi_wrdata_en, then the data beat exactly
  // t_phy_wrlat cycles after the cycle en is sampled.
  task automatic dfi_write(input logic [2:0] bank, input logic [4:0] row,
                           input logic [31:0] data, input logic [3:0] mask);
    begin
      dfi_cmd(CMD_WR, bank, row);
      @(negedge clk); dfi_wrdata_en = 1'b1;                 // sampled t0
      @(negedge clk); dfi_wrdata_en = 1'b0;                 // t0 passed
      @(negedge clk);                                       // t0+1..t0+2
      @(negedge clk); dfi_wrdata = 32'hDEAD_BEEF;           // decoy @t0+3
                      dfi_wrdata_mask = 4'hF;
      @(negedge clk); dfi_wrdata = data;                    // real  @t0+4
                      dfi_wrdata_mask = mask;
      @(negedge clk); dfi_wrdata = 32'd0;
                      dfi_wrdata_mask = 4'h0;
    end
  endtask

  // DFI read: RD command, then dfi_rddata_en; checks dfi_rddata_valid
  // asserts exactly t_phy_rdlat cycles after en is sampled.
  task automatic dfi_read(input logic [2:0] bank, input logic [4:0] row,
                          output logic [31:0] data);
    begin
      dfi_cmd(CMD_RD, bank, row);
      @(negedge clk); dfi_rddata_en = 1'b1;                 // sampled t0
      @(negedge clk); dfi_rddata_en = 1'b0;                 // t0 passed
      for (int i = 1; i < T_PHY_RDLAT; i++) begin
        @(posedge clk); #1;
        check(dfi_rddata_valid === 1'b0,
              $sformatf("rddata_valid early (+%0d)", i));
      end
      @(posedge clk); #1;                                   // t0+5
      check(dfi_rddata_valid === 1'b1, "rddata_valid missing at t_phy_rdlat");
      data = dfi_rddata;
      @(posedge clk); #1;
      check(dfi_rddata_valid === 1'b0, "rddata_valid not a single pulse");
      check(dfi_rddata === 32'd0, "rddata not gated to 0 after valid");
    end
  endtask

  task automatic do_reset;
    begin
      rst_n = 0;
      dfi_cs_n = 1; dfi_ras_n = 1; dfi_cas_n = 1; dfi_we_n = 1;
      dfi_address = 0; dfi_bank = 0; dfi_cke = 1; dfi_odt = 0;
      dfi_wrdata_en = 0; dfi_wrdata = 0; dfi_wrdata_mask = 0;
      dfi_rddata_en = 0; dfi_init_start = 0; dfi_lp_ctrl = 0;
      repeat (4) @(negedge clk);
      rst_n = 1;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic do_init;
    int n;
    begin
      @(negedge clk); dfi_init_start = 1'b1;
      n = 0;
      while (dfi_init_complete !== 1'b1 && n < 100) begin
        @(posedge clk); #1; n++;
      end
      check(dfi_init_complete === 1'b1, "init_complete never asserted");
      check(n >= 30 && n <= 34,
            $sformatf("init took %0d cycles (expected ~32)", n));
      @(negedge clk); dfi_init_start = 1'b0;
      @(posedge clk); #1;
      check(dfi_init_complete === 1'b0,
            "init_complete did not drop after handshake release");
    end
  endtask

  logic [31:0] rd;

`ifdef VERILATOR
  // ---- v2.5 CRV helpers (random upper address bits for toggle closure;
  //      the DUT only decodes dfi_address[4:0], upper bits are don't-care)
  task automatic crv_cmd(input logic [2:0] cmd, input logic [2:0] bank,
                         input logic [4:0] row, input logic [11:0] ahi);
    begin
      @(negedge clk);
      dfi_cs_n    = 1'b0;
      dfi_ras_n   = cmd[2];
      dfi_cas_n   = cmd[1];
      dfi_we_n    = cmd[0];
      dfi_bank    = bank;
      dfi_address = {ahi, row};
      dfi_odt     = $urandom_range(0, 1);   // sampled, no side effect
      @(negedge clk);
      dfi_cs_n    = 1'b1;
      dfi_ras_n   = 1'b1;
      dfi_cas_n   = 1'b1;
      dfi_we_n    = 1'b1;
    end
  endtask

  // write with the same delay-line discipline as dfi_write (decoy at
  // t0+3, real data exactly t_phy_wrlat after wrdata_en is sampled)
  task automatic crv_write(input logic [2:0] bank, input logic [4:0] row,
                           input logic [31:0] data, input logic [3:0] mask,
                           input logic [11:0] ahi);
    begin
      crv_cmd(CMD_WR, bank, row, ahi);
      @(negedge clk); dfi_wrdata_en = 1'b1;
      @(negedge clk); dfi_wrdata_en = 1'b0;
      @(negedge clk);
      @(negedge clk); dfi_wrdata = $urandom;              // decoy @t0+3
                      dfi_wrdata_mask = 4'hF;
      @(negedge clk); dfi_wrdata = data;                  // real  @t0+4
                      dfi_wrdata_mask = mask;
      @(negedge clk); dfi_wrdata = 32'd0;
                      dfi_wrdata_mask = 4'h0;
    end
  endtask

  task automatic crv_read(input logic [2:0] bank, input logic [4:0] row,
                          input logic [11:0] ahi, output logic [31:0] data);
    begin
      crv_cmd(CMD_RD, bank, row, ahi);
      @(negedge clk); dfi_rddata_en = 1'b1;
      @(negedge clk); dfi_rddata_en = 1'b0;
      repeat (T_PHY_RDLAT) @(posedge clk);
      #1;
      data = dfi_rddata;
      @(negedge clk);
    end
  endtask
`endif

  initial begin
    do_reset;

    // -- check 1: reset state -------------------------------------
    check(dfi_init_complete === 1'b0, "reset: init_complete != 0");
    check(dfi_rddata_valid === 1'b0,  "reset: rddata_valid != 0");
    check(dfi_lp_ctrl_ack === 1'b0,   "reset: lp_ctrl_ack != 0");
    check(irq === 1'b0,               "reset: irq != 0");

    // -- check 2: commands before init -> ignored + irq -----------
    dfi_cmd(CMD_WR, 3'd1, 5'd2);
    @(negedge clk); dfi_wrdata_en = 1'b1;
    @(negedge clk); dfi_wrdata_en = 1'b0;
    dfi_cmd(CMD_RD, 3'd1, 5'd2);
    @(negedge clk); dfi_rddata_en = 1'b1;
    @(negedge clk); dfi_rddata_en = 1'b0;
    repeat (T_PHY_RDLAT + 3) begin
      @(posedge clk); #1;
      check(dfi_rddata_valid === 1'b0,
            "pre-init: rddata_valid asserted (command not ignored)");
    end
    check(irq === 1'b1, "pre-init command: irq not raised");

    // -- check 3: init handshake -----------------------------------
    do_reset;                             // clear sticky irq, re-init
    do_init;
    check(irq === 1'b0, "irq set after clean init");

    // -- check 4: write -> read-back compare x2 --------------------
    dfi_write(3'd2, 5'd07, 32'h1234_5678, 4'h0);
    dfi_write(3'd5, 5'd19, 32'hCAFE_0001, 4'h0);
    dfi_read (3'd2, 5'd07, rd);
    check(rd === 32'h1234_5678, "readback mismatch @bank2/row7");
    dfi_read (3'd5, 5'd19, rd);
    check(rd === 32'hCAFE_0001, "readback mismatch @bank5/row19");
    check(irq === 1'b0, "irq set after good transactions");

    // -- check 5: write delay-line precision ------------------------
    // dfi_write plants a decoy 3 cycles after wrdata_en; if the delay
    // line were shorter than t_phy_wrlat the decoy would be committed.
    dfi_write(3'd0, 5'd01, 32'hAAAA_5555, 4'h0);
    dfi_read (3'd0, 5'd01, rd);
    check(rd === 32'hAAAA_5555, "delay line: decoy committed or data lost");

    // -- check 6: byte mask ------------------------------------------
    dfi_write(3'd0, 5'd02, 32'hFFFF_FFFF, 4'h0);
    dfi_write(3'd0, 5'd02, 32'h0000_0000, 4'b0101); // keep bytes 0,2
    dfi_read (3'd0, 5'd02, rd);
    check(rd === 32'h00FF_00FF, "byte mask semantics wrong");

    // -- check 7: back-to-back consecutive transactions --------------
    dfi_write(3'd7, 5'd00, 32'h1111_1111, 4'h0);
    dfi_write(3'd7, 5'd01, 32'h2222_2222, 4'h0);
    dfi_write(3'd7, 5'd02, 32'h3333_3333, 4'h0);
    dfi_read (3'd7, 5'd00, rd); check(rd === 32'h1111_1111, "b2b #0");
    dfi_read (3'd7, 5'd01, rd); check(rd === 32'h2222_2222, "b2b #1");
    dfi_read (3'd7, 5'd02, rd); check(rd === 32'h3333_3333, "b2b #2");

    // -- check 8: lp_ctrl handshake + command in LP -------------------
    @(negedge clk); dfi_lp_ctrl = 1'b1;
    begin
      int m;
      m = 0;
      while (dfi_lp_ctrl_ack !== 1'b1 && m < 20) begin
        @(posedge clk); #1; m++;
      end
      check(dfi_lp_ctrl_ack === 1'b1, "lp_ctrl_ack never asserted");
    end
    dfi_cmd(CMD_RD, 3'd2, 5'd07);         // illegal in LP: ignore + irq
    @(negedge clk); dfi_rddata_en = 1'b1;
    @(negedge clk); dfi_rddata_en = 1'b0;
    repeat (T_PHY_RDLAT + 3) begin
      @(posedge clk); #1;
      check(dfi_rddata_valid === 1'b0, "LP: rddata_valid asserted");
    end
    check(irq === 1'b1, "command in LP: irq not raised");
    @(negedge clk); dfi_lp_ctrl = 1'b0;
    begin
      int m;
      m = 0;
      while (dfi_lp_ctrl_ack !== 1'b0 && m < 20) begin
        @(posedge clk); #1; m++;
      end
      check(dfi_lp_ctrl_ack === 1'b0, "lp_ctrl_ack did not drop");
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 140 randomized transactions over a byte-masked scoreboard model:
    // ~40% WR (random bank/row/data/mask + model update), ~30% RD
    // (readback compare for locations written by this phase), ~15% legal
    // non-data commands (ACT/PRE/REF/MRS/NOP: accepted, no side effect),
    // ~5% cke/odt wiggles, ~10% LP episodes (command in LP -> ignored +
    // sticky irq, then reset+re-init; the DRAM array survives reset).
    begin : crv_phase
      logic [31:0] model [0:255];
      logic [255:0] written;
      logic [31:0] d, rcv;
      logic [3:0]  m;
      logic [11:0] ahi;
      int n_wr = 0, n_rd = 0, n_cmd = 0, n_wig = 0, n_lp = 0;
      int roll, b, r;
      written = '0;
      for (int t = 0; t < 140; t++) begin
        roll = $urandom_range(0, 19);
        b = $urandom_range(0, 7);
        r = $urandom_range(0, 31);
        // rejection sampling: over-weight boundary bank/row
        if ($urandom_range(0, 9) < 2) b = ($urandom_range(0, 1) == 0) ? 0 : 7;
        if ($urandom_range(0, 9) < 2) r = ($urandom_range(0, 1) == 0) ? 0 : 31;
        ahi = $urandom_range(0, 4095);
        if (roll < 8) begin
          // random write (+decoy) with random byte mask; model update
          n_wr++;
          d = $urandom;
          m = $urandom_range(0, 15);
          if ($urandom_range(0, 9) < 3) m = ($urandom_range(0, 1) == 0) ? 4'h0 : 4'hF;
          crv_write(3'(b), 5'(r), d, m, ahi);
          for (int k = 0; k < 4; k++)
            if (!m[k]) model[{3'(b), 5'(r)}][8*k +: 8] = d[8*k +: 8];
          written[{3'(b), 5'(r)}] = 1'b1;
        end else if (roll < 14) begin
          // random read + readback compare (only CRV-written locations:
          // the directed phase leaves live data in the array)
          n_rd++;
          crv_read(3'(b), 5'(r), ahi, rcv);
          if (written[{3'(b), 5'(r)}] && rcv !== model[{3'(b), 5'(r)}]) begin
            errors++;
            $display("ERROR: CRV RD b%0d r%0d got=%h exp=%h",
                     b, r, rcv, model[{3'(b), 5'(r)}]);
          end
        end else if (roll < 17) begin
          // legal non-data command (MRS/REF/PRE/ACT/NOP): no side effect
          n_cmd++;
          begin
            logic [2:0] nops [0:4];
            nops[0] = 3'b000; nops[1] = 3'b001; nops[2] = 3'b010;
            nops[3] = 3'b011; nops[4] = 3'b111;
            crv_cmd(nops[$urandom_range(0, 4)], 3'(b), 5'(r), ahi);
          end
        end else if (roll < 18) begin
          // cke low pulse between commands (legal, no command in flight)
          n_wig++;
          @(negedge clk); dfi_cke = 1'b0;
          repeat (2) @(negedge clk);
          dfi_cke = 1'b1;
        end else begin
          // LP episode: request -> ack -> illegal command in LP (ignored,
          // sticky irq) -> release -> reset clears irq -> re-init; the
          // DRAM array is not reset, so the scoreboard stays valid
          n_lp++;
          @(negedge clk); dfi_lp_ctrl = 1'b1;
          while (dfi_lp_ctrl_ack !== 1'b1) @(posedge clk);
          crv_cmd(CMD_RD, 3'(b), 5'(r), ahi);
          @(negedge clk); dfi_rddata_en = 1'b1;
          @(negedge clk); dfi_rddata_en = 1'b0;
          repeat (T_PHY_RDLAT + 3) begin
            @(posedge clk); #1;
            if (dfi_rddata_valid !== 1'b0) begin
              errors++; $display("ERROR: CRV LP: rddata_valid asserted");
            end
          end
          if (irq !== 1'b1) begin
            errors++; $display("ERROR: CRV LP: irq not raised");
          end
          @(negedge clk); dfi_lp_ctrl = 1'b0;
          while (dfi_lp_ctrl_ack !== 1'b0) @(posedge clk);
          do_reset;
          do_init;
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV LP: irq not cleared by reset");
          end
        end
      end
      // deterministic data toggle closure: write+readback all-zeros /
      // all-ones / alternating patterns so every dfi_rddata bit toggles
      // both directions (random stimulus leaves single-bit misses)
      begin
        logic [31:0] pats [0:3];
        pats[0] = 32'h0000_0000; pats[1] = 32'hFFFF_FFFF;
        pats[2] = 32'hAAAA_AAAA; pats[3] = 32'h5555_5555;
        for (int i = 0; i < 4; i++) begin
          crv_write(3'd0, 5'd0, pats[i], 4'h0, 12'h000);
          model[0] = pats[i];
          written[0] = 1'b1;
          crv_read(3'd0, 5'd0, 12'h000, rcv);
          if (rcv !== pats[i]) begin
            errors++;
            $display("ERROR: CRV toggle RD got=%h exp=%h", rcv, pats[i]);
          end
        end
      end
      $display("CRV: 140 txns (wr=%0d rd=%0d cmd=%0d wig=%0d lp=%0d) + 8 toggle txns",
               n_wr, n_rd, n_cmd, n_wig, n_lp);
    end
`endif

    if (errors == 0) $display("TEST PASSED: DFI_5_0__MC_PHY_Interface_");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CRV_INIT_FSM; s++) visited += init_seen[s];
      for (int s = 0; s < CRV_LP_FSM; s++)   visited += lp_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CRV_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Random phase adds traffic: extend the guard. The timeout is chunked
  // into 1-us delays: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (see docs/COVERAGE.md note 1).
  initial begin
    repeat (8000) #1000;    // 8 ms in 1-us chunks
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
