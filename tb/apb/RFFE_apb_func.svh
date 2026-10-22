// SPDX-License-Identifier: Apache-2.0
// RFFE-specific part of tb/RFFE_apb_tb.sv. A slave model on the bus (USID
// 9, 256 registers, the full command set, can corrupt the parity of read
// frames); SDATA is pulled low when nobody drives it.
// Covered through the registers: every command type through CMD, data
// bytes through WR (SCLK waiting for them), read bytes through RD with a
// parity error, a slave that is not there, CMD and WR written while full,
// RD overflowing and popped as it captures, the reserved type, every
// stream event and interrupt bit.
logic        s_drv = 0, s_dv = 0, s_corrupt = 0;
assign sdata_i = sdata_oe ? sdata_o : (s_drv && s_dv);
always @(negedge PCLK) if (PRESETN && sdata_oe && s_drv) fail("SDATA driven by both");

// ---------------- slave model ----------------
logic [7:0]  s_mem [0:255];
logic        s_sc = 0, s_sd = 0, s_arm = 0;
int          s_st = 0, s_n = 0, s_nleft = 0, s_ri = 0, s_err = 0;
logic [12:0] s_sh = 0;
logic [15:0] s_addr = 0;
bit          s_long = 0, s_rd = 0;
logic [8:0]  s_rf = 0;
initial for (int i = 0; i < 256; i++) s_mem[i] = 8'(i * 7 + 1);
function automatic int s_idx(input logic [15:0] a); return int'(a[7:0] ^ a[15:8]); endfunction
always @(posedge PCLK) if (!PRESETN) begin s_st = 0; s_drv <= 0; s_arm = 0; end
else begin : b_slave
  logic b0;
  b0 = sdata_i;
  if (!sclk && !s_sc && !s_drv) begin
    if (!s_sd && b0) s_arm = 1;
    if (s_sd && !b0 && s_arm) begin s_st = 1; s_n = 0; s_sh = 0; s_arm = 0; end
  end
  if (sclk) s_arm = 0;
  if (s_sc && !sclk) begin
    if (s_st == 1) begin
      s_sh = {s_sh[11:0], b0}; s_n++;
      if (s_n == 13) begin : b_c
        logic [7:0] c;
        c = s_sh[8:1]; s_n = 0; s_st = 0;
        if (!(^s_sh)) s_err++;
        else if (s_sh[12:9] == 9 || s_sh[12:9] == 0) begin
          s_long = 0; s_rd = 0;
          if (c[7]) s_mem[0] = {1'b0, c[6:0]};
          else if (c[7:5] == 3'b010) begin s_addr = c[4:0]; s_nleft = 0; s_st = 4; end
          else if (c[7:5] == 3'b011) begin s_addr = c[4:0]; s_nleft = 0; s_rd = 1; s_st = 5; end
          else if (c[7:5] == 3'b000) begin s_nleft = c[3:0]; s_st = 3; end
          else if (c[7:4] == 4'b0010) begin s_nleft = c[3:0]; s_rd = 1; s_st = 3; end
          else if (c[7:4] == 4'b0011) begin s_nleft = c[2:0]; s_rd = c[3]; s_long = 1; s_st = 2; end
        end
      end
    end else if (s_st >= 2 && s_st <= 4) begin
      s_sh = {s_sh[11:0], b0}; s_n++;
      if (s_n == 9) begin
        s_n = 0;
        if (!(^s_sh[8:0])) begin s_err++; s_st = 0; end
        else if (s_st == 2) begin s_addr[15:8] = s_sh[8:1]; s_st = 3; end
        else if (s_st == 3) begin s_addr[7:0] = s_sh[8:1]; if (!s_long) s_addr[15:8] = 0; s_st = s_rd ? 5 : 4; end
        else begin
          s_mem[s_idx(s_addr)] = s_sh[8:1];
          if (s_long) s_addr++; else s_addr[7:0]++;
          if (s_nleft == 0) s_st = 0;
          s_nleft--;
        end
      end
    end else if (s_st == 7) begin s_drv <= 0; s_st = 0; end
  end
  if (!s_sc && sclk) begin
    if (s_st == 5) begin s_st = 6; s_ri = 0; s_rf = {s_mem[s_idx(s_addr)], ~^s_mem[s_idx(s_addr)] ^ s_corrupt}; end
    else if (s_st == 6) begin
      s_drv <= 1;
      s_dv <= s_rf[8 - s_ri]; s_ri++;
      if (s_ri == 9) begin
        if (s_long) s_addr++; else s_addr[7:0]++;
        if (s_nleft == 0) s_st = 7;
        else begin s_nleft--; s_ri = 0; s_rf = {s_mem[s_idx(s_addr)], ~^s_mem[s_idx(s_addr)] ^ s_corrupt}; end
      end
    end else if (s_st == 7) s_dv <= 0;
  end
  s_sc = sclk; s_sd = b0;
end

// CMD word: type [2:0], sa [6:3], addr [22:7], bc [26:23]
function automatic logic [31:0] cmdw(input int ty, input int sa, input int a, input int bc);
  return 32'(ty) | (32'(sa) << 3) | (32'(a) << 7) | (32'(bc) << 23);
endfunction
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
task automatic seq_done;
  poll(A_STATUS, 1, 0, 50000);
endtask
task automatic h_wr(input logic [7:0] d);
  poll(A_FLAGS, 1 << FLAG_WR_FULL, 0, 50000);
  wr(A_WR, d);
endtask
task automatic h_rd(input logic [8:0] e);
  poll(A_FLAGS, 1 << FLAG_RD_AVAIL, 1 << FLAG_RD_AVAIL, 50000);
  rd(A_RD);
  if (rdv[8:0] !== e) fail($sformatf("RD %h, expected %h", rdv[8:0], e));
endtask
function automatic logic [8:0] exp_rd(input logic [15:0] a);
  return {s_corrupt, s_mem[s_idx(a)]};
endfunction

task automatic ip_func;
  logic [7:0] d [0:15];
  logic [8:0] e [0:15];
  wr(A_IRQ_ENABLE, 0);
  wr(A_CFG, 7);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // writes: register 0, register, extended (16 bytes), extended long (8 bytes)
  wr(A_CMD, cmdw(0, 9, 16'h0055, 0));
  seq_done();
  if (s_mem[0] !== 8'h55) fail("register 0 write");
  irq_expect(IRQ_SEQ_DONE);
  wr(A_CMD, cmdw(1, 9, 16'h001A, 0));
  h_wr(8'hA5);
  seq_done();
  if (s_mem[8'h1A] !== 8'hA5) fail("register write");
  for (int i = 0; i < 16; i++) d[i] = $urandom;
  d[3] = 8'hFF; d[4] = 8'h00;
  wr(A_CMD, cmdw(3, 9, 16'h00F8, 15));
  for (int i = 0; i < 16; i++) h_wr(d[i]);
  seq_done();
  for (int i = 0; i < 16; i++) if (s_mem[s_idx({8'h00, 8'(8'hF8 + i)})] !== d[i]) fail($sformatf("extended write byte %0d", i));
  wr(A_CMD, cmdw(5, 9, 16'hA5F0, 7));
  for (int i = 0; i < 8; i++) h_wr(d[i] ^ 8'h3C);
  seq_done();
  for (int i = 0; i < 8; i++) if (s_mem[s_idx(16'hA5F0 + 16'(i))] !== (d[i] ^ 8'h3C)) fail($sformatf("long write byte %0d", i));
  // WR written while full
  wr(A_CMD, cmdw(1, 9, 16'h0003, 0));
  wr(A_WR, 8'h11); wr(A_WR, 8'h22);
  irq_expect(IRQ_WR_OVF);
  seq_done();
  irq_expect(IRQ_WR_DONE);
  if (s_mem[3] !== 8'h11) fail("WR byte after an overflow");
  // reads: register, extended long, extended
  e[0] = exp_rd(16'h001A);
  wr(A_CMD, cmdw(2, 9, 16'h001A, 0));
  h_rd(e[0]);
  seq_done();
  for (int i = 0; i < 8; i++) e[i] = exp_rd(16'h1234 + 16'(i));
  wr(A_CMD, cmdw(6, 9, 16'h1234, 7));
  for (int i = 0; i < 8; i++) h_rd(e[i]);
  seq_done();
  // RD not read: the second byte overflows
  for (int i = 0; i < 3; i++) e[i] = exp_rd({8'h00, 8'(8'h10 + i)});
  wr(A_CMD, cmdw(4, 9, 16'h0010, 2));
  seq_done();
  irq_expect(IRQ_RD_OVF);
  h_rd(e[0]);
  // RD popped as it captures
  for (int i = 0; i < 2; i++) e[i] = exp_rd({8'h00, 8'(8'h20 + i)});
  wr(A_CMD, cmdw(4, 9, 16'h0020, 1));
  while (!(dut.u_core.st == dut.u_core.S_RX && dut.u_core.tick && dut.u_core.sclk && dut.u_core.nb == 4'd1 && dut.avail_RD))
    @(negedge PCLK);
  apb_now(0, A_RD, 0, 0);
  if (rdv[8:0] !== e[0]) fail($sformatf("RD %h at capture, expected %h", rdv[8:0], e[0]));
  h_rd(e[1]);
  seq_done();
  rd(A_RD);                                     // empty: the last byte again
  // a read parity error, and a slave that is not there
  s_corrupt = 1;
  e[0] = exp_rd(16'h0007);
  wr(A_CMD, cmdw(2, 9, 16'h0007, 0));
  h_rd(e[0]);
  seq_done();
  s_corrupt = 0;
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b10) fail($sformatf("STATUS %h after a parity error", rdv));
  wr(A_CMD, cmdw(2, 3, 16'h0007, 0));
  h_rd(9'h100);
  seq_done();
  // CMD written while full: the third command is dropped; the reserved type
  wr(A_CMD, cmdw(0, 9, 16'h0001, 0));
  wr(A_CMD, cmdw(0, 9, 16'h0002, 0));
  wr(A_CMD, cmdw(0, 9, 16'h0003, 0));
  irq_expect(IRQ_CMD_OVF);
  seq_done();
  poll(A_FLAGS, 1 << FLAG_CMD_FULL, 0, 50000);
  seq_done();
  if (s_mem[0] !== 8'h02) fail("register 0 after CMD overflow");
  wr(A_CMD, cmdw(7, 15, 16'hFFFF, 15));
  seq_done();
  irq_expect(IRQ_CMD_DONE);
  if (s_err != 0) fail("the slave model saw a parity error");

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[6:0] != 7'h7F) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 7; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[6:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  wr(A_CMD, cmdw(0, 9, 16'h0000, 0));
  poll(A_IRQ_STATUS, 1 << IRQ_SEQ_DONE, 1 << IRQ_SEQ_DONE, 50000);
  if (!irq) fail("irq low with SEQ_DONE pending");
endtask
