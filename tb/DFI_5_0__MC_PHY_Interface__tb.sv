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

    if (errors == 0) $display("TEST PASSED: DFI_5_0__MC_PHY_Interface_");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
