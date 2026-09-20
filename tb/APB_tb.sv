// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for APB_top -- APB3 master model
// Checks: reset state / write-read compare x4 / pready wait states /
//         pslverr on reserved region + irq / back-to-back transfers /
//         penable-without-psel robustness
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module APB_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic          psel;
  logic          penable;
  logic [AW-1:0] paddr;
  logic          pwrite;
  logic [DW-1:0] pwdata;
  logic [DW-1:0] prdata;
  logic          pready;
  logic          pslverr;
  logic          irq;

  int errors = 0;
  int wait_cycles;
  logic [DW-1:0] rd_data;    // prdata sampled in the completing ACCESS cycle
  logic          slverr_f;   // pslverr sampled in the completing ACCESS cycle
  logic          irq_f;      // irq sampled in the completing ACCESS cycle

  APB_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .psel(psel), .penable(penable), .paddr(paddr), .pwrite(pwrite),
    .pwdata(pwdata), .prdata(prdata),
    .pready(pready), .pslverr(pslverr), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic chk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s @%0t", msg, $time);
    end
  endtask

  // idle the bus for n cycles
  task automatic bus_idle(input int n);
    psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
    repeat (n) @(negedge clk);
  endtask

  // SETUP phase: drive psel/penable/attrs for exactly one full cycle
  // (driven at negedge so they are stable around the capturing posedge)
  task automatic apb_setup(input logic [AW-1:0] a, input logic w,
                           input logic [DW-1:0] d);
    @(negedge clk);
    psel = 1'b1; penable = 1'b0; paddr = a; pwrite = w; pwdata = d; #1;
  endtask

  // ACCESS phase: raise penable for the next cycle, honor pready wait
  // states and count them. Completion-time outputs are sampled mid
  // completing cycle, then the completing clock edge is passed so callers
  // may change bus signals without corrupting the write data.
  task automatic apb_access;
    @(negedge clk);
    penable = 1'b1; #1;                    // first ACCESS cycle
    wait_cycles = 0;
    while (pready !== 1'b1) begin
      wait_cycles++;
      chk(pslverr === 1'b0, "apb: pslverr must be low while pready=0");
      @(negedge clk); #1;
    end
    rd_data  = prdata;                     // sample completing-cycle outputs
    slverr_f = pslverr;
    irq_f    = irq;
    @(posedge clk); #1;                    // transfer completes here
  endtask

  // end the transfer immediately after the completing ACCESS cycle so no
  // phantom SETUP is started
  task automatic apb_done;
    psel = 1'b0; penable = 1'b0;
    @(negedge clk); #1;
  endtask

  // full write transaction, bus returned to idle afterwards
  task automatic apb_write(input logic [AW-1:0] a, input logic [DW-1:0] d,
                           input bit exp_slverr);
    apb_setup(a, 1'b1, d);
    apb_access();
    chk(slverr_f === exp_slverr, "apb_write: pslverr mismatch");
    if (exp_slverr) chk(irq_f === 1'b1, "apb_write: irq expected on pslverr");
    apb_done();
  endtask

  // full read transaction with data compare
  task automatic apb_read(input logic [AW-1:0] a, input logic [DW-1:0] exp,
                          input bit exp_slverr);
    apb_setup(a, 1'b0, '0);
    apb_access();
    chk(slverr_f === exp_slverr, "apb_read: pslverr mismatch");
    if (!exp_slverr)
      chk(rd_data === exp, "apb_read: data mismatch");
    if (exp_slverr) chk(irq_f === 1'b1, "apb_read: irq expected on pslverr");
    apb_done();
  endtask

  initial begin
    psel = 0; penable = 0; paddr = '0; pwrite = 0; pwdata = '0;

    // ---------------- 1. reset state ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    #1;
    chk(pready  === 1'b0, "reset: pready must be 0 outside ACCESS");
    chk(pslverr === 1'b0, "reset: pslverr must be 0");
    chk(prdata  === '0,   "reset: prdata must be 0");
    chk(irq     === 1'b0, "reset: irq must be 0");
    rst_n = 1; repeat (2) @(posedge clk);

    // ---------------- 2. write/read compare x4 (fast region) ------------
    apb_write(32'h0000, 32'hA5A5_0001, 0);
    chk(wait_cycles == 0, "fast write: no wait state expected");
    apb_write(32'h0004, 32'hA5A5_0002, 0);
    apb_write(32'h0008, 32'hA5A5_0003, 0);
    apb_write(32'h000C, 32'hA5A5_0004, 0);
    apb_read(32'h0000, 32'hA5A5_0001, 0);
    chk(wait_cycles == 0, "fast read: no wait state expected");
    apb_read(32'h0004, 32'hA5A5_0002, 0);
    apb_read(32'h0008, 32'hA5A5_0003, 0);
    apb_read(32'h000C, 32'hA5A5_0004, 0);

    // ---------------- 3. slow region: pready wait states ----------------
    apb_write(32'h0404, 32'h5A5A_1234, 0);
    chk(wait_cycles == 1, "slow write: exactly one wait state expected");
    apb_read(32'h0404, 32'h5A5A_1234, 0);
    chk(wait_cycles == 1, "slow read: exactly one wait state expected");

    // ---------------- 4. reserved region -> pslverr ---------------------
    apb_read(32'h0800, 32'h0, 1);
    apb_write(32'h0808, 32'hFFFF_FFFF, 1);   // aliases word 2, must not write
    // register file must not be corrupted by the errored write
    apb_read(32'h0008, 32'hA5A5_0003, 0);

    // ---------------- 5. penable without psel: slave must ignore --------
    @(negedge clk);
    psel = 1'b0; penable = 1'b1; paddr = 32'h0; pwrite = 1'b1;
    pwdata = 32'hDEAD_BEEF; #1;
    chk(pready === 1'b0 && pslverr === 1'b0, "penable w/o psel must be ignored");
    @(negedge clk); penable = 1'b0; #1;
    apb_read(32'h0000, 32'hA5A5_0001, 0);   // untouched, still functional

    // ---------------- 6. back-to-back transfers (psel held high) --------
    // write 0x10 then 0x14 then read both, psel never dropped between
    @(negedge clk); #1;
    apb_setup(32'h0010, 1'b1, 32'hB2B2_0010);   // SETUP t0
    apb_access();                               // ACCESS t0
    chk(slverr_f === 1'b0, "b2b: write0 pslverr");
    apb_setup(32'h0014, 1'b1, 32'hB2B2_0014);   // SETUP t1 (psel stays 1)
    apb_access();                               // ACCESS t1
    chk(slverr_f === 1'b0, "b2b: write1 pslverr");
    apb_setup(32'h0010, 1'b0, '0);              // SETUP t2
    apb_access();                               // ACCESS t2
    chk(rd_data === 32'hB2B2_0010, "b2b: read0 data mismatch");
    apb_setup(32'h0014, 1'b0, '0);              // SETUP t3
    apb_access();                               // ACCESS t3
    chk(rd_data === 32'hB2B2_0014, "b2b: read1 data mismatch");
    apb_done();

    // ---------------- 7. consecutive transactions after idle ------------
    bus_idle(3);
    apb_write(32'h0020, 32'hC3C3_0020, 0);
    apb_read(32'h0020, 32'hC3C3_0020, 0);
    apb_read(32'h0020, 32'hC3C3_0020, 0);   // repeated read, same value

    bus_idle(2);
    if (errors == 0) $display("TEST PASSED: APB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #50000;
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

endmodule
