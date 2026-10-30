// SPDX-License-Identifier: Apache-2.0
// func_ddr4_tb -- pin-level functional test for DDR4_top: the TB plays the
// DRAM and checks what the controller puts on the pins (command encodings,
// row / column address, bank state and timing, refresh, DQ, CAS latency).
// The device rules live in func_mem_model.svh.
// DDR4_top has no BA / BG pins (the slice keeps one 4-bank array), so the
// bank of ACT / RD / WR is taken from the trace port, which carries the
// host address one clock before the command, and a single-bank PRE closes
// the bank of the host command in flight.
//   make -f Makefile.DDR4 func
`timescale 1ns/1ps
module func_ddr4_tb;
  localparam int NCH = 1, NBK = 4;
  localparam int CL = 15, TRCD = 14, TRP = 14, TRC = 45, TRAS = 32, TRFC = 160, TREFI = 6240;
  localparam int REF_SLACK = 200;

  logic clk = 0, rst_n = 0, hvalid = 0;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke;
  logic [16:0] addr;
  tri [15:0] dq; tri [1:0] dqs;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;

  DDR4_top dut (.*);
  always #5 clk = ~clk;

  function automatic int cl_now();   return CL;   endfunction
  function automatic int trcd_now(); return TRCD; endfunction
  function automatic int bank_of(input logic [31:0] a); return a[10:9]; endfunction
  function automatic int cell_of(input logic [31:0] a); return a[7:0]; endfunction
  function automatic bit is_mrw(input logic [2:0] c, input logic [31:0] a); return 0; endfunction
  task automatic mrw(input logic [15:0] d); endtask

  `include "func_mem_model.svh"

  // bank of the host command in flight (target of a single-bank PRE)
  int hbank = 0;
  always @(posedge clk) if (rst_n && hvalid && hready) hbank = bank_of(haddr);

  // ------------------------------ pin decoder ------------------------------
  logic        p_tv = 0;               // trace of the previous clock
  logic [2:0]  p_tc;
  logic [31:0] p_ta;
  logic        p_dqd = 0;              // DQ driven in the previous clock
  logic [15:0] p_dq;
  always @(clk) #1 chk(ck_t === clk && ck_c === ~clk && cke === rst_n && dqs === 2'bzz,
                       "CK_t / CK_c follow the clock, CKE follows reset, DQS released");
  always @(negedge clk) begin
    if (!rst_n) begin
      chk({ras_n, cas_n, we_n} === 3'b111 && dq === 16'hzzzz && trace_valid === 1'b0 &&
          hdone === 1'b0, "reset: NOP, DQ released, no trace / hdone");
      dev_reset(); hq.delete(); done_q = 0; p_tv = 0; p_dqd = 0;
    end else begin
      case ({ras_n, cas_n, we_n})
        3'b111: ;
        3'b011: begin                                         // ACT
          chk(p_tv && p_tc == 3'd1, "ACT without an activate trace");
          chk(addr[16:14] == 0 && addr[13:0] == p_ta[31:18], $sformatf("ACT row %h, host row %h", addr, p_ta[31:18]));
          dev_act(bank_of(p_ta), addr[13:0]);
        end
        3'b101, 3'b100: begin                                 // RD / WR
          chk(p_tv && p_tc == (we_n ? 3'd2 : 3'd3), "RD / WR without a matching trace");
          chk(addr == {9'b0, p_ta[7:0]}, $sformatf("column address %h, host column %h", addr, p_ta[7:0]));
          if (!we_n) chk(p_dqd && p_dq == last_wdata, $sformatf("WR data on DQ %h, host wrote %h", p_dq, last_wdata));
          dev_cas(!we_n, bank_of(p_ta), p_ta[31:18], cell_of(p_ta), p_dq);
        end
        3'b010: if (addr[10]) dev_prea(); else dev_pre(hbank);    // PRE / PREA
        3'b001: dev_ref(-1);                                  // all-bank REF
        default: fail($sformatf("illegal command RAS_n/CAS_n/WE_n = %b", {ras_n, cas_n, we_n}));
      endcase
      // a trace is followed by its command on the next clock
      if (p_tv && {ras_n, cas_n, we_n} != (p_tc == 3'd1 ? 3'b011 : p_tc == 3'd2 ? 3'b101 : 3'b100))
        fail("trace not followed by its command");
      // DQ is driven only in the clock before a WR command
      if (p_dqd) chk({ras_n, cas_n, we_n} == 3'b100, "DQ driven without a WR");
      p_dqd = (dq !== 16'hzzzz);
      if (p_dqd) chk(trace_valid && trace_cmd == 3'd3 && !$isunknown(dq), "DQ driven outside a write");
      p_dq = dq; p_tv = trace_valid; p_tc = trace_cmd; p_ta = trace_addr;
    end
    dev_tick();
  end

  initial begin
    repeat (3) @(negedge clk);
    chk(hready === 1'b1 && hrdata === 16'h0, "reset: host ready, read data 0");
    rst_n = 1;

    // directed: ACT, WR, RD of one cell, a row conflict and a PRE
    host(3'd1, {14'h2A5C, 18'h0_0212}, 0);
    host(3'd3, {14'h2A5C, 18'h0_02C3}, 16'hBEEF);
    host(3'd2, {14'h2A5C, 18'h0_02C3}, 0);
    host(3'd2, {14'h1111, 18'h0_02C3}, 0);    // same bank, other row
    host(3'd4, {14'h1111, 18'h0_0200}, 0);
    host(3'd4, {14'h1111, 18'h0_0200}, 0);    // PRE of a closed bank: no pin command
    host(3'd0, 32'h0, 0);                      // no-op code
    // every column of one row, then read them back from another bank
    for (int c = 0; c < 256; c++) host(3'd3, {14'h0001, 10'h000, 8'(c)}, 16'(c * 16'h0101 ^ 16'h5A00));
    for (int c = 0; c < 256; c++) host(3'd2, {14'h0002, 10'h200, 8'(c)}, 0);

    traffic(3000);

    // the array survives a controller reset (a DRAM keeps its data)
    drain();
    @(negedge clk) rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int c = 0; c < 256; c += 17) host(3'd2, {14'h0003, 10'h000, 8'(c)}, 0);
    traffic(500);
    report("DDR4_func");
  end

  initial begin
    #20ms;
    $display("TIMEOUT"); $finish;
  end
endmodule
