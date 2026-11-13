// SPDX-License-Identifier: Apache-2.0
// Real AXI4_Lite_apb/core. Error IRQ comes from actual accepted AXI faults.
`timescale 1ns/1ps
module endpoint_memory_tb;
  logic clk=0;
  always #5 clk=~clk;
  logic rst=0,sel=0,en=0,wr=0;
  logic [11:0] addr=0;
  logic [31:0] data=0;
  logic [3:0] strb=0;
  logic [31:0] awaddr=0,wd=0,araddr=0;
  logic av=0,wv=0,br=0,rv=0,rr=0;
  logic [3:0] ws=0;
  wire [31:0] rd,rdata;
  wire ready,error,irq,awready,wready,bvalid,arready,rvalid;
  wire [1:0] bresp,rresp;
  AXI4_Lite_apb u_ep (
    .PCLK(clk),.PRESETN(rst),.PSEL(sel),.PENABLE(en),.PWRITE(wr),.PADDR(addr),.PWDATA(data),.PSTRB(strb),
    .PRDATA(rd),.PREADY(ready),.PSLVERR(error),.irq,
    .awaddr,.awvalid(av),.awready,.wdata(wd),.wstrb(ws),.wvalid(wv),.wready,.bresp,.bvalid,.bready(br),
    .araddr,.arvalid(rv),.arready,.rdata,.rresp,.rvalid,.rready(rr));
`ifdef STB_MEMORY_NATIVE
  memory_contract contract_checks(.clk,.rst,.sel,.en,.wr,.ready,.addr,.strb,
    .awaddr,.wd,.araddr,.rdata,.ws,.av,.wv,.br,.rv,.rr,.awready,.wready,.bvalid,.arready,.rvalid,.bresp,.rresp);
`endif
  integer inf,outf,n,cycle=0;
  bit active=0;
  string stim,trace;
  always @(posedge clk) if(active) begin
    // RDATA is unspecified outside RVALID and before memory initialization.
    $fwrite(outf,"%0d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
      cycle,rst,sel,en,wr,addr,data,strb,awaddr,av,wd,ws,wv,br,araddr,rv,rr,
      rd,ready,error,irq,u_ep.c_irq,awready,wready,bvalid,bresp,arready,rvalid,rresp,(rvalid?rdata:32'd0));
    cycle=cycle+1;
  end
  initial begin
    if(!$value$plusargs("stim=%s",stim)||!$value$plusargs("trace=%s",trace)) $fatal(1,"paths required");
    inf=$fopen(stim,"r");outf=$fopen(trace,"w");
    if(inf==0||outf==0) $fatal(1,"file open");
    @(negedge clk);
    while(!$feof(inf)) begin
      n=$fscanf(inf,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
        rst,sel,en,wr,addr,data,strb,awaddr,av,wd,ws,wv,br,araddr,rv,rr);
      if(n!=16) $fatal(1,"malformed IRQ stimulus");
      active=1;@(posedge clk);#1;@(negedge clk);
    end
    active=0;$fclose(inf);$fclose(outf);$display("IRQ_WAIT_DONE cycles=%0d",cycle);$finish;
  end
  initial begin #1000000;$fatal(1,"timeout");end
endmodule
