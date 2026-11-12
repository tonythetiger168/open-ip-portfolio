// SPDX-License-Identifier: Apache-2.0
// Real router + two real catalog wrappers/cores. No modeled DUT endpoint.
`timescale 1ns/1ps
module control_slice_tb;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0, psel=0, penable=0, pwrite=0;
  logic [31:0] paddr=0, pwdata=0;
  logic [3:0] pstrb=0;
  logic [2:0] pprot=0;
  wire [31:0] prdata;
  wire pready, pslverr;
  wire [1:0] s_psel;
  wire s_penable, s_pwrite;
  wire [11:0] s_paddr;
  wire [31:0] s_pwdata;
  wire [3:0] s_pstrb;
  wire [2:0] s_pprot;
  wire [31:0] d0,d1;
  wire r0,r1,e0,e1,irq0,irq1;
`ifdef OVERLAP
  localparam logic [19:0] PAGE1=20'h10000;
`else
  localparam logic [19:0] PAGE1=20'h10001;
`endif
  apb_window_router #(.PAGE0(20'h10000),.PAGE1(PAGE1)) u_router (
    .rst_n,.psel,.penable,.pwrite,.paddr,.pwdata,.pstrb,.pprot,
    .prdata,.pready,.pslverr,.s_psel,.s_penable,.s_pwrite,.s_paddr,.s_pwdata,.s_pstrb,.s_pprot,
    .s0_prdata(d0),.s1_prdata(d1),.s0_pready(r0),.s1_pready(r1),.s0_pslverr(e0),.s1_pslverr(e1));
  // AXI initiators intentionally idle. This slice checks APB CSRs only.
  AXI4_Lite_apb u_reg0 (
    .PCLK(clk),.PRESETN(rst_n),.PSEL(s_psel[0]),.PENABLE(s_penable),.PWRITE(s_pwrite),
    .PADDR(s_paddr),.PWDATA(s_pwdata),.PSTRB(s_pstrb),.PRDATA(d0),.PREADY(r0),.PSLVERR(e0),.irq(irq0),
    .awaddr(32'd0),.awvalid(1'b0),.awready(),.wdata(32'd0),.wstrb(4'd0),.wvalid(1'b0),.wready(),
    .bresp(),.bvalid(),.bready(1'b1),.araddr(32'd0),.arvalid(1'b0),.arready(),
    .rdata(),.rresp(),.rvalid(),.rready(1'b1));
  AXI4_Lite_apb u_reg1 (
    .PCLK(clk),.PRESETN(rst_n),.PSEL(s_psel[1]),.PENABLE(s_penable),.PWRITE(s_pwrite),
    .PADDR(s_paddr),.PWDATA(s_pwdata),.PSTRB(s_pstrb),.PRDATA(d1),.PREADY(r1),.PSLVERR(e1),.irq(irq1),
    .awaddr(32'd0),.awvalid(1'b0),.awready(),.wdata(32'd0),.wstrb(4'd0),.wvalid(1'b0),.wready(),
    .bresp(),.bvalid(),.bready(1'b1),.araddr(32'd0),.arvalid(1'b0),.arready(),
    .rdata(),.rresp(),.rvalid(),.rready(1'b1));
  integer input_fd, trace_fd, n, cycle=0;
  bit monitor_active=0;
  string stimulus_path, trace_path;
  // Passive sampling at the accepting edge, before NBA changes register state.
  // Expected data never enters this monitor or the stimulus file.
  always @(posedge clk) if (monitor_active) begin
    $fwrite(trace_fd,"%0d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
      cycle,rst_n,psel,penable,pwrite,paddr,pwdata,pstrb,pprot,
      s_psel,s_penable,s_pwrite,s_paddr,s_pwdata,s_pstrb,s_pprot,prdata,pready,pslverr,{irq1,irq0});
    cycle=cycle+1;
  end
  initial begin
    if (!$value$plusargs("stim=%s",stimulus_path) || !$value$plusargs("trace=%s",trace_path))
      $fatal(1,"stim/trace paths required");
    input_fd=$fopen(stimulus_path,"r"); trace_fd=$fopen(trace_path,"w");
    if (input_fd == 0 || trace_fd == 0) $fatal(1,"file open failed");
    @(negedge clk);
    while (!$feof(input_fd)) begin
      n=$fscanf(input_fd,"%h %h %h %h %h %h %h %h\n",rst_n,psel,penable,pwrite,paddr,pwdata,pstrb,pprot);
      if (n!=8) $fatal(1,"malformed stimulus");
      monitor_active=1;
      @(posedge clk); #1;
      @(negedge clk);
    end
    monitor_active=0;
    $fclose(input_fd); $fclose(trace_fd);
    $display("SLICE_SIM_DONE cycles=%0d",cycle);
    $finish;
  end
  initial begin #1000000; $fatal(1,"timeout"); end
endmodule
