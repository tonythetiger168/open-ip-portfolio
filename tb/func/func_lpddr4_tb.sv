// SPDX-License-Identifier: Apache-2.0
// func_lpddr4_tb -- pin-level functional test for LPDDR4_top (two channels,
// eight banks): the TB plays the DRAM, decodes the CA frames (beat 0 with
// CS_n low = {code, bank}; ACT carries the row in 3 beats, RD / WR the
// column in 2, LSB first) and checks the device rules in
// func_mem_model.svh: per-bank state and timing, round-robin per-bank
// refresh, DQ ownership per channel, and CL / tRCD of the frequency set
// that the MRW to MR7 (host WR to column 0xF0) selects.
//   make -f Makefile.LPDDR4 func
`timescale 1ns/1ps
module func_lpddr4_tb;
  localparam int NCH = 2, NBK = 8;
  localparam int TRP = 14, TRC = 38, TRAS = 28, TRFC = 130, TREFI = 1560;
  localparam int REF_SLACK = 200;

  logic clk = 0, rst_n = 0, hvalid = 0;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hready, hdone, ck_t, ck_c, cs_n, cke;
  logic [5:0] ca;
  tri [31:0] dq; tri [1:0] dqs;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;

  LPDDR4_top dut (.*);
  always #5 clk = ~clk;

  bit fset = 0;                        // frequency set the TB expects
  function automatic int cl_now();   return fset ? 22 : 15; endfunction
  function automatic int trcd_now(); return fset ? 14 : 15; endfunction
  function automatic int bank_of(input logic [31:0] a); return {a[8], a[10:9]}; endfunction
  function automatic int cell_of(input logic [31:0] a); return {a[8], a[7:0]}; endfunction
  function automatic bit is_mrw(input logic [2:0] c, input logic [31:0] a);
    return c == 3'd3 && a[7:0] == 8'hF0;
  endfunction
  task automatic mrw(input logic [15:0] d); fset = d[0]; endtask

  `include "func_mem_model.svh"

  // ------------------------------ CA decoder ------------------------------
  logic        p_tv = 0;               // trace of the previous clock
  logic [2:0]  p_tc;
  logic [31:0] p_ta;
  logic [1:0]  p_dqd = 0;              // DQ halves driven in the previous clock
  logic [31:0] p_dq;
  // frame being received
  int          f_left = 0, f_t0, f_bank, f_beat;
  logic [2:0]  f_code;
  logic [17:0] f_pay;
  logic [31:0] f_ta;
  logic [15:0] f_wd;
  int          ref_exp = 0;            // next bank of the per-bank refresh

  task automatic frame_done();
    int t;
    t = cyc; cyc = f_t0;               // device timing counts from beat 0
    case (f_code)
      3'd1: begin
        chk(f_pay[17:14] == 0 && f_pay[13:0] == f_ta[31:18], $sformatf("ACT row %h, host row %h", f_pay[13:0], f_ta[31:18]));
        dev_act(f_bank, f_pay[13:0]);
      end
      3'd2, 3'd3: begin
        chk(f_pay[11:8] == 0 && f_pay[7:0] == f_ta[7:0], $sformatf("column %h, host column %h", f_pay[7:0], f_ta[7:0]));
        dev_cas(f_code == 3'd3, f_bank, f_ta[31:18], {f_bank[2], f_pay[7:0]}, f_wd);
      end
      default: ;
    endcase
    cyc = t;
  endtask

  always @(clk) #1 chk(ck_t === clk && ck_c === ~clk && cke === rst_n && dqs === 2'bzz,
                       "CK_t / CK_c follow the clock, CKE follows reset, DQS released");
  always @(negedge clk) begin
    if (!rst_n) begin
      chk(cs_n === 1'b1 && ca === 6'h0 && dq === 32'hzzzz_zzzz && trace_valid === 1'b0 &&
          hdone === 1'b0, "reset: CS_n high, CA 0, DQ released, no trace / hdone");
      dev_reset(); hq.delete(); done_q = 0; p_tv = 0; p_dqd = 0; f_left = 0; ref_exp = 0;
    end else begin
      if (f_left > 0) begin                                   // payload beat
        chk(cs_n === 1'b1, "CS_n low inside a frame");
        f_pay = f_pay | (18'(ca) << (6 * f_beat));
        f_beat++; f_left--;
        if (f_left == 0) frame_done();
      end else if (!cs_n) begin                               // beat 0
        f_code = ca[5:3]; f_bank = ca[2:0]; f_t0 = cyc; f_pay = 0; f_beat = 0; f_ta = p_ta;
        case (f_code)
          3'd1: begin
            chk(p_tv && p_tc == 3'd1 && bank_of(p_ta) == f_bank, "ACT without a matching trace");
            f_left = 3;
          end
          3'd2, 3'd3: begin
            chk(p_tv && p_tc == f_code && bank_of(p_ta) == f_bank, "RD / WR without a matching trace");
            if (f_code == 3'd3) begin
              f_wd = p_dq[16 * f_bank[2] +: 16];
              chk(p_dqd == (2'b01 << f_bank[2]) && f_wd == last_wdata,
                  $sformatf("WR data on DQ %h (halves %b), host wrote %h", p_dq, p_dqd, last_wdata));
            end
            f_left = 2;
          end
          3'd4: dev_pre(f_bank);
          3'd6: begin
            chk(f_bank == ref_exp, $sformatf("REFpb to bank %0d, round robin is at %0d", f_bank, ref_exp));
            ref_exp = (f_bank + 1) % NBK;
            dev_ref(f_bank);
          end
          default: fail($sformatf("illegal CA code %0d", f_code));
        endcase
      end else chk(ca === 6'h0, "CA not 0 between frames");
      if (p_tv && !(!cs_n && ca[5:3] == p_tc)) fail("trace not followed by its command");
      if (p_dqd != 0) chk(!cs_n && ca[5:3] == 3'd3, "DQ driven without a WR");
      p_dqd = {dq[31:16] !== 16'hzzzz, dq[15:0] !== 16'hzzzz};
      if (p_dqd != 0)    // one channel at a time, only for a write, never X
        chk(trace_valid && trace_cmd == 3'd3 && (p_dqd == 2'b01 || p_dqd == 2'b10) &&
            (^(p_dqd[0] ? dq[15:0] : dq[31:16])) !== 1'bx, "DQ driven outside a write");
      p_dq = dq; p_tv = trace_valid; p_tc = trace_cmd; p_ta = trace_addr;
    end
    dev_tick();
  end

  initial begin
    repeat (3) @(negedge clk);
    chk(hready === 1'b1 && hrdata === 16'h0, "reset: host ready, read data 0");
    rst_n = 1;

    // directed, both channels: ACT, WR, RD, a row conflict and PRE
    for (int ch = 0; ch < 2; ch++) begin
      host(3'd1, {14'h2A5C, 9'h0, 1'(ch), 8'h12}, 0);
      host(3'd3, {14'h2A5C, 9'h0, 1'(ch), 8'hC3}, 16'hBEE0 | 16'(ch));
      host(3'd2, {14'h2A5C, 9'h0, 1'(ch), 8'hC3}, 0);
      host(3'd2, {14'h1111, 9'h0, 1'(ch), 8'hC3}, 0);
      host(3'd4, {14'h1111, 9'h0, 1'(ch), 8'h00}, 0);
    end
    // MRW to MR7: set B (CL 22, tRCD 14), traffic, back to set A
    host(3'd3, 32'h0000_00F0, 16'h0001);
    for (int c = 0; c < 64; c++) host(3'd3, {14'h0005, 9'h1, 1'(c), 8'(c)}, 16'(c * 16'h0303));
    for (int c = 0; c < 64; c++) host(3'd2, {14'h0006, 9'h2, 1'(c), 8'(c)}, 0);
    host(3'd3, 32'h0000_00F0, 16'h0000);
    // every column of every channel
    for (int c = 0; c < 512; c++) host(3'd3, {14'h0001, 9'h0, 9'(c)}, 16'(c * 16'h0101 ^ 16'h5A00));
    for (int c = 0; c < 512; c++) host(3'd2, {14'h0002, 9'h3, 9'(c)}, 0);

    traffic(3000);

    // the array survives a controller reset; the frequency set returns to A
    drain();
    @(negedge clk) rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1; fset = 0;
    for (int c = 0; c < 512; c += 17) host(3'd2, {14'h0003, 9'h0, 9'(c)}, 0);
    traffic(500);
    report("LPDDR4_func");
  end

  initial begin
    #20ms;
    $display("TIMEOUT"); $finish;
  end
endmodule
