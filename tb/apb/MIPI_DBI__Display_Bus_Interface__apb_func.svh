// SPDX-License-Identifier: Apache-2.0
// MIPI DBI-specific part of tb/MIPI_DBI__Display_Bus_Interface__apb_tb.sv.
// A small display on the pins: Type B / Type A writes are logged at the
// strobe's end and checked against the ops; reads return a fresh value on
// d_i (Type A / B) or a random bit stream on sda_i (Type C) that RD must
// return. Covered through the registers: CFG for every type, commands,
// parameters and reads through OP / RD, OP held off while the core is busy
// (write while full), RD overflowing, RD popped in the clock it captures,
// STATUS while busy, every interrupt bit masked, raising irq and cleared.
logic [18:0] wq [0:255];                 // ops committed: {last, rd, dc, data}
int          wh = 0, wt = 0;
logic [15:0] rdq [0:255];                // values the display returned
int          rqh = 0, rqt = 0;
logic        q_wrx = 1, q_rdx = 1, q_scl = 0;
logic [7:0]  c_byte;
int          c_n = 0, c_w = 0;
logic [8:0]  c_sh;
initial begin d_i = 0; sda_i = 0; end

task automatic x_done(input bit rd, input logic [15:0] dat);
  logic [18:0] h;
  bit          w16;
  h = wq[wh % 256];
  w16 = dut.u_core.cfg_w16 && !dut.u_core.cfg_type[1];
  if (wh == wt) fail("transfer with no op");
  else begin
    if (h[17] != rd) fail($sformatf("transfer rd %0d, op %h", rd, h));
    if (!rd && dat !== (w16 ? h[15:0] : {8'd0, h[7:0]})) fail($sformatf("write %h, op %h", dat, h));
    wh++;
  end
endtask
always @(negedge PCLK) if (!PRESETN) begin
  q_wrx = 1; q_rdx = 1; q_scl = 0; c_n = 0; c_w = 0;
end else begin
  case (dut.u_core.cfg_type)
    2'd0: begin                          // Type A: wrx = R/WX, rdx = E
      if (rdx && !q_rdx && !csx && wrx) begin d_i = $urandom; rdq[rqt % 256] = dut.u_core.cfg_w16 ? d_i : {8'd0, d_i[7:0]}; rqt++; end
      if (!rdx && q_rdx && !csx) x_done(wrx, d_o);
    end
    2'd1: begin                          // Type B
      if (!rdx && q_rdx) begin d_i = $urandom; rdq[rqt % 256] = dut.u_core.cfg_w16 ? d_i : {8'd0, d_i[7:0]}; rqt++; end
      if (wrx && !q_wrx && !csx) x_done(0, d_o);
      if (rdx && !q_rdx && !csx) x_done(1, 0);
    end
    default: begin                       // Type C: random read bits
      if (!scl && q_scl) sda_i = $urandom;
      if (scl && !q_scl && !sda_oe && dut.u_core.dum == 0) begin
        c_byte = {c_byte[6:0], sda_i}; c_n++;
        if (c_n == 8) begin rdq[rqt % 256] = {8'd0, c_byte}; rqt++; c_n = 0; x_done(1, 0); end
      end
      if (scl && !q_scl && sda_oe) begin
        c_sh = {c_sh[7:0], sda_o}; c_w++;
        if (c_w == (dut.u_core.cfg_type == 2'd2 ? 9 : 8)) begin c_w = 0; x_done(0, {8'd0, c_sh[7:0]}); end
      end
    end
  endcase
  q_wrx = wrx; q_rdx = rdx; q_scl = scl;
end

// waits while OP is full (except where a test wants a write while full)
task automatic op_wr(input bit dc, input bit rdop, input bit last, input logic [15:0] d);
  while (dut.full_OP) @(negedge PCLK);
  wq[wt % 256] = {last, rdop, dc, d}; wt++;
  wr(A_OP, {13'd0, last, rdop, dc, d});
endtask
task automatic rd_check;
  poll(A_FLAGS, 1 << FLAG_RD_AVAIL, 1 << FLAG_RD_AVAIL, 2000);
  rd(A_RD);
  if (rqh == rqt) fail("RD with no read on the bus");
  else begin
    if (rdv[15:0] !== rdq[rqh % 256]) fail($sformatf("RD %h, expected %h", rdv[15:0], rdq[rqh % 256]));
    rqh++;
  end
endtask
task automatic idle_wait;
  int g;
  g = 0;
  while ((dut.u_core.busy || dut.full_OP) && g < 20000) begin @(negedge PCLK); g++; end
  if (g >= 20000) fail("controller did not go idle");
  cycles(3);
endtask
// cfg word: type [1:0], w16 [2], tw [6:3], tr [10:7], dummy [12:11]
function automatic logic [31:0] cfgw(input int ty, input bit w16, input int tw, input int tr, input int dum);
  return 32'(ty) | (32'(w16) << 2) | (32'(tw) << 3) | (32'(tr) << 7) | (32'(dum) << 11);
endfunction

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_STATUS, 0);
  // every type: a command, parameters, reads
  for (int t = 0; t < 4; t++) begin
    for (int w = 0; w < 2; w++) begin
      wr(A_CFG, cfgw(t, w, 1, 2, 1));
      op_wr(0, 0, 0, $urandom);
      op_wr(1, 0, 0, 16'hFFFF);
      op_wr(1, 0, 0, 16'h0000);
      op_wr(1, 0, 0, $urandom);
      op_wr(0, 0, 0, 16'h0004);
      op_wr(1, 1, 0, 0); rd_check();
      op_wr(1, 1, 1, 0); rd_check();
      idle_wait();
      if (wh != wt) fail($sformatf("type %0d: %0d transfers missing", t, wt - wh));
    end
  end
  // 16-bit reads with every data bit both ways
  wr(A_CFG, cfgw(1, 1, 0, 0, 0));
  for (int i = 0; i < 8; i++) begin op_wr(1, 1, i == 7, 0); rd_check(); end
  idle_wait();

  // OP while the core is busy: held (FULL), a third write is dropped
  wr(A_CFG, cfgw(1, 0, 15, 15, 0));
  op_wr(0, 0, 0, 16'h2C);
  cycles(2);
  op_wr(1, 0, 0, 16'h11);
  rd(A_FLAGS);
  if (!rdv[FLAG_OP_FULL]) fail("OP not full while the core is busy");
  rd(A_STATUS);
  if (rdv != 1) fail("STATUS not busy");
  wr(A_OP, 32'h1_0022);                        // dropped
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_OP_OVF]) fail("no OP_OVF");
  while (dut.full_OP) @(negedge PCLK);
  op_wr(1, 0, 1, 16'h33);
  idle_wait();

  // RD overflow: two reads, RD not read in between
  wr(A_CFG, cfgw(1, 1, 0, 0, 0));
  op_wr(0, 0, 0, 16'h0A);
  op_wr(1, 1, 0, 0);
  op_wr(1, 1, 1, 0);
  idle_wait();
  rd_check();                                  // the first read stays, the second is dropped
  rqh++;
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_RD_OVF]) fail("no RD_OVF");
  rd(A_RD);                                    // empty

  // RD popped in the clock it captures the next read
  wr(A_CFG, cfgw(1, 1, 3, 3, 0));
  op_wr(1, 1, 0, 0);
  op_wr(1, 1, 1, 0);
  while (!(dut.u_core.st == dut.u_core.S_ACT && dut.u_core.cnt == 0 && dut.u_core.o_rd && dut.avail_RD)) @(negedge PCLK);
  apb_now(0, A_RD, 0, 0);
  if (rdv[15:0] !== rdq[rqh % 256]) fail("RD at capture");
  rqh++;
  rd_check();
  idle_wait();

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[3:0] != 4'hF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 4; b++) begin
    wr(A_IRQ_STATUS, 1 << b);
    rd(A_IRQ_STATUS);
    if (rdv[3:0] != 4'(4'hF << (b + 1))) fail($sformatf("IRQ_STATUS %h after clearing bit %0d", rdv, b));
  end
  // leave one pending into the final reset
  op_wr(0, 0, 1, 16'h29);
  idle_wait();
  if (!irq) fail("irq low after OP_DONE");
endtask
