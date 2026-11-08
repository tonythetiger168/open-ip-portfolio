// SPDX-License-Identifier: Apache-2.0
// soc_ss_axi_mem: behavioural AXI4 subordinate memory used by the testbenches
// of the phone SoC subsystem IPs (32-bit address and data, 4-bit ID).
//  - Word memory of 2^18 entries hashed from the whole address (index
//    a[19:2] + {a[31:20], 6'b0}), each tagged with its full word address:
//    a word never written, or overwritten by a word that hashes to the same
//    entry, reads as RESET_WORD. Buffers that differ only in high address
//    bits land 64 K entries apart, so test buffers do not collide.
//  - Write and read channels are independent; one burst of each at a time.
//  - Random AWREADY / WREADY / ARREADY and BVALID / RVALID delays when
//    `stall` is 1 (the default), zero delays when it is 0.
//  - Accesses with err_lo <= address < err_hi get SLVERR (writes are dropped,
//    reads return 32'hDEAD_BEEF).
//  - A reset (rst_n low) ends the bursts in progress.
//  - Checks every burst: AxSIZE = 2, AxBURST = INCR, no 4 KB crossing, WLAST
//    on the last beat only, BID / RID echo the request ID. A violation
//    increments `errors` and is printed with "ERROR:".
`ifndef SOC_SS_AXI_MEM_SVH
`define SOC_SS_AXI_MEM_SVH
module soc_ss_axi_mem #(parameter logic [31:0] RESET_WORD = 32'h0) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [3:0]  awid,
  input  logic [31:0] awaddr,
  input  logic [7:0]  awlen,
  input  logic [2:0]  awsize,
  input  logic [1:0]  awburst,
  input  logic [2:0]  awprot,
  input  logic        awvalid,
  output logic        awready,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  input  logic        wlast,
  input  logic        wvalid,
  output logic        wready,
  output logic [3:0]  bid,
  output logic [1:0]  bresp,
  output logic        bvalid,
  input  logic        bready,
  input  logic [3:0]  arid,
  input  logic [31:0] araddr,
  input  logic [7:0]  arlen,
  input  logic [2:0]  arsize,
  input  logic [1:0]  arburst,
  input  logic [2:0]  arprot,
  input  logic        arvalid,
  output logic        arready,
  output logic [3:0]  rid,
  output logic [31:0] rdata,
  output logic [1:0]  rresp,
  output logic        rlast,
  output logic        rvalid,
  input  logic        rready
);
  logic [31:0] mem [262144];
  logic [29:0] tag [262144];
  bit          vld [262144];
  bit          stall = 1;
  bit          aw_hold = 0;      // 1: AWREADY held low (a blocked write path)
  logic [31:0] err_lo = 32'hFFFF_FFFF, err_hi = 32'hFFFF_FFFF;
  int          errors = 0;
  int          n_wr_bursts = 0, n_rd_bursts = 0, n_wr_beats = 0, n_rd_beats = 0;
  int          max_awlen = 0, max_arlen = 0;
  logic [2:0]  last_awprot, last_arprot;

  function automatic int unsigned idx(input logic [31:0] a);
    return 32'(18'(a[19:2] + {a[31:20], 6'b0}));
  endfunction
  function automatic logic [31:0] peek(input logic [31:0] a);
    return (vld[idx(a)] && tag[idx(a)] == a[31:2]) ? mem[idx(a)] : RESET_WORD;
  endfunction
  function automatic void poke(input logic [31:0] a, input logic [31:0] d);
    mem[idx(a)] = d; tag[idx(a)] = a[31:2]; vld[idx(a)] = 1'b1;
  endfunction
  function automatic bit is_err(input logic [31:0] a);
    return a >= err_lo && a < err_hi;
  endfunction
  function automatic void bad(input string m);
    errors++;
    $display("ERROR: axi_mem: %s @%0t", m, $time);
  endfunction
  function automatic void check_req(input string ch, input logic [31:0] a, input logic [7:0] l,
                                    input logic [2:0] sz, input logic [1:0] bu);
    if (sz !== 3'd2) bad($sformatf("%s size %0d", ch, sz));
    if (bu !== 2'b01) bad($sformatf("%s burst %0d", ch, bu));
    if (a[1:0] !== 2'b00) bad($sformatf("%s unaligned %h", ch, a));
    if ({20'd0, a[11:0]} + 32'(l) * 4 + 4 > 32'd4096) bad($sformatf("%s %h len %0d crosses 4 KB", ch, a, l));
  endfunction
  task automatic dly;
    if (stall) repeat ($urandom % 4) @(posedge clk);
  endtask

  // write channel; a reset ends the burst in progress
  task automatic wr_burst;
    logic [31:0] a; logic [7:0] l; logic [3:0] id; logic e;
    dly();
    #1 awready = 1;
    @(posedge clk);
    a = awaddr; l = awlen; id = awid; last_awprot = awprot;
    check_req("AW", awaddr, awlen, awsize, awburst);
    #1 awready = 0;
    n_wr_bursts++; if (l > max_awlen) max_awlen = l;
    e = 0;
    for (int i = 0; i <= l; i++) begin
      dly();
      #1 wready = 1;
      @(posedge clk);
      while (!wvalid) @(posedge clk);
      if (wlast !== (i == l)) bad($sformatf("WLAST %b on beat %0d of %0d", wlast, i, l + 1));
      if (wstrb !== 4'hF) bad($sformatf("WSTRB %h", wstrb));
      if (is_err(a)) e = 1; else poke(a, wdata);
      n_wr_beats++;
      a = a + 4;
      #1 wready = 0;
    end
    dly();
    #1 bvalid = 1; bid = id; bresp = e ? 2'b10 : 2'b00;
    @(posedge clk);
    while (!bready) @(posedge clk);
    #1 bvalid = 0;
  endtask
  initial begin
    awready = 0; wready = 0; bvalid = 0; bid = 0; bresp = 0;
    forever begin
      @(posedge clk);
      if (!rst_n || !awvalid || aw_hold) continue;
      fork
        wr_burst();
        @(negedge rst_n);
      join_any
      disable fork;
      if (!rst_n) begin awready = 0; wready = 0; bvalid = 0; end
    end
  end

  // read channel; a reset ends the burst in progress
  task automatic rd_burst;
    logic [31:0] a; logic [7:0] l; logic [3:0] id;
    dly();
    #1 arready = 1;
    @(posedge clk);
    a = araddr; l = arlen; id = arid; last_arprot = arprot;
    check_req("AR", araddr, arlen, arsize, arburst);
    #1 arready = 0;
    n_rd_bursts++; if (l > max_arlen) max_arlen = l;
    for (int i = 0; i <= l; i++) begin
      dly();
      #1 rvalid = 1; rid = id; rlast = (i == l);
      rdata = is_err(a) ? 32'hDEAD_BEEF : peek(a);
      rresp = is_err(a) ? 2'b10 : 2'b00;
      @(posedge clk);
      while (!rready) @(posedge clk);
      n_rd_beats++;
      a = a + 4;
      #1 rvalid = 0; rlast = 0;
    end
  endtask
  initial begin
    arready = 0; rvalid = 0; rid = 0; rdata = 0; rresp = 0; rlast = 0;
    forever begin
      @(posedge clk);
      if (!rst_n || !arvalid) continue;
      fork
        rd_burst();
        @(negedge rst_n);
      join_any
      disable fork;
      if (!rst_n) begin arready = 0; rvalid = 0; rlast = 0; end
    end
  end
endmodule
// AXI4 manager pins of a subsystem core as TB wires (core testbenches), and an
// soc_ss_axi_mem instance on them: `SOC_SS_AXI_MEM(inst, clk, rst_n)
`define SOC_SS_AXI_WIRES \
  wire [3:0] m_awid; \
  wire [31:0] m_awaddr; \
  wire [7:0] m_awlen; \
  wire [2:0] m_awsize; \
  wire [1:0] m_awburst; \
  wire [2:0] m_awprot; \
  wire  m_awvalid; \
  wire  m_awready; \
  wire [31:0] m_wdata; \
  wire [3:0] m_wstrb; \
  wire  m_wlast; \
  wire  m_wvalid; \
  wire  m_wready; \
  wire [3:0] m_bid; \
  wire [1:0] m_bresp; \
  wire  m_bvalid; \
  wire  m_bready; \
  wire [3:0] m_arid; \
  wire [31:0] m_araddr; \
  wire [7:0] m_arlen; \
  wire [2:0] m_arsize; \
  wire [1:0] m_arburst; \
  wire [2:0] m_arprot; \
  wire  m_arvalid; \
  wire  m_arready; \
  wire [3:0] m_rid; \
  wire [31:0] m_rdata; \
  wire [1:0] m_rresp; \
  wire  m_rlast; \
  wire  m_rvalid; \
  wire  m_rready;
`define SOC_SS_AXI_MEM(inst, clk_s, rst_s) \
  soc_ss_axi_mem inst ( \
    .clk(clk_s), .rst_n(rst_s), \
    .awid(m_awid), \
    .awaddr(m_awaddr), \
    .awlen(m_awlen), \
    .awsize(m_awsize), \
    .awburst(m_awburst), \
    .awprot(m_awprot), \
    .awvalid(m_awvalid), \
    .awready(m_awready), \
    .wdata(m_wdata), \
    .wstrb(m_wstrb), \
    .wlast(m_wlast), \
    .wvalid(m_wvalid), \
    .wready(m_wready), \
    .bid(m_bid), \
    .bresp(m_bresp), \
    .bvalid(m_bvalid), \
    .bready(m_bready), \
    .arid(m_arid), \
    .araddr(m_araddr), \
    .arlen(m_arlen), \
    .arsize(m_arsize), \
    .arburst(m_arburst), \
    .arprot(m_arprot), \
    .arvalid(m_arvalid), \
    .arready(m_arready), \
    .rid(m_rid), \
    .rdata(m_rdata), \
    .rresp(m_rresp), \
    .rlast(m_rlast), \
    .rvalid(m_rvalid), \
    .rready(m_rready) \
  );
`endif
