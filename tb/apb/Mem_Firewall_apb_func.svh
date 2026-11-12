// SPDX-License-Identifier: Apache-2.0
// Mem_Firewall-specific part of tb/Mem_Firewall_apb_tb.sv. A TB initiator
// drives the AXI4 subordinate pins s_*; an soc_ss_axi_mem subordinate sits on
// the AXI4 manager pins m_*. Covered through the registers: CTRL.enable 0
// (everything passes), regions with read-only, write and secure-only
// permissions, an access outside every region, a burst straddling a region
// limit, DECERR responses (writes never reach memory, reads return zero),
// FAULT_INFO / FAULT_ADDR hold the first fault until CMD.fault_clr, DENIED,
// the FAULT interrupt.
// Coverage closure: a field sweep through a region that grants everything
// (IDs, narrow sizes, FIXED / WRAP bursts, AxPROT, byte strobes, a 256-beat
// burst, addresses across 0x7FFF_FFFC..0x8000_0000), SLVERR passed through, an
// interrupt left pending for the reset that follows, FLAGS read.
`include "apb/tv_apb_common.svh"

initial begin
  s_awid = 0; s_arid = 0; s_awaddr = 0; s_araddr = 0; s_wdata = 0; s_awlen = 0; s_arlen = 0;
  s_awsize = 2; s_arsize = 2; s_awprot = 0; s_arprot = 0; s_awburst = 1; s_arburst = 1;
  s_awvalid = 0; s_wvalid = 0; s_wlast = 0; s_bready = 0; s_arvalid = 0; s_rready = 0; s_wstrb = 4'hF;
end
// burst fields of the next fw_wr / fw_rd (defaults: 4-byte INCR, all
// strobes, data a ^ beat ^ 0x5A5A_0000, AxPROT {0, ns, 0}, IDs 3 / 5)
logic [2:0] fw_size = 3'd2;
logic [1:0] fw_burst = 2'b01;
logic [2:0] fw_prot = 3'b000;                         // bits 2 and 0 of AxPROT
logic [3:0] fw_strb = 4'hF, fw_wid = 4'h3, fw_rid = 4'h5;
bit         fw_rnd = 0;                               // random write data
// one write burst of len + 1 beats; returns BRESP
task automatic fw_wr(input logic [31:0] a, input int len, input bit ns, input logic [3:0] id, output logic [1:0] resp);
  @(negedge PCLK);
  s_awaddr = a; s_awlen = 8'(len); s_awprot = {fw_prot[2], ns, fw_prot[0]}; s_awid = id; s_awvalid = 1;
  s_awsize = fw_size; s_awburst = fw_burst;
  @(posedge PCLK); while (!s_awready) @(posedge PCLK);
  @(negedge PCLK); s_awvalid = 0;
  for (int i = 0; i <= len; i++) begin
    s_wdata = fw_rnd ? $urandom : a ^ 32'(i) ^ 32'h5A5A_0000; s_wstrb = fw_strb; s_wlast = (i == len); s_wvalid = 1;
    @(posedge PCLK); while (!s_wready) @(posedge PCLK);
    @(negedge PCLK); s_wvalid = 0; s_wlast = 0;
  end
  s_bready = 1;
  @(posedge PCLK); while (!s_bvalid) @(posedge PCLK);
  resp = s_bresp;
  if (s_bid !== id) fail("BID");
  @(negedge PCLK); s_bready = 0;
endtask
// one read burst; returns the last RRESP and checks the data (memory or zero)
task automatic fw_rd(input logic [31:0] a, input int len, input bit ns, input logic [3:0] id, output logic [1:0] resp);
  @(negedge PCLK);
  s_araddr = a; s_arlen = 8'(len); s_arprot = {fw_prot[2], ns, fw_prot[0]}; s_arid = id; s_arvalid = 1;
  s_arsize = fw_size; s_arburst = fw_burst;
  @(posedge PCLK); while (!s_arready) @(posedge PCLK);
  @(negedge PCLK); s_arvalid = 0; s_rready = 1;
  for (int i = 0; i <= len; i++) begin
    @(posedge PCLK); while (!s_rvalid) @(posedge PCLK);
    resp = s_rresp;
    if (s_rid !== id) fail("RID");
    if (s_rlast !== (i == len)) fail("RLAST");
    if (s_rresp == 2'b00 && s_rdata !== mem.peek(a + 32'(4 * i))) fail($sformatf("read %h beat %0d data", a, i));
    if (s_rresp == 2'b11 && s_rdata !== 0) fail("denied read data not zero");
  end
  @(negedge PCLK); s_rready = 0;
endtask
task automatic fw_expect_w(input logic [31:0] a, input int len, input bit ns, input logic [1:0] e, input string what);
  logic [1:0] r;
  int nb0;
  nb0 = mem.n_wr_bursts;
  fw_wr(a, len, ns, fw_wid, r);
  if (r !== e) fail($sformatf("%s: BRESP %b, expected %b", what, r, e));
  if (e == 2'b11 && mem.n_wr_bursts != nb0) fail({what, ": a denied write reached memory"});
  if (e == 2'b00 && !fw_rnd && mem.peek(a) !== (a ^ 32'h5A5A_0000)) fail({what, ": write not in memory"});
endtask
task automatic fw_expect_r(input logic [31:0] a, input int len, input bit ns, input logic [1:0] e, input string what);
  logic [1:0] r;
  fw_rd(a, len, ns, fw_rid, r);
  if (r !== e) fail($sformatf("%s: RRESP %b, expected %b", what, r, e));
endtask

task automatic ip_func;
  // disabled: everything passes
  fw_expect_w(32'h9000_0000, 3, 1, 2'b00, "disabled write");
  fw_expect_r(32'h9000_0000, 3, 1, 2'b00, "disabled read");
  // region 0: 0x1000_0000..0x1000_0FFF read only; region 1: 0x2000_0000..0x2000_FFFF
  // read / write; region 2: 0x3000_0000..0x3000_03FF secure-only read / write
  wr(A_RGN0_BASE, 32'h1000_0000); wr(A_RGN0_LIMIT, 32'h1000_0FFF); wr(A_RGN0_ATTR, 4'b0011);
  wr(A_RGN1_BASE, 32'h2000_0000); wr(A_RGN1_LIMIT, 32'h2000_FFFF); wr(A_RGN1_ATTR, 4'b0111);
  wr(A_RGN2_BASE, 32'h3000_0000); wr(A_RGN2_LIMIT, 32'h3000_03FF); wr(A_RGN2_ATTR, 4'b1111);
  wr(A_RGN3_ATTR, 0);
  wr(A_CTRL, 1);
  for (int i = 0; i < 8; i++) mem.poke(32'h1000_0100 + 32'(4 * i), $urandom);
  fw_expect_r(32'h1000_0100, 7, 1, 2'b00, "read-only region read");
  tv_no_irq(IRQ_FAULT, "allowed read");
  fw_expect_w(32'h1000_0100, 1, 1, 2'b11, "read-only region write");
  rd(A_FAULT_INFO);
  if (rdv[7:0] !== {4'h3, 1'b1, 1'b1, 1'b1, 1'b1}) fail($sformatf("FAULT_INFO %h", rdv));
  rd_exp(A_FAULT_ADDR, 32'h1000_0100);
  tv_irq(IRQ_FAULT, "write to a read-only region");
  // a second fault does not replace the held one
  fw_expect_r(32'h4000_0000, 0, 1, 2'b11, "no region");
  rd_exp(A_FAULT_ADDR, 32'h1000_0100);
  wr(A_CMD, 1);
  rd_exp(A_FAULT_INFO, 0);
  fw_expect_w(32'h2000_0040, 15, 1, 2'b00, "read / write region");
  fw_expect_w(32'h2000_FFF8, 3, 1, 2'b11, "burst past the region limit");
  rd_exp(A_FAULT_ADDR, 32'h2000_FFF8);
  wr(A_CMD, 1);
  // secure-only region: AxPROT[1] = 1 (non-secure) denied, 0 allowed
  fw_expect_w(32'h3000_0010, 0, 1, 2'b11, "non-secure write to a secure region");
  rd(A_FAULT_INFO);
  if (rdv[3:0] !== 4'b1111) fail($sformatf("FAULT_INFO %h for a non-secure access", rdv));
  wr(A_CMD, 1);
  fw_expect_w(32'h3000_0010, 0, 0, 2'b00, "secure write to a secure region");
  fw_expect_r(32'h3000_0010, 0, 0, 2'b00, "secure read of a secure region");
  rd_exp(A_DENIED, 4);
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // field sweep through region 3, which grants everything: IDs, narrow
  // sizes, FIXED / WRAP bursts, AxPROT, byte strobes, a 256-beat burst,
  // random data and addresses that flip every bit pass through unchanged
  // (the test memory takes any burst here)
  mem.any_burst = 1; fw_rnd = 1;
  wr(A_RGN3_BASE, 0); wr(A_RGN3_LIMIT, 32'hFFFF_FFFF); wr(A_RGN3_ATTR, 4'b0111);
  for (int k = 0; k < 5; k++) begin
    logic [31:0] a;
    int len;
    case (k)
      0: begin a = 32'h7FFF_FFFC; len = 0;   fw_size = 2; fw_burst = 2'b01; fw_prot = 3'b101; fw_strb = 4'b0101; fw_wid = 4'hF; end
      1: begin a = 32'h8000_0000; len = 255; fw_size = 2; fw_burst = 2'b01; fw_prot = 3'b000; fw_strb = 4'hF;    fw_wid = 4'h0; end
      2: begin a = 32'h0000_0003; len = 3;   fw_size = 0; fw_burst = 2'b00; fw_prot = 3'b101; fw_strb = 4'b1000; fw_wid = 4'hA; end
      3: begin a = 32'h0000_0002; len = 3;   fw_size = 1; fw_burst = 2'b10; fw_prot = 3'b000; fw_strb = 4'b1100; fw_wid = 4'h5; end
      default: begin a = 32'h0000_1000; len = 1; fw_size = 2; fw_burst = 2'b01; fw_strb = 4'hF; fw_wid = 4'h3; end
    endcase
    fw_rid = ~fw_wid;
    fw_expect_w(a, len, k[0], 2'b00, $sformatf("sweep write %0d", k));
    fw_expect_r(a, len, k[0], 2'b00, $sformatf("sweep read %0d", k));
    if (s_awaddr !== a || m_awaddr !== a || m_awlen !== 8'(len) || m_awsize !== fw_size || m_awburst !== fw_burst || m_awid !== fw_wid)
      fail($sformatf("sweep %0d: AW not passed through unchanged", k));
    if (m_araddr !== a || m_arlen !== 8'(len) || m_arsize !== fw_size || m_arburst !== fw_burst || m_arid !== fw_rid
        || m_arprot !== {fw_prot[2], k[0], fw_prot[0]})
      fail($sformatf("sweep %0d: AR not passed through unchanged", k));
  end
  // SLVERR from the memory passes through, then OKAY again
  mem.err_lo = 32'h0000_2000; mem.err_hi = mem.err_lo + 4;
  fw_expect_w(32'h0000_2000, 0, 1, 2'b10, "SLVERR write");
  fw_expect_r(32'h0000_2000, 0, 1, 2'b10, "SLVERR read");
  mem.err_lo = '1; mem.err_hi = '1;
  fw_expect_w(32'h0000_2010, 0, 1, 2'b00, "write after SLVERR");
  fw_expect_r(32'h0000_2010, 0, 1, 2'b00, "read after SLVERR");
  rd_exp(A_DENIED, 4);
  tv_no_irq(IRQ_FAULT, "region 3 sweep");
  // faults recorded with ID 12 at 0xCFFF_0007 (a byte), then ID 3 at 0; the
  // second FAULT is left pending for the reset that follows
  wr(A_RGN3_ATTR, 0);
  fw_size = 0; fw_wid = 4'hC;
  fw_expect_w(32'hCFFF_0007, 0, 1, 2'b11, "byte write outside every region");
  rd(A_FAULT_INFO);
  if (rdv[7:0] !== {4'hC, 1'b1, 1'b1, 1'b1, 1'b1}) fail($sformatf("FAULT_INFO %h", rdv));
  rd_exp(A_FAULT_ADDR, 32'hCFFF_0007);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD, 1);
  fw_size = 2; fw_wid = 4'h3;
  fw_expect_w(32'h0000_0000, 0, 1, 2'b11, "write outside every region");
  rd_exp(A_FAULT_ADDR, 32'h0000_0000);
  rd_exp(A_DENIED, 6);
  tv_irq_pin(IRQ_FAULT, "write outside every region");   // left pending for the reset
  mem.any_burst = 0;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
