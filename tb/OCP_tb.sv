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
  logic irq_mon = 1'b0;
  always @(posedge clk) if (irq) irq_mon <= 1'b1;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.state (S_IDLE/S_ACCEPT/S_LAT/S_RESP), 4 states.
  // =====================================================================
  localparam int OCP_FSM_TOTAL = 4;
  logic [3:0] fsm_seen = '0;          // visited-state bitmap
  wire  [1:0] dut_state = dut.state;
  logic irq_seen_c = 1'b0;

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

  // FSM coverage: sample DUT state register on both edges (scheduler
  // failure mode #3 mitigation: dual-edge probe tolerates lost wakeups)
  always @(posedge clk or negedge clk) fsm_seen[dut_state] <= 1'b1;
  always @(posedge clk) if (irq) irq_seen_c <= 1'b1;

  // output-invariant assertion suite (level/comb checks, negedge-sampled
  // so all NBA updates are settled; no history-dependent properties)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(sresp === 2'b00 && scmdaccept === 1'b0 && irq === 1'b0,
                  "A1 reset: outputs quiescent");
    end else begin
      // A2: SResp is NULL outside the response state
      sva_check((dut_state == 2'd3) || (sresp === 2'b00), "A2 sresp NULL unless S_RESP");
      // A3: SData/SThreadID mirror their holding registers
      sva_check(sdata === dut.rdata_q && sthreadid === dut.thread_q,
                "A3 S outputs mirror regs");
      // A4: SCmdAccept exactly reflects S_ACCEPT (ACCEPT_DLY=1 build)
      sva_check(scmdaccept === (dut_state == 2'd1), "A4 scmdaccept == S_ACCEPT");
      // A5: SResp=ERR only for a request captured as bad-address
      sva_check((sresp !== 2'b10) || dut.err_q, "A5 ERR implies err_q");
      // A6: state register holds a legal encoding (all 4 used)
      sva_check(dut_state <= 2'd3, "A6 state legal");
    end
    rst_n_q <= rst_n;
  end
`endif

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
`ifdef VERILATOR
    // forked irq monitors lose wakeups under the 5.006 timing scheduler
    // (mode #2); the module-level irq_mon flag replaces them here. The
    // iverilog path keeps the original fork structure bit-identical.
    irq_mon = 0;
    ocp_read(32'h800, '0, 2'b01, 2'b10);   // expect SResp=ERR
    repeat (2) @(posedge clk);
    if (!irq_mon) begin
      errors++;
      $display("ERROR: OCP reserved RD: no irq pulse");
    end
    irq_mon = 0;
    ocp_write(32'hFFC, 32'hDEAD_DEAD, 4'hF, 2'b00, 2'b10); // expect ERR
    repeat (2) @(posedge clk);
    if (!irq_mon) begin
      errors++;
      $display("ERROR: OCP reserved WR: no irq pulse");
    end
`else
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
`endif

    // CHECK 7: error injection - misaligned address
    ocp_read(32'h002, '0, 2'b00, 2'b10);       // expect SResp=ERR

    // reserved write must not corrupt regfile
    ocp_read(32'h000, 32'hA500_0000, 2'b00, 2'b01);

    repeat (5) @(posedge clk);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 256-word write sweep (mem toggle) + 120 randomized transactions:
    // WR / RD / WRNP with random byte-enables and thread ids across valid /
    // misaligned / reserved address classes. Errors expect SResp=ERR + irq
    // pulse; shadow regfile predicts every read. Reuses the bounded master
    // tasks (fixed 2-cycle DVA latency checked per transaction).
    begin : crv_phase
      int n_wr = 0, n_rd = 0, n_np = 0, n_err = 0;
      logic [31:0] sh_mem [0:255];
      logic [31:0] ba, db;
      logic [3:0]  be_v;
      logic [1:0]  tid_v;
      int roll, cls;
      irq_seen_c = 1'b0;
      for (int w = 0; w < 256; w++) begin
        sh_mem[w] = $urandom;
        ocp_write(w*4, sh_mem[w], 4'hF, w[1:0], 2'b01);
      end
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 9);
        db = $urandom; tid_v = $urandom_range(0, 3);
        be_v = (t % 3 == 0) ? 4'hF : (4'h1 << $urandom_range(0, 3));
        cls  = $urandom_range(0, 3);
        if (cls == 3)      ba = 32'h400 + $urandom;              // reserved
        else if (cls == 2) ba = {$urandom_range(0, 255), 2'b00} |
                                $urandom_range(1, 3);            // misaligned
        else               ba = {$urandom_range(0, 255), 2'b00}; // valid
        if (roll < 4) begin
          // write (or posted write): errors get SResp=ERR / silent irq
          if (ba[31:10] == 0 && ba[1:0] == 0) begin
            for (int b = 0; b < 4; b++)
              if (be_v[b]) sh_mem[ba[9:2]][b*8 +: 8] = db[b*8 +: 8];
          end
          if (roll == 3) begin
            ocp_write_np(ba, db);
            n_np++;
          end else begin
            ocp_write(ba, db, be_v, tid_v,
                      (ba[31:10] != 0 || ba[1:0] != 0) ? 2'b10 : 2'b01);
            n_wr++;
          end
          if (ba[31:10] != 0 || ba[1:0] != 0) n_err++;
        end else begin
          ocp_read(ba, (ba[31:10] == 0 && ba[1:0] == 0) ? sh_mem[ba[9:2]] : 32'h0,
                   tid_v, (ba[31:10] != 0 || ba[1:0] != 0) ? 2'b10 : 2'b01);
          n_rd++;
          if (ba[31:10] != 0 || ba[1:0] != 0) n_err++;
        end
      end
      if (!irq_seen_c) begin
        errors++; $display("ERROR: CRV irq never pulsed on error classes");
      end
      // regfile must be intact after the error classes
      for (int w = 1; w < 256; w += 31) ocp_read(w*4, sh_mem[w], 2'b00, 2'b01);
      $display("CRV: 376 txns (sweep=256 wr=%0d rd=%0d wrnp=%0d err=%0d)",
               n_wr, n_rd, n_np, n_err);
    end
`endif

    if (errors == 0) $display("TEST PASSED: OCP");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < OCP_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, OCP_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave
  initial begin
    repeat (4000) #1000;
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #200000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
