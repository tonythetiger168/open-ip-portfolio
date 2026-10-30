// SPDX-License-Identifier: Apache-2.0
// IO-Link-specific part of tb/IO_LINK_apb_tb.sv. A bare core P shares the
// C/Q line with the DUT (wired AND) in the other role, plus a UART BFM for
// frames P never sends (parity, checksum and gap errors). The DUT is first
// the master: wake-up, exchanges of every kind with the buffer read and
// written through MEM_ADDR / MEM_WDATA / CMD / MEM_RDATA, the largest reply,
// CKS flags and every master error. Then the DUT is the device: wake-up,
// exchanges with D_MSG checked against the core's reports, the page, and
// every device error. Every interrupt bit is masked, enabled and cleared.
logic [15:0] cb = 8;
logic        f_drv = 0, f_lvl = 1;
wire         p_txd, p_ten;
always @* rxd = (tx_en ? txd : 1'b1) & (p_ten ? p_txd : 1'b1) & (f_drv ? f_lvl : 1'b1);

// ---- partner P
logic        p_master = 0, p_start = 0, p_wurq = 0, p_ev = 0, p_pdinv = 0;
logic [1:0]  p_mtype = 0;
logic [5:0]  p_pdo = 0, p_pdi = 0, p_od = 1;
logic [7:0]  p_mc = 0;
logic        p_done, p_dwq, p_dmsg;
logic [7:0]  p_mmc, p_cks;
logic [2:0]  p_why;
logic        p_etmo, p_euart, p_ecks;
IO_LINK_top u_p (
  .clk(PCLK), .rst_n(PRESETN), .cfg_master(p_master), .cfg_bit(cb), .cfg_wurq(16'd400), .cfg_mtype(p_mtype),
  .cfg_pdout_len(p_pdo), .cfg_pdin_len(p_pdi), .cfg_od_len(p_od),
  .txd(p_txd), .tx_en(p_ten), .rxd(rxd),
  .host_rd(1'b0), .host_wr(1'b0), .host_addr(8'd0), .host_wdata(8'd0), .host_rdata(),
  .cfg_resp_timeout(8'd20), .m_wurq(p_wurq), .m_start(p_start), .m_mc(p_mc), .m_busy(),
  .m_done(p_done), .m_err_timeout(p_etmo), .m_err_uart(p_euart), .m_err_cks(p_ecks), .m_cks(p_cks), .m_cnt(),
  .cfg_ta(4'd2), .cfg_event(p_ev), .cfg_pd_invalid(p_pdinv),
  .d_wurq(p_dwq), .d_msg(p_dmsg), .d_msg_mc(p_mmc), .d_msg_why(p_why));
int n_pwq = 0, n_pmsg = 0;
always @(negedge PCLK) begin if (p_dwq) n_pwq++; if (p_dmsg) n_pmsg++; end

function automatic logic [5:0] csum6(input logic [7:0] x);
  return {x[7] ^ x[5] ^ x[3] ^ x[1], x[6] ^ x[4] ^ x[2] ^ x[0], x[7] ^ x[6], x[5] ^ x[4],
          x[3] ^ x[2], x[1] ^ x[0]};
endfunction

// ---- DUT reports, in order; D_MSG must give them back
logic [10:0] rq [$];
int n_rep = 0, n_x = 0;
always @(negedge PCLK)
  if (dut.u_core.d_msg) rq.push_back({dut.u_core.d_msg_why, dut.u_core.d_msg_mc});

task automatic irq_bit(input int b, input string what);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ %s not set", what));
  wr(A_IRQ_ENABLE, 0);
  @(negedge PCLK); if (irq !== 0) fail($sformatf("irq with IRQ_ENABLE = 0 (%s)", what));
  wr(A_IRQ_ENABLE, 32'd1 << b);
  @(negedge PCLK); if (irq !== 1) fail($sformatf("irq not raised by %s", what));
  wr(A_IRQ_STATUS, 32'd1 << b);
  wr(A_IRQ_ENABLE, 0);
  rd(A_IRQ_STATUS); if (rdv[b]) fail($sformatf("IRQ %s not cleared", what));
endtask

// ---- buffer through the registers
task automatic mem_wr(input logic [7:0] a, input logic [7:0] d);
  wr(A_MEM_ADDR, a); wr(A_MEM_WDATA, d); wr(A_CMD, 32'h4);
endtask
task automatic mem_exp(input logic [7:0] a, input logic [7:0] e, input string what);
  wr(A_MEM_ADDR, a); wr(A_CMD, 32'h8); rd(A_MEM_RDATA);
  if (rdv !== {24'd0, e}) fail($sformatf("%s: MEM[%h] = %h, expected %h", what, a, rdv, e));
endtask

// ---- configuration of both sides
task automatic cfg(input bit dut_master, input logic [1:0] ty, input int pdo, input int pdi, input int od,
                   input bit ev = 0, input bit pdinv = 0);
  wr(A_CTRL, {23'd0, pdinv, ev, 4'd2, ty, dut_master});
  wr(A_LENGTHS, {6'd0, 8'd20, 6'(od), 6'(pdi), 6'(pdo)});
  p_master = !dut_master; p_mtype = ty; p_pdo = 6'(pdo); p_pdi = 6'(pdi); p_od = 6'(od);
  p_ev = 0; p_pdinv = 0;
endtask

// ---- DUT as master: one request; returns M_STATUS in rdv
task automatic m_go(input logic [7:0] mc);
  wr(A_MC, mc); wr(A_CMD, 32'h1);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 100000);
  wr(A_IRQ_STATUS, 32'h1);
  rd(A_M_STATUS);
  n_x++;
endtask
task automatic m_xfer(input string what, input logic [7:0] mc, input int pdo, input int pdi, input int od);
  logic [7:0] v [0:63];
  logic [31:0] st;
  for (int k = 0; k < pdo; k++) begin v[k] = $urandom; mem_wr(8'(k), v[k]); end
  if (!mc[7]) for (int k = 0; k < od; k++) begin v[32 + k] = $urandom; mem_wr(8'(32 + k), v[32 + k]); end
  for (int k = 0; k < 32; k++) begin u_p.ram[8'(k)] = $urandom; u_p.ram[8'(32 + k)] = $urandom; u_p.ram[8'(128 + k)] = $urandom; end
  m_go(mc); st = rdv;
  if (st[3:0] !== 0 || st[18:12] !== 7'((mc[7] ? od : 0) + pdi + 1))
    fail($sformatf("%s: M_STATUS %h", what, st));
  for (int k = 0; k < pdo; k++) if (u_p.ram[8'(64 + k)] !== v[k]) fail($sformatf("%s: PD out %0d", what, k));
  if (!mc[7]) for (int k = 0; k < od; k++) if (u_p.ram[8'(96 + k)] !== v[32 + k]) fail($sformatf("%s: OD %0d", what, k));
  for (int k = 0; k < pdi; k++) mem_exp(8'(64 + k), u_p.ram[8'(k)], {what, " PD in"});
  if (mc[7]) for (int k = 0; k < od; k++)
    mem_exp(8'(96 + k), mc[6:5] == 2'd1 ? u_p.ram[8'(128 + ((mc[4:0] + k) % 32))] : u_p.ram[8'(32 + k)], {what, " OD"});
endtask

// ---- partner P as master
task automatic p_go(input logic [7:0] mc);
  int k;
  @(negedge PCLK) p_mc = mc; p_start = 1;
  @(negedge PCLK) p_start = 0;
  k = 0;
  while (!p_done && k < 200000) begin @(negedge PCLK); k++; end
  if (!p_done) fail("P: no m_done");
  cycles(4 * cb);
endtask
task automatic d_take(input logic [7:0] mc, input int why);
  logic [10:0] e;
  poll(A_FLAGS, 32'h1, 32'h1, 200);
  rd(A_D_MSG);
  e = rq.size() ? rq.pop_front() : 11'hx;
  if (rdv !== {21'd0, e}) fail($sformatf("D_MSG %h, expected %h", rdv, e));
  if (rdv[10:0] !== {3'(why), mc}) fail($sformatf("D_MSG %h: mc %h why %0d expected", rdv, mc, why));
  n_rep++;
endtask

// ---- UART BFM
task automatic f_bit(input logic b);
  f_drv = 1; f_lvl = b;
  repeat (cb) @(posedge PCLK);
endtask
task automatic f_oct(input logic [7:0] d, input bit perr = 0);
  f_bit(0);
  for (int i = 0; i < 8; i++) f_bit(d[i]);
  f_bit(^d ^ perr);
  f_bit(1);
  f_drv = 0;
endtask
task automatic f_gap(input int bits);
  f_drv = 0; repeat (bits * cb) @(posedge PCLK);
endtask
// a device reply after the DUT master's message
task automatic f_reply(input logic [7:0] d, input logic [1:0] st, input logic [5:0] ck_x, input bit perr);
  @(negedge PCLK); while (!tx_en) @(negedge PCLK);
  while (tx_en) @(negedge PCLK);
  f_gap(3);
  f_oct(d, perr);
  f_oct({st, csum6(8'h52 ^ d ^ {st, 6'd0}) ^ ck_x});
endtask

task automatic ip_func;
  logic [31:0] st;
  wr(A_TIMING, {16'd400, cb});
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ================= DUT as master, P as device
  cfg(1, 0, 0, 0, 1);
  cycles(50);
  wr(A_CMD, 32'h2);                                          // wake-up
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 1000);
  irq_bit(IRQ_M_DONE, "M_DONE");
  cycles(20);
  if (n_pwq != 1) fail("P did not see the wake-up");
  m_xfer("page read", 8'b1_01_10110, 0, 0, 1);
  m_xfer("page write", 8'b0_01_01001, 0, 0, 1);
  cfg(1, 2, 3, 2, 1);
  m_xfer("T2 read", 8'b1_00_00000, 3, 2, 1);
  m_xfer("T2 write", 8'b0_11_11111, 3, 2, 1);
  cfg(1, 1, 32, 32, 32);
  m_xfer("32 read", 8'b1_10_00001, 32, 32, 32);
  m_xfer("32 write", 8'b0_10_00001, 32, 32, 32);
  // CKS flags from P, all ones / zeros through the buffer
  cfg(1, 0, 0, 0, 1);
  p_ev = 1; p_pdinv = 1;
  m_go(8'hA0); st = rdv;
  if (st[11:10] !== 2'b11 || st[3:0] !== 0) fail($sformatf("CKS flags: M_STATUS %h", st));
  p_ev = 0; p_pdinv = 0;
  m_go(8'hA0); st = rdv;
  if (st[11:10] !== 2'b00) fail($sformatf("CKS flags off: M_STATUS %h", st));
  mem_wr(8'hFF, 8'hFF); mem_exp(8'hFF, 8'hFF, "ones");
  mem_wr(8'hFF, 8'h00); mem_exp(8'hFF, 8'h00, "zeros");
  // master errors: no reply, parity, checksum
  p_mtype = 3;
  m_go(8'hA0); if (rdv[3:0] !== 4'b0010 || rdv[18:12] !== 0) fail($sformatf("no reply: M_STATUS %h", rdv));
  fork m_go(8'hA0); f_reply(8'h3C, 2'b00, 0, 1); join
  if (rdv[3:0] !== 4'b0100) fail($sformatf("reply parity: M_STATUS %h", rdv));
  fork m_go(8'hA0); f_reply(8'hC3, 2'b10, 6'h3F, 0); join
  if (rdv[3:0] !== 4'b1000 || rdv[11:4] !== {2'b10, csum6(8'h52 ^ 8'hC3 ^ 8'h80) ^ 6'h3F})
    fail($sformatf("reply checksum: M_STATUS %h", rdv));
  p_mtype = 0;
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ================= DUT as device, P as master
  cfg(0, 2, 2, 3, 1, 1, 1);
  cycles(50);
  @(negedge PCLK) p_wurq = 1; @(negedge PCLK) p_wurq = 0;
  while (!p_done) @(negedge PCLK);
  cycles(20);
  irq_bit(IRQ_WURQ, "WURQ");
  for (int k = 0; k < 3; k++) mem_wr(8'(k), 8'(8'h5A + k));
  mem_wr(8'h20, 8'h77);
  for (int k = 0; k < 32; k++) mem_wr(8'(128 + k), 8'(k * 9));
  for (int k = 0; k < 32; k++) u_p.ram[8'(k)] = $urandom;
  u_p.ram[8'h20] = $urandom;
  p_go(8'h80);                                               // process read
  if (p_etmo || p_euart || p_ecks) fail("P: errors on process read");
  if (p_cks[7:6] !== 2'b11) fail("DUT CKS flags");
  for (int k = 0; k < 3; k++) if (u_p.ram[8'(64 + k)] !== 8'(8'h5A + k)) fail($sformatf("PD in %0d", k));
  if (u_p.ram[8'h60] !== 8'h77) fail("OD read");
  d_take(8'h80, 0);
  for (int k = 0; k < 2; k++) mem_exp(8'(64 + k), u_p.ram[8'(k)], "PD out");
  p_go(8'h3F);                                               // ISDU write
  d_take(8'h3F, 0);
  mem_exp(8'h60, u_p.ram[8'h20], "OD write");
  wr(A_CTRL, {23'd0, 2'b00, 4'd2, 2'd2, 1'b0});
  p_go(8'hBE);                                               // page read 30, wraps at 32
  if (p_cks[7:6] !== 2'b00 || u_p.ram[8'h60] !== 8'(30 * 9)) fail("page read");
  d_take(8'hBE, 0);
  // device errors
  p_mtype = 1; p_go(8'h80); d_take(8'h80, 3); p_mtype = 2;
  f_oct(8'h41); f_oct(8'h80, 1); f_gap(40); d_take(8'h41, 1);
  f_oct(8'h00); f_oct(8'h80); f_oct(8'h01); f_oct(8'h02); f_oct(8'h03); f_gap(40); d_take(8'h00, 2);
  f_oct(8'hFF); f_oct(8'h80); f_gap(20); d_take(8'hFF, 4);
  // a report waiting; D_MSG read on the clock the next one is captured
  p_go(8'h80);
  fork
    p_go(8'h81);
    begin
      @(negedge PCLK);
      while (!(dut.u_core.r_valid && dut.u_core.st == 3'd4 && dut.u_core.oi + 7'd1 == dut.u_core.d_n)) @(negedge PCLK);
      apb_now(0, A_D_MSG, 0, 0);
      if (rdv[7:0] !== 8'h80) fail($sformatf("D_MSG %h popped with the next capture", rdv));
      void'(rq.pop_front());
    end
  join
  d_take(8'h81, 0);
  // overflow: two reports, none read
  wr(A_IRQ_STATUS, IRQ_ALL);
  p_go(8'h82);
  p_go(8'h83);
  irq_bit(IRQ_D_MSG_OVF, "D_MSG_OVF");
  irq_bit(IRQ_D_MSG_AVAIL, "D_MSG_AVAIL");
  d_take(8'h82, 0);
  rd(A_D_MSG);                                               // empty: the old report
  rq.delete();
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, 32'h10);
  if (rq.size()) fail($sformatf("%0d reports not read", rq.size()));
  $display("IO_LINK_apb: %0d master requests, %0d device reports", n_x, n_rep);
endtask
