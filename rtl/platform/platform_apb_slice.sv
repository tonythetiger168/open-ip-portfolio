// SPDX-License-Identifier: Apache-2.0
// Bounded platform fixture; NOT a TV/STB/IPCAM SoC top.
// APB4 requester -> two-window router -> two existing APB3 memory cores.
// The adapter rejects partial writes instead of silently dropping PSTRB.
module platform_apb_slice (
  input logic pclk, rst_n,
  input logic psel, penable, pwrite,
  input logic [31:0] paddr, pwdata,
  input logic [3:0] pstrb,
  input logic [2:0] pprot,
  output logic [31:0] prdata,
  output logic pready, pslverr,
  output logic [1:0] irq
);
  logic [1:0] sel;
  logic en, wr;
  logic [11:0] addr;
  logic [31:0] data, r0, r1, routed_data;
  logic ready0, ready1, err0, err1, routed_ready, routed_error;
  logic partial_write;
  assign partial_write = pwrite && pstrb != 4'hf;
  apb_window_router router (
    .rst_n(rst_n), .psel(psel && !partial_write), .penable(penable),
    .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
    .prdata(routed_data), .pready(routed_ready), .pslverr(routed_error),
    .s_psel(sel), .s_penable(en), .s_pwrite(wr), .s_paddr(addr),
    .s_pwdata(data), .s_pstrb(), .s_pprot(),
    .s0_prdata(r0), .s1_prdata(r1), .s0_pready(ready0), .s1_pready(ready1),
    .s0_pslverr(err0), .s1_pslverr(err1)
  );
  APB_top #(.DW(32), .AW(32), .DEPTH(256)) memory0 (
    .clk(pclk), .rst_n(rst_n), .psel(sel[0]), .penable(en),
    .paddr({20'b0,addr}), .pwrite(wr), .pwdata(data),
    .prdata(r0), .pready(ready0), .pslverr(err0), .irq(irq[0])
  );
  APB_top #(.DW(32), .AW(32), .DEPTH(256)) memory1 (
    .clk(pclk), .rst_n(rst_n), .psel(sel[1]), .penable(en),
    .paddr({20'b0,addr}), .pwrite(wr), .pwdata(data),
    .prdata(r1), .pready(ready1), .pslverr(err1), .irq(irq[1])
  );
  assign prdata = partial_write ? 32'b0 : routed_data;
  assign pready = rst_n && psel && penable && partial_write ? 1'b1 : routed_ready;
  assign pslverr = rst_n && psel && penable && partial_write ? 1'b1 : routed_error;
endmodule
