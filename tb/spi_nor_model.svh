// SPDX-License-Identifier: Apache-2.0
// spi_nor_model: behavioural quad-SPI NOR flash (SPI mode 0) for the QSPI_XIP
// testbenches. 64 KB array (the 24-bit address wraps at 64 KB).
// Commands: 0x03 read, 0x0B fast read (8 dummy clocks), 0x6B quad output
// fast read (8 dummy clocks, data on IO3..0), 0x05 read status ({WEL, WIP=0}),
// 0x06 write enable, 0x04 write disable, 0x02 page program (needs WEL; bits
// are ANDed in, the address wraps inside the 256-byte page), 0x20 4 KB sector
// erase (needs WEL), 0x9F JEDEC ID (EF 40 18). WEL clears at the end of a
// program or erase. Any other command is ignored until CS# rises.
// Checks (counted in `errors`): IO lines driven by the host while the flash
// drives them (an X sampled), a command byte that is X, a program or erase
// without WEL.
`ifndef SPI_NOR_MODEL_SVH
`define SPI_NOR_MODEL_SVH
module spi_nor_model (
  input  logic sclk,
  input  logic csn,
  inout  tri   [3:0] io
);
  logic [7:0] mem [0:65535];
  int         errors = 0;
  int         n_cmds = 0;
  logic       wel = 0;
  logic [7:0] cmd;
  logic [23:0] addr;
  int         nbit;          // rising edges since CS# fell
  logic [7:0] sh;
  logic [3:0] o;             // output value
  logic [3:0] oe;            // output enable per line
  logic [7:0] pp_byte;
  logic [15:0] a16;
  assign io[0] = oe[0] ? o[0] : 1'bz;
  assign io[1] = oe[1] ? o[1] : 1'bz;
  assign io[2] = oe[2] ? o[2] : 1'bz;
  assign io[3] = oe[3] ? o[3] : 1'bz;
  function automatic void bad(input string m);
    errors++;
    $display("ERROR: spi_nor: %s @%0t", m, $time);
  endfunction
  function automatic bit has_addr(input logic [7:0] c);
    return c == 8'h03 || c == 8'h0B || c == 8'h6B || c == 8'h02 || c == 8'h20;
  endfunction
  function automatic int dummy(input logic [7:0] c);
    return (c == 8'h0B || c == 8'h6B) ? 8 : 0;
  endfunction
  function automatic int data_start(input logic [7:0] c);   // first data rising edge
    return 8 + (has_addr(c) ? 24 : 0) + dummy(c);
  endfunction
  initial begin oe = 4'b0000; o = 4'b0000; end
  always @(negedge csn) begin
    nbit = 0; oe = 4'b0000; cmd = 8'h00; addr = '0;
  end
  always @(posedge csn) begin
    oe = 4'b0000;
    if (nbit >= 8) begin
      n_cmds++;
      if (cmd == 8'h06) wel = 1;
      if (cmd == 8'h04) wel = 0;
      if (cmd == 8'h20 && nbit >= 32) begin
        if (!wel) bad("sector erase without WEL");
        else for (int i = 0; i < 4096; i++) mem[{addr[15:12], 12'd0} + i] = 8'hFF;
        wel = 0;
      end
      if (cmd == 8'h02 && nbit > 32) wel = 0;
    end
  end
  always @(posedge sclk) if (!csn) begin
    if (nbit < 8) begin
      if (io[0] === 1'bx || io[0] === 1'bz) bad("command bit not driven");
      cmd = {cmd[6:0], io[0]};
    end else if (has_addr(cmd) && nbit < 32) begin
      addr = {addr[22:0], io[0]};
    end else if (cmd == 8'h02 && nbit >= 32) begin
      pp_byte = {pp_byte[6:0], io[0]};
      if ((nbit - 32) % 8 == 7) begin
        if (!wel) bad("page program without WEL");
        else begin a16 = addr[15:0]; mem[a16] = mem[a16] & pp_byte; end
        addr[7:0] = addr[7:0] + 8'd1;                // wraps inside the page
      end
    end
    // the host must not drive the lines the flash drives
    if (|oe && ((oe[1] && io[1] !== o[1]) || (oe[0] && io[0] !== o[0]) || (oe[2] && io[2] !== o[2]) || (oe[3] && io[3] !== o[3])))
      bad($sformatf("IO contention: flash drives %b on %b, line is %b", o, oe, io));
    nbit++;
  end
  // outputs change on the falling edge before the rising edge that samples them
  always @(negedge sclk) if (!csn && nbit >= 8) begin
    int k;
    k = nbit - data_start(cmd);                      // data bits / clocks already sampled
    if (k >= 0) begin
      case (cmd)
        8'h03, 8'h0B: begin
          a16 = addr[15:0] + 16'(k / 8);
          oe = 4'b0010; o[1] = mem[a16][7 - k % 8];
        end
        8'h6B: begin
          a16 = addr[15:0] + 16'(k / 2);
          oe = 4'b1111; o = (k % 2 == 0) ? mem[a16][7:4] : mem[a16][3:0];
        end
        8'h05: begin oe = 4'b0010; o[1] = (k % 8 == 6) ? wel : 1'b0; end
        8'h9F: begin
          logic [23:0] id;
          id = 24'hEF4018;
          oe = 4'b0010; o[1] = (k < 24) ? id[23 - k] : 1'b0;
        end
        default: oe = 4'b0000;
      endcase
    end
  end
endmodule
`endif
