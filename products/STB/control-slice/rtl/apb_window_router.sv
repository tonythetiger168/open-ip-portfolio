// SPDX-License-Identifier: Apache-2.0
// Design prototype: two non-overlapping 4KB windows, one APB4 requester.
// Same PCLK/reset domain; not an AXI bridge, multi-manager fabric or firewall.
module apb_window_router #(
  parameter logic [19:0] PAGE0 = 20'h10000,
  parameter logic [19:0] PAGE1 = 20'h10001
) (
  input logic rst_n,
  input logic psel, penable, pwrite,
  input logic [31:0] paddr, pwdata,
  input logic [3:0] pstrb,
  input logic [2:0] pprot,
  output logic [31:0] prdata,
  output logic pready, pslverr,
  output logic [1:0] s_psel,
  output logic s_penable, s_pwrite,
  output logic [11:0] s_paddr,
  output logic [31:0] s_pwdata,
  output logic [3:0] s_pstrb,
  output logic [2:0] s_pprot,
  input logic [31:0] s0_prdata, s1_prdata,
  input logic s0_pready, s1_pready, s0_pslverr, s1_pslverr
);
  logic hit0, hit1, valid_decode;
  assign hit0 = paddr[31:12] == PAGE0;
  assign hit1 = paddr[31:12] == PAGE1;
  assign valid_decode = (hit0 ^ hit1) && paddr[1:0] == 2'b00;
  assign s_psel = rst_n && psel && valid_decode ? {hit1, hit0} : 2'b00;
  assign s_penable = rst_n && psel && valid_decode && penable;
  assign s_pwrite = pwrite;
  assign s_paddr = paddr[11:0];
  assign s_pwdata = pwdata;
  assign s_pstrb = pstrb;
  assign s_pprot = pprot;
  always_comb begin
    prdata = '0;
    pready = 1'b0;
    pslverr = 1'b0;
    if (rst_n && psel && penable) begin
      if (!valid_decode) begin
        pready = 1'b1;
        pslverr = 1'b1;
      end else if (hit0) begin
        prdata = s0_prdata;
        pready = s0_pready;
        pslverr = s0_pready && s0_pslverr;
      end else begin
        prdata = s1_prdata;
        pready = s1_pready;
        pslverr = s1_pready && s1_pslverr;
      end
    end
  end
endmodule
