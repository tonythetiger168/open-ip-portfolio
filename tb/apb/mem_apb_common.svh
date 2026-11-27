// SPDX-License-Identifier: Apache-2.0
// Shared APB tests of the word-level memory controllers (DDR / LPDDR / GDDR /
// HBM families), included by tb/apb/<P>_apb_func.svh after the IP part,
// which provides NBU (bank entries), function mk(b, row, col) (host address)
// and function cellof(a) (storage word of a host address). Register map:
// CMD = {hcmd, haddr, hwdata} (writing CMD2 sends it), RDATA = hrdata,
// IRQ RD_DONE = hdone. Host contract: hcmd 1 ACT, 2 RD, 3 WR, 4 PRE (other
// codes are no-ops), taken when the core is ready; RD_DONE once per RD and
// RDATA holds the word from the next clock.
// Covered: every command through the registers, read data against a
// scoreboard (every RDATA bit both ways), every haddr / hwdata bit, every
// bank entry and so every channel's dq lanes both ways, CMD held
// while the core is busy and dropped when full, every interrupt bit set,
// masked, enabled onto irq and cleared.
// A controller that keeps no array of its own gets the DRAM device model
// tb/mem_dev.svh, included here when the IP part defines its `MEM_DEV_* hooks.
// `MEM_LINE (cores with line commands and an MR file, register RLINE0..3 =
// rdline, IRQ DONE = hdone): also RDL / WRL (through CMD: the command, then
// its 8 data beats) on every bank entry with every RLINE bit both ways, and
// MRW / MRR.
`ifdef MEM_DEV_RD
`define MEM_DEV_CLK PCLK
`include "mem_dev.svh"
`endif
logic [15:0] m_sb [0:65535];
initial for (int i = 0; i < 65536; i++) m_sb[i] = 16'h0;     // the array starts zeroed
localparam logic [31:0] M_FULL = 32'h1 << FLAG_CMD_FULL;
localparam logic [31:0] M_RDD  = 32'h1 << IRQ_RD_DONE;
int m_nrd = 0, m_ndone = 0;            // READs the core took / finished (hdone)
always @(posedge PCLK) begin
  if (dut.u_core.hvalid && dut.u_core.hready && (dut.u_core.hcmd == 3'd2
`ifdef MEM_LINE
      || dut.u_core.dstate == 0 && (dut.u_core.hcmd == 3'd5 || dut.u_core.hcmd == 3'd7 && dut.u_core.haddr[3])
`endif
     )) m_nrd <= m_nrd + 1;
  if (dut.u_core.hdone) m_ndone <= m_ndone + 1;
end

task automatic m_send(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
  poll(A_FLAGS, M_FULL, 0, 2000);
  wr(A_CMD0, {29'h0, c});
  wr(A_CMD1, a);
  wr(A_CMD2, {16'h0, d});
endtask
task automatic m_wr(input logic [31:0] a, input logic [15:0] d);
  m_send(3'd3, a, d);
  m_sb[cellof(a)] = d;
endtask
task automatic m_rd(input logic [31:0] a);
  wr(A_IRQ_STATUS, M_RDD);
  m_send(3'd2, a, $urandom);
  poll(A_IRQ_STATUS, M_RDD, M_RDD, 4000);
  rd_exp(A_RDATA, {16'h0, m_sb[cellof(a)]});
endtask
function automatic logic [31:0] m_addr;
  m_addr = mk($urandom_range(0, NBU - 1), 14'($urandom), 8'($urandom));
endfunction

`ifdef MEM_LINE
`ifndef MEM_LCELL
`define MEM_LCELL(a, k) ((cellof(a) & ~7) | (k))
`endif
task automatic m_wrl(input logic [31:0] a, input logic [127:0] d);
  m_send(3'd6, a, $urandom);
  for (int i = 0; i < 8; i++) begin
    poll(A_FLAGS, M_FULL, 0, 2000);              // the command / last beat taken
    wr(A_CMD2, {16'h0, d[16*i +: 16]});          // data beats
    m_sb[`MEM_LCELL(a, i) % 65536] = d[16*i +: 16];
  end
endtask
task automatic m_rdl(input logic [31:0] a);
  logic [127:0] e;
  for (int i = 0; i < 8; i++) e[16*i +: 16] = m_sb[`MEM_LCELL(a, i) % 65536];
  wr(A_IRQ_STATUS, M_RDD);
  m_send(3'd5, a, $urandom);
  poll(A_IRQ_STATUS, M_RDD, M_RDD, 4000);
  rd_exp(A_RLINE0, e[31:0]); rd_exp(A_RLINE1, e[63:32]);
  rd_exp(A_RLINE2, e[95:64]); rd_exp(A_RLINE3, e[127:96]);
  rd_exp(A_RDATA, {16'h0, e[127:112]});
endtask
task automatic m_mr(input int i, input logic [7:0] v);
  m_send(3'd7, {28'h0, 1'b0, 3'(i)}, {8'($urandom), v});          // MRW
  wr(A_IRQ_STATUS, M_RDD);
  m_send(3'd7, {28'($urandom), 1'b1, 3'(i)}, $urandom);           // MRR
  poll(A_IRQ_STATUS, M_RDD, M_RDD, 4000);
  rd_exp(A_RDATA, {24'h0, (i == 0) ? {1'b0, v[6:0]} : v});
endtask
`ifndef MEM_APB_MR0
`define MEM_APB_MR0 8'(CL - 5)
`endif
task automatic line_func;
  logic [31:0] a;
  for (int b = 0; b < NBU; b++) begin
    a = mk(b, 14'(b), 8'h40);
    m_wrl(a, {4{32'hFFFF_FFFF}}); m_rdl(a);
    m_wrl(a, '0); m_rdl(a);
    m_wrl(a, {4{32'hA5A5_5A5A}}); m_rdl(a);
    m_wrl(mk(b, 14'h3FFF, 8'h48), {$urandom, $urandom, $urandom, $urandom});
    m_rdl(a);
  end
  for (int i = 0; i < 8; i++) begin m_mr(i, 8'hFF); m_mr(i, 8'h00); end
  m_mr(0, 8'h03); m_mr(1, 8'h02);               // short CL / CWL
  a = mk(0, 14'h5, 8'hF8);
  m_wrl(a, {$urandom, $urandom, $urandom, $urandom}); m_rdl(a); m_rd(a + 3);
  m_mr(0, `MEM_APB_MR0); m_mr(1, 8'(CWL - 5));  // reset values
endtask
`endif

task automatic mem_func;
  logic [31:0] a;
  rd_exp(A_RDATA, 0);
  rd_exp(A_FLAGS, 0);
  // ---- every bank entry: write and read back, conflicts, ACT / PRE
  for (int b = 0; b < NBU && b < 8; b++) begin
    m_send(3'd1, mk(b, 14'h3FFF, 8'h00), 0);
    m_wr(mk(b, 14'h3FFF, 8'h11), 16'hA5A5 ^ 16'(b));
    m_rd(mk(b, 14'h3FFF, 8'h11));
    m_wr(mk(b, 14'h0, 8'h12), 16'h5A5A);
    m_rd(mk(b, 14'h0, 8'h12));
    m_send(3'd4, mk(b, 14'h0, 8'h00), 0);
    m_rd(mk(b, 14'h3FFF, 8'h11));
  end
  // ---- data patterns: every RDATA / hwdata bit both ways
  a = mk(0, 14'h1, 8'h5A);
  m_wr(a, 16'hFFFF); m_rd(a); m_wr(a, 16'h0000); m_rd(a);
  m_wr(a, 16'hAAAA); m_rd(a); m_wr(a, 16'h5555); m_rd(a);
  // ---- every bank entry (so every channel's dq lanes): all ones, all zeros
  for (int b = 0; b < NBU; b++) begin
    m_wr(mk(b, 14'h2, 8'h77), 16'hFFFF); m_wr(mk(b, 14'h2, 8'h78), 16'h0000);
  end
  m_rd(mk(NBU - 1, 14'h2, 8'h77));
  // ---- no-op codes, addresses with every bit both ways
`ifdef MEM_LINE
  m_send(3'd0, 32'hFFFF_FFFF, 16'hFFFF); m_send(3'd0, 32'h0, 16'h0);
  line_func();
`else
  m_send(3'd0, 32'hFFFF_FFFF, 16'hFFFF); m_send(3'd5, 32'h0, 16'h0);
  m_send(3'd6, 32'hFFFF_FFFF, 16'hFFFF); m_send(3'd7, 32'h0, 16'h0);
`endif
  for (int k = 0; k < 24; k++) begin
    a = m_addr();
    if (k % 3 == 0) m_wr(a, $urandom); else m_rd(a);
  end
  // ---- CMD while busy: the second command waits in CMD (FULL), a third
  // write to CMD2 is dropped (CMD_OVF); interrupts masked
  wr(A_IRQ_STATUS, IRQ_ALL);
  a = mk(1 % NBU, 14'h7, 8'h21);
  m_wr(a, 16'h1234);
  // a write to another row of the same bank first, so the READ of a is a
  // row conflict (PRE, ACT, RD) and keeps the core busy long enough (another
  // column too: the model storage ignores the row)
  m_wr(mk(1 % NBU, 14'h9, 8'h22), 16'h5678);
  no_idle = 1;                         // exact timing: the core is still busy
  m_send(3'd2, a, 0);
  wr(A_CMD2, 32'h0);                   // core busy: held
  rd(A_FLAGS);
  if (rdv !== M_FULL) fail("CMD not held while the core is busy");
  wr(A_CMD2, 32'h0);                   // full: dropped
  no_idle = 0;
  poll(A_FLAGS, M_FULL, 0, 2000);
  // every READ taken is done (one or two, as the core may take the first at
  // once), so no RD_DONE is still to come when the random traffic below
  // clears and waits for its own
  for (int t = 0; t < 4000 && m_ndone != m_nrd; t++) @(negedge PCLK);
  if (m_ndone != m_nrd) fail("held READ never finished");
  rd_exp(A_RDATA, 32'h1234);
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  if (irq !== 1'b0) fail("irq with every interrupt masked");
  // ---- each interrupt alone onto irq, then cleared
  for (int i = 0; i < 3; i++) begin
    wr(A_IRQ_ENABLE, 32'h1 << i);
    if (irq !== 1'b1) fail($sformatf("irq bit %0d enabled: no irq", i));
    wr(A_IRQ_STATUS, 32'h1 << i);
    if (irq !== 1'b0) fail($sformatf("irq bit %0d cleared: irq stays", i));
  end
  // ---- random traffic with every interrupt enabled
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int k = 0; k < 40; k++) begin
    a = m_addr();
    case ($urandom_range(0, 5))
      0: m_send(3'd1, a, 0);
      1: m_send(3'd4, a, 0);
      2, 3: m_wr(a, $urandom);
      default: m_rd(a);
    endcase
  end
  poll(A_FLAGS, M_FULL, 0, 2000);
  cycles(40);
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
