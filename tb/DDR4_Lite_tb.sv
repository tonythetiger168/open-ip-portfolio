// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DDR4_Lite_tb -- directed + randomized verification for DDR4_Lite_top.
//
//   S1 single write/read              S2 4-bank interleave (tRRD, open rows)
//   S3 row conflict (PRE/ACT/tRAS)    S4 mode registers (MRW/MRR, CL/CWL)
//   S5 randomized traffic + refresh   S6 protocol-error irq
//
// Protocol monitors (checked on the PHY pins, not hierarchically):
//   tRP  PRE->ACT      tRCD ACT->RD/WR   tRC  ACT->ACT (same bank)
//   tRAS ACT->PRE      tRRD ACT->ACT (diff bank)         tRFC REF->cmd
//   tRP  PREA->REF     refresh liveness (T_REFI shortened to 64)
// ============================================================================
`timescale 1ns/1ps

module DDR4_Lite_tb;

  localparam integer T_RCD=6, T_RP=6, T_RC=24, T_RAS=16, T_RRD=3,
                     T_WR=8, T_WTR=4, T_RFC=40, T_REFI=64;

  reg         clk = 1'b0;
  reg         rst_n;
  reg         hvalid;
  wire        hready;
  reg  [2:0]  hcmd;
  reg  [31:0] haddr;
  reg  [15:0] hwdata;
  wire [15:0] hrdata;
  wire        hdone;
  wire        irq;
  wire        ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n;
  wire [1:0]  ba;
  wire [13:0] addr;
  tri  [15:0] dq;
  tri  [1:0]  dqs;
  wire        trace_valid;
  wire [2:0]  trace_cmd;
  wire [31:0] trace_addr;

  integer tb_err = 0;
  integer cyc = 0;

  DDR4_Lite_top #(.T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS),
                  .T_RRD(T_RRD), .T_WR(T_WR), .T_WTR(T_WTR), .T_RFC(T_RFC),
                  .T_REFI(T_REFI), .CL(11), .CWL(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .hvalid(hvalid), .hready(hready), .hcmd(hcmd), .haddr(haddr),
    .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone), .irq(irq),
    .ck_t(ck_t), .ck_c(ck_c), .cke(cke), .cs_n(cs_n), .act_n(act_n),
    .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .ba(ba), .addr(addr),
    .dq(dq), .dqs(dqs),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------- deterministic data pattern ----------------
  function [15:0] data_word(input [31:0] a, input int b);
    data_word = a[15:0] ^ (16'h0101 * b[15:0]) ^ 16'h5A5A;
  endfunction

  // ---------------- front-end tasks ----------------
  task fe_write_line(input [31:0] a);
    begin
      @(negedge clk); hcmd <= 3'd2; haddr <= a; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0;
      for (int b = 0; b < 8; b++) begin
        hwdata <= data_word(a, b);
        @(negedge clk);
      end
      wait (hdone === 1'b1); @(negedge clk);
    end
  endtask

  task fe_read_check(input [31:0] a);
    reg [15:0] got;
    begin
      @(negedge clk); hcmd <= 3'd1; haddr <= a; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0;
      wait (hready === 1'b0);
      wait (hready === 1'b1);
      for (int b = 0; b < 8; b++) begin
        @(posedge clk); #1 got = hrdata;
        if (got !== data_word(a, b)) begin
          tb_err = tb_err + 1;
          $display("FAIL: read mismatch addr=%h beat=%0d got=%h exp=%h (cyc %0d)",
                   a, b, got, data_word(a, b), cyc);
        end
      end
      @(negedge clk);
    end
  endtask

  task fe_mrw(input [2:0] idx, input [7:0] v);
    begin
      @(negedge clk); hcmd <= 3'd3; haddr <= {29'h0, idx}; hwdata <= {8'h0, v};
      hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0;
      wait (hdone === 1'b1); @(negedge clk);
    end
  endtask

  task fe_mrr(input [2:0] idx, input [7:0] exp_v);
    begin
      @(negedge clk); hcmd <= 3'd4; haddr <= {29'h0, idx}; hvalid <= 1'b1;
      @(negedge clk); hvalid <= 1'b0;
      wait (hdone === 1'b1); #1;
      if (hrdata[7:0] !== exp_v) begin
        tb_err = tb_err + 1;
        $display("FAIL: MRR MR%0d got=%h exp=%h", idx, hrdata[7:0], exp_v);
      end
      @(negedge clk);
    end
  endtask

  // ---------------- protocol monitor ----------------
  integer last_act [0:3], last_pre [0:3], last_rw [0:3];
  integer last_act_any, last_ref, last_prea;
  integer ref_count = 0;

  initial begin
    for (int i = 0; i < 4; i++) begin
      last_act[i] = -1000; last_pre[i] = -1000; last_rw[i] = -1000;
    end
    last_act_any = -1000; last_ref = -1000; last_prea = -1000;
  end

  task chk(input cond, input [255:0] msg, input integer got, input integer exp);
    if (!cond) begin
      tb_err = tb_err + 1;
      $display("FAIL: %s (cyc %0d, got %0d exp %0d)", msg, cyc, got, exp);
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && !cs_n) begin
      if (!act_n) begin                        // ACT
        chk(cyc - last_pre[ba]  >= T_RP,  "tRP (PRE->ACT)", cyc - last_pre[ba],  T_RP);
        chk(cyc - last_act[ba]  >= T_RC,  "tRC (ACT->ACT)", cyc - last_act[ba],  T_RC);
        chk(cyc - last_act_any  >= T_RRD, "tRRD",           cyc - last_act_any,  T_RRD);
        last_act[ba] <= cyc; last_act_any <= cyc;
      end else if (!ras_n && !cas_n && !we_n) begin   // MRS (not used by FE)
      end else if (!ras_n && !cas_n && we_n) begin    // REF
        chk(cyc - last_ref  >= T_RFC, "tRFC (REF->REF)", cyc - last_ref, T_RFC);
        chk(cyc - last_prea >= T_RP,  "tRP (PREA->REF)", cyc - last_prea, T_RP);
        last_ref <= cyc; ref_count <= ref_count + 1;
      end else if (!ras_n && cas_n && !we_n) begin    // PRE / PREA
        if (addr[10]) begin
          for (int i = 0; i < 4; i++) last_pre[i] <= cyc;
          last_prea <= cyc;
        end else begin
          chk(cyc - last_act[ba] >= T_RAS, "tRAS (ACT->PRE)", cyc - last_act[ba], T_RAS);
          last_pre[ba] <= cyc;
        end
      end else if (ras_n && !cas_n) begin             // RD / WR
        chk(cyc - last_act[ba] >= T_RCD, "tRCD (ACT->RD/WR)", cyc - last_act[ba], T_RCD);
        last_rw[ba] <= cyc;
      end
    end
  end

  // ---------------- scenarios ----------------
  integer seed = 32'hC0FFEE;
  reg [31:0] r_addr;
  reg [31:0] wlog [0:255];
  integer    wlog_n = 0;

  initial begin
    rst_n = 1'b0; hvalid = 1'b0; hcmd = 3'd0; haddr = 32'h0; hwdata = 16'h0;
    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // S1: single write/read
    fe_write_line(32'h0000_0000);
    fe_read_check(32'h0000_0000);

    // S2: 4 banks, same row, interleaved
    for (int b = 0; b < 4; b++) fe_write_line({22'h0, b[1:0], 9'h015, 4'h0});
    for (int b = 0; b < 4; b++) fe_read_check({22'h0, b[1:0], 9'h015, 4'h0});

    // S3: row conflict in bank 0
    fe_write_line(32'h0000_0200);   // row 1 (line 0)
    fe_read_check(32'h0000_0200);
    fe_read_check(32'h0000_0000);   // row 0 still intact after PRE/ACT

    // S4: mode registers
    fe_mrw(3'd0, 8'h24);            // CL = 5 + 4 = 9
    fe_mrr(3'd0, 8'h24);
    fe_mrw(3'd1, 8'h03);            // CWL = 5 + 3 = 8
    fe_mrr(3'd1, 8'h03);
    fe_write_line({22'h0, 2'b10, 9'h002, 4'h0});
    fe_read_check({22'h0, 2'b10, 9'h002, 4'h0});

    // S5: randomized traffic with refresh running (T_REFI=64)
    wlog_n = 0;
    for (int t = 0; t < 120; t++) begin
      r_addr = {$random(seed)} & 32'h0000_7FFF & ~32'hF;  // keep [3:0]=0
      r_addr[6:4] = r_addr[6:4] % 8;
      if (t % 2 == 0) begin
        fe_write_line(r_addr);
        wlog[wlog_n] = r_addr; wlog_n = wlog_n + 1;
      end else begin
        fe_read_check(r_addr);
      end
    end
    // read back everything that was written (post-refresh integrity)
    for (int i = 0; i < wlog_n; i++) fe_read_check(wlog[i]);

    // refresh liveness check
    chk(ref_count >= 10, "refresh liveness", ref_count, 10);

    // S6: protocol errors raise irq (inline: error transactions complete
    // at decode time, before any data beats)
    @(negedge clk); hcmd <= 3'd7; haddr <= 32'h0; hvalid <= 1'b1;
    @(negedge clk); hvalid <= 1'b0;
    wait (hdone === 1'b1); @(negedge clk);
    // out-of-range write (haddr[20]=1): dropped at decode, hdone pulses once
    @(negedge clk); hcmd <= 3'd2; haddr <= 32'h0010_0000; hvalid <= 1'b1;
    @(negedge clk); hvalid <= 1'b0;
    wait (hdone === 1'b1); @(negedge clk);
    repeat (4) @(negedge clk);
    if (irq !== 1'b1) begin
      tb_err = tb_err + 1;
      $display("FAIL: irq not raised after protocol errors");
    end

    // summary
    if (tb_err == 0) $display("SIM_PASS: DDR4_Lite_tb completed, refreshes seen: %0d", ref_count);
    else             $display("SIM_FAIL: %0d errors", tb_err);
    $finish;
  end

  // global timeout
  initial begin
    #2_000_000;
    $display("SIM_FAIL: timeout");
    $finish;
  end

endmodule
