// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for OCP_top -- OCP-IP slave, master model in TB
// Checks: reset state / WR+RD full-path compare / byte-enable merge /
//         posted WRNP (no response) / 2-cycle DVA latency / SThreadID echo /
//         reserved-region ERR + irq / back-to-back transactions
`timescale 1ns/1ps
module OCP_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic [2:0]      mcmd;
  logic [AW-1:0]   maddr;
  logic [DW-1:0]   mdata;
  logic [DW/8-1:0] mbyteen;
  logic [1:0]      mthreadid;
  logic            scmdaccept;
  logic [DW-1:0]   sdata;
  logic [1:0]      sresp;
  logic [1:0]      sthreadid;
  logic            irq;

  int errors = 0;

  localparam logic [2:0] MCMD_IDLE = 3'b000;
  localparam logic [2:0] MCMD_WR   = 3'b001;
  localparam logic [2:0] MCMD_RD   = 3'b010;
  localparam logic [2:0] MCMD_WRNP = 3'b101;

  OCP_top #(.DW(DW), .AW(AW), .ACCEPT_DLY(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .mcmd(mcmd), .maddr(maddr), .mdata(mdata),
    .mbyteen(mbyteen), .mthreadid(mthreadid),
    .scmdaccept(scmdaccept), .sdata(sdata), .sresp(sresp),
    .sthreadid(sthreadid), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // OCP master model: drive command until SCmdAccept, return latency
  // ------------------------------------------------------------------
  task automatic ocp_cmd(input logic [2:0] cmd, input logic [AW-1:0] a,
                         input logic [DW-1:0] d, input logic [3:0] be,
                         input logic [1:0] tid);
    begin
      @(negedge clk);
      mcmd <= cmd; maddr <= a; mdata <= d; mbyteen <= be; mthreadid <= tid;
      // hold command until accepted
      do @(posedge clk); while (!scmdaccept);
      @(negedge clk);
      mcmd <= MCMD_IDLE;
    end
  endtask

  // wait for response, return sresp/sdata and measure DVA latency
  task automatic ocp_wait_resp(output logic [1:0] rsp, output logic [DW-1:0] d,
                               output int lat);
    logic done;
    begin
      lat = 0; rsp = 2'b00; d = 'x; done = 0;
      while (!done) begin
        @(posedge clk);
        lat++;
        if (sresp != 2'b00) begin
          rsp = sresp; d = sdata; done = 1;
        end else if (lat > 20) begin
          errors++;
          $display("ERROR: OCP response timeout");
          done = 1;
        end
      end
    end
  endtask

  task automatic ocp_write(input logic [AW-1:0] a, input logic [DW-1:0] d,
                           input logic [3:0] be, input logic [1:0] tid,
                           input logic [1:0] exp_resp);
    logic [1:0] rsp; logic [DW-1:0] dd; int lat;
    begin
      ocp_cmd(MCMD_WR, a, d, be, tid);
      ocp_wait_resp(rsp, dd, lat);
      if (rsp !== exp_resp) begin
        errors++;
        $display("ERROR: OCP WR @%h resp=%b exp=%b", a, rsp, exp_resp);
      end
      if (lat !== 2) begin
        errors++;
        $display("ERROR: OCP WR @%h DVA latency=%0d exp=2", a, lat);
      end
      if (sthreadid !== tid) begin
        errors++;
        $display("ERROR: OCP WR @%h SThreadID=%b exp=%b", a, sthreadid, tid);
      end
    end
  endtask

  task automatic ocp_read(input logic [AW-1:0] a, input logic [DW-1:0] exp,
                          input logic [1:0] tid, input logic [1:0] exp_resp);
    logic [1:0] rsp; logic [DW-1:0] dd; int lat;
    begin
      ocp_cmd(MCMD_RD, a, '0, 4'hF, tid);
      ocp_wait_resp(rsp, dd, lat);
      if (rsp !== exp_resp) begin
        errors++;
        $display("ERROR: OCP RD @%h resp=%b exp=%b", a, rsp, exp_resp);
      end
      if (exp_resp == 2'b01 && dd !== exp) begin
        errors++;
        $display("ERROR: OCP RD @%h data=%h exp=%h", a, dd, exp);
      end
      if (lat !== 2) begin
        errors++;
        $display("ERROR: OCP RD @%h DVA latency=%0d exp=2", a, lat);
      end
      if (sthreadid !== tid) begin
        errors++;
        $display("ERROR: OCP RD @%h SThreadID=%b exp=%b", a, sthreadid, tid);
      end
    end
  endtask

  // posted write: expect accept but no response within 5 cycles
  task automatic ocp_write_np(input logic [AW-1:0] a, input logic [DW-1:0] d);
    int n;
    begin
      ocp_cmd(MCMD_WRNP, a, d, 4'hF, 2'b00);
      n = 0;
      repeat (5) begin
        @(posedge clk);
        if (sresp != 2'b00) begin
          errors++;
          $display("ERROR: OCP WRNP @%h got unexpected SResp=%b", a, sresp);
        end
        n++;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    mcmd = MCMD_IDLE; maddr = '0; mdata = '0; mbyteen = 4'hF; mthreadid = 2'b00;
    rst_n = 0; repeat (4) @(posedge clk);

    // CHECK 1: reset state
    if (sresp !== 2'b00 || scmdaccept !== 1'b0 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: OCP reset state sresp=%b scmdaccept=%b irq=%b",
               sresp, scmdaccept, irq);
    end
    rst_n = 1; repeat (2) @(posedge clk);

    // CHECK 2: write/read full-path compare (16 words, varying thread id)
    for (int i = 0; i < 16; i++)
      ocp_write(32'h000 + i*4, 32'hA500_0000 + i, 4'hF, i[1:0], 2'b01);
    for (int i = 0; i < 16; i++)
      ocp_read (32'h000 + i*4, 32'hA500_0000 + i, i[1:0], 2'b01);

    // CHECK 3: byte-enable partial write merge
    ocp_write(32'h040, 32'hFFFF_FFFF, 4'hF, 2'b01, 2'b01);
    ocp_write(32'h040, 32'h0000_1234, 4'b0011, 2'b10, 2'b01);
    ocp_read (32'h040, 32'hFFFF_1234, 2'b10, 2'b01);
    ocp_write(32'h040, 32'hAB00_0000, 4'b1000, 2'b11, 2'b01);
    ocp_read (32'h040, 32'hABFF_1234, 2'b11, 2'b01);

    // CHECK 4: posted WRNP - accepted, written, but no response
    ocp_write_np(32'h080, 32'hCAFE_0001);
    ocp_write_np(32'h084, 32'hCAFE_0002);
    ocp_read(32'h080, 32'hCAFE_0001, 2'b00, 2'b01);
    ocp_read(32'h084, 32'hCAFE_0002, 2'b00, 2'b01);

    // CHECK 5: back-to-back transactions (no idle gap between cmds)
    begin
      int seen;
      seen = 0;
      fork
        begin : b2b_mon
          repeat (20) begin
            @(posedge clk);
            if (sresp == 2'b01) seen++;
          end
        end
        begin : b2b_drv
          @(negedge clk);
          mcmd <= MCMD_WR; maddr <= 32'h0C0; mdata <= 32'hB2B_0001; mbyteen <= 4'hF; mthreadid <= 2'b01;
          do @(posedge clk); while (!scmdaccept);
          @(negedge clk);
          mcmd <= MCMD_WR; maddr <= 32'h0C4; mdata <= 32'hB2B_0002; // immediately re-drive
          // note: slave is busy; cmd must be held until accepted
          do @(posedge clk); while (!scmdaccept);
          @(negedge clk); mcmd <= MCMD_IDLE;
        end
      join
      if (seen !== 2) begin
        errors++;
        $display("ERROR: OCP back-to-back: %0d DVA responses seen, exp 2", seen);
      end
    end
    ocp_read(32'h0C0, 32'hB2B_0001, 2'b00, 2'b01);
    ocp_read(32'h0C4, 32'hB2B_0002, 2'b00, 2'b01);

    // CHECK 6: error injection - reserved region (>=0x400) read & write
    begin
      logic irq_seen;
      irq_seen = 0;
      fork
        begin
          repeat (10) begin
            @(posedge clk);
            if (irq) irq_seen = 1;
          end
        end
        ocp_read(32'h800, '0, 2'b01, 2'b10);   // expect SResp=ERR
      join
      if (!irq_seen) begin
        errors++;
        $display("ERROR: OCP reserved RD: no irq pulse");
      end
    end
    begin
      logic irq_seen;
      irq_seen = 0;
      fork
        begin
          repeat (10) begin
            @(posedge clk);
            if (irq) irq_seen = 1;
          end
        end
        ocp_write(32'hFFC, 32'hDEAD_DEAD, 4'hF, 2'b00, 2'b10); // expect ERR
      join
      if (!irq_seen) begin
        errors++;
        $display("ERROR: OCP reserved WR: no irq pulse");
      end
    end

    // CHECK 7: error injection - misaligned address
    ocp_read(32'h002, '0, 2'b00, 2'b10);       // expect SResp=ERR

    // reserved write must not corrupt regfile
    ocp_read(32'h000, 32'hA500_0000, 2'b00, 2'b01);

    repeat (5) @(posedge clk);
    if (errors == 0) $display("TEST PASSED: OCP");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
