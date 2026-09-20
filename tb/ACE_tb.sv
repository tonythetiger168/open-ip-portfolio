// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for ACE_top -- AXI4 master model + snoop (AC/CR/CD)
// interconnect model. Checks: reset state, burst write/read compare,
// snoop dirty-hit data return, snoop miss, MakeUnique invalidation,
// SLVERR error injection + irq, back-to-back transactions.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module ACE_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_SLVERR = 2'b10;
  localparam logic [3:0] SNP_READSHARED = 4'b0000;
  localparam logic [3:0] SNP_READCLEAN  = 4'b0001;
  localparam logic [3:0] SNP_MAKEUNIQUE = 4'b0111;

  logic clk = 0, rst_n = 0;
  // AW
  logic awvalid = 0, awready;
  logic [AW-1:0] awaddr = 0;
  logic [7:0]  awlen = 0;
  logic [2:0]  awsize = 0;
  logic [1:0]  awburst = 0;
  logic [2:0]  awsnoop = 0;
  logic [1:0]  awdomain = 0, awbar = 0;
  // W
  logic wvalid = 0, wready;
  logic [DW-1:0] wdata = 0;
  logic [DW/8-1:0] wstrb = 0;
  logic wlast = 0;
  // B
  logic bvalid, bready = 0;
  logic [1:0] bresp;
  // AR
  logic arvalid = 0, arready;
  logic [AW-1:0] araddr = 0;
  logic [7:0] arlen = 0;
  logic [2:0] arsize = 0;
  logic [1:0] arburst = 0;
  logic [3:0] arsnoop = 0;
  logic [1:0] ardomain = 0, arbar = 0;
  // R
  logic rvalid, rready = 0;
  logic [DW-1:0] rdata;
  logic [1:0] rresp;
  logic rlast;
  // AC
  logic acvalid = 0, acready;
  logic [AW-1:0] acaddr = 0;
  logic [3:0] acsnoop = 0;
  // CR
  logic crvalid, crready = 0;
  logic [4:0] crresp;
  // CD
  logic cdvalid, cdready = 0;
  logic [DW-1:0] cddata;
  logic cdlast;
  logic irq;

  int errors = 0;
  int irq_seen = 0;

  ACE_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awlen(awlen),
    .awsize(awsize), .awburst(awburst), .awsnoop(awsnoop),
    .awdomain(awdomain), .awbar(awbar),
    .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
    .bvalid(bvalid), .bready(bready), .bresp(bresp),
    .arvalid(arvalid), .arready(arready), .araddr(araddr), .arlen(arlen),
    .arsize(arsize), .arburst(arburst), .arsnoop(arsnoop),
    .ardomain(ardomain), .arbar(arbar),
    .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp), .rlast(rlast),
    .acvalid(acvalid), .acready(acready), .acaddr(acaddr), .acsnoop(acsnoop),
    .crvalid(crvalid), .crready(crready), .crresp(crresp),
    .cdvalid(cdvalid), .cdready(cdready), .cddata(cddata), .cdlast(cdlast),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // irq monitor
  always @(posedge clk) if (irq) irq_seen++;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probes, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // =====================================================================
  localparam logic [3:0] SNP_CLEANINVALID = 4'b1000;  // RTL encoding
  localparam int ACE_FSM_TOTAL = 8;   // W 3 + R 2 + S 3 states
  logic [2:0] wfsm_seen = '0;         // visited-state bitmaps
  logic [1:0] rfsm_seen = '0;
  logic [2:0] sfsm_seen = '0;
  wire [1:0] dut_wstate = dut.wstate;   // hierarchical FSM probes
  wire       dut_rstate = dut.rstate;
  wire [1:0] dut_sstate = dut.sstate;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: sample all three DUT state registers every clock
  always @(posedge clk) begin
    wfsm_seen[dut_wstate] <= 1'b1;
    rfsm_seen[dut_rstate] <= 1'b1;
    sfsm_seen[dut_sstate] <= 1'b1;
  end

  // output-invariant assertion suite (prev-cycle samples for stability
  // checks; all values read coherently pre-NBA). rst_obs gates out the
  // t=0 sample (this block can run before the DUT's initial reset settle
  // on the very first posedge).
  logic        p_rstn = 1, rst_obs = 0;
  logic        p_bvalid = 0, p_bready = 0;
  logic [1:0]  p_bresp  = 0;
  logic        p_rvalid = 0, p_rready = 0, p_rlast = 0;
  logic [1:0]  p_rresp  = 0;
  logic [31:0] p_rdata  = 0;
  logic        p_crvalid = 0, p_crready = 0;
  logic [4:0]  p_crresp  = 0;
  logic        p_cdvalid = 0, p_cdready = 0;
  logic [31:0] p_cddata  = 0;
  logic        p_irq = 0;
  always @(posedge clk) begin
    if (!rst_n) rst_obs <= 1'b1;
    if (rst_obs) begin
      if (!p_rstn) begin
        // A1: no response channel activity during reset
        sva_check(bvalid === 1'b0 && rvalid === 1'b0 &&
                  crvalid === 1'b0 && cdvalid === 1'b0,
                  "A1 reset: response channels low");
      end else begin
        // A2: bvalid held stable until bready
        sva_check(!(p_bvalid && !p_bready) ||
                  (bvalid && bresp === p_bresp),
                  "A2 bvalid/bresp held until bready");
        // A3: rvalid held stable until rready
        sva_check(!(p_rvalid && !p_rready) ||
                  (rvalid && rdata === p_rdata && rresp === p_rresp &&
                   rlast === p_rlast),
                  "A3 rvalid/rdata/rresp held until rready");
        // A4: crvalid held stable until crready
        sva_check(!(p_crvalid && !p_crready) ||
                  (crvalid && crresp === p_crresp),
                  "A4 crvalid/crresp held until crready");
        // A5: cdvalid held stable until cdready
        sva_check(!(p_cdvalid && !p_cdready) ||
                  (cdvalid && cddata === p_cddata),
                  "A5 cdvalid/cddata held until cdready");
        // A6: last flags only together with their valid
        sva_check((!rlast || rvalid) && (!cdlast || cdvalid),
                  "A6 last implies valid");
        // A7: bresp/rresp only OKAY(00)/SLVERR(10)
        sva_check((!bvalid || (bresp !== 2'b01 && bresp !== 2'b11)) &&
                  (!rvalid || (rresp !== 2'b01 && rresp !== 2'b11)),
                  "A7 b/rresp legal");
        // A8: crresp WasUnique[4]/Error[1] are hard-wired 0
        sva_check(!crvalid || (crresp[4] === 1'b0 && crresp[1] === 1'b0),
                  "A8 crresp fixed bits zero");
        // A9: write-channel phase outputs mutually exclusive
        sva_check((awready + wready + bvalid) <= 1,
                  "A9 write phases mutually exclusive");
        // A10: irq is a single-cycle pulse (no back-to-back)
        sva_check(!(irq && p_irq), "A10 irq single-cycle pulse");
      end
    end
    p_bvalid <= bvalid; p_bready <= bready; p_bresp <= bresp;
    p_rvalid <= rvalid; p_rready <= rready; p_rlast <= rlast;
    p_rresp  <= rresp;  p_rdata  <= rdata;
    p_crvalid <= crvalid; p_crready <= crready; p_crresp <= crresp;
    p_cdvalid <= cdvalid; p_cdready <= cdready; p_cddata <= cddata;
    p_irq <= irq;
    p_rstn <= rst_n;
  end

  // ---- CRV cache-line scoreboard (mirrors the 64-line cache model) ---
  logic [63:0] m_valid = '0, m_dirty = '0;
  logic [23:0] m_tag   [0:63];
  logic [31:0] m_data  [0:63];

  // address-time error class (matches RTL werr_q/rerr_q equation)
  function automatic logic crv_err(input logic [31:0] a,
                                   input logic [1:0]  b,
                                   input logic [2:0]  s);
    return (b != 2'b01) || (s > 3'd2) || (|a[31:16]);
  endfunction

  // ---- CRV write burst: random ACE side fields, random data/strb -----
  task automatic crv_write(input logic [31:0] addr, input logic [7:0] len,
                           input logic [1:0] burst, input logic [2:0] size,
                           input bit stall, input bit rand_strb = 1);
    logic        err;
    logic [31:0] a, d;
    logic [3:0]  st;
    begin
      err = crv_err(addr, burst, size);
      @(negedge clk);
      awvalid = 1; awaddr = addr; awlen = len; awsize = size;
      awburst = burst;
      awsnoop  = 3'($urandom_range(0, 7));   // side fields: functional no-ops,
      awdomain = 2'($urandom_range(0, 3));   // randomized for toggle coverage
      awbar    = 2'($urandom_range(0, 3));
      while (!awready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) awvalid = 0;
      for (int i = 0; i <= len; i++) begin
        if (stall) repeat ($urandom_range(0, 2)) @(negedge clk);
        d  = $urandom;
        st = rand_strb ? 4'($urandom_range(0, 15)) : 4'hF;
        wvalid = 1; wdata = d; wstrb = st; wlast = (i == len);
        while (!wready) @(negedge clk);
        @(posedge clk);
        @(negedge clk) wvalid = 0; wlast = 0;
        // scoreboard update: the DUT writes every accepted beat when !err
        a = addr + 32'(i) * 4;
        if (!err) begin
          m_valid[a[7:2]] = 1'b1;
          m_dirty[a[7:2]] = 1'b1;
          m_tag[a[7:2]]   = a[31:8];
          for (int b = 0; b < 4; b++)
            if (st[b]) m_data[a[7:2]][8*b +: 8] = d[8*b +: 8];
        end
      end
      bready = 0;
      while (!bvalid) @(negedge clk);
      if (bresp !== (err ? AXI_SLVERR : AXI_OKAY)) begin
        errors++;
        $display("ERROR: CRV ACE write @%h bresp=%b exp_slverr=%b",
                 addr, bresp, err);
      end
      if (stall) repeat (2) @(negedge clk);
      bready = 1;
      @(posedge clk);
      @(negedge clk) bready = 0;
    end
  endtask

  // ---- CRV read burst: per-beat data compare vs scoreboard -----------
  task automatic crv_read(input logic [31:0] addr, input logic [7:0] len,
                          input logic [1:0] burst, input logic [2:0] size,
                          input bit stall);
    logic        err;
    logic [31:0] a, exp;
    begin
      err = crv_err(addr, burst, size);
      @(negedge clk);
      arvalid = 1; araddr = addr; arlen = len; arsize = size;
      arburst = burst;
      arsnoop  = 4'($urandom_range(0, 15));
      ardomain = 2'($urandom_range(0, 3));
      arbar    = 2'($urandom_range(0, 3));
      while (!arready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) arvalid = 0;
      for (int i = 0; i <= len; i++) begin
        rready = 0;
        while (!rvalid) @(negedge clk);
        a   = addr + 32'(i) * 4;
        exp = (m_valid[a[7:2]] && (m_tag[a[7:2]] === a[31:8]))
              ? m_data[a[7:2]] : 32'h0;
        if (rdata !== exp) begin
          errors++;
          $display("ERROR: CRV ACE read @%h beat%0d got=%h exp=%h",
                   addr, i, rdata, exp);
        end
        if (rlast !== (i == len)) begin
          errors++;
          $display("ERROR: CRV ACE read @%h beat%0d rlast=%b", addr, i, rlast);
        end
        if (rresp !== (err ? AXI_SLVERR : AXI_OKAY)) begin
          errors++;
          $display("ERROR: CRV ACE read @%h beat%0d rresp=%b", addr, i, rresp);
        end
        if (stall) repeat ($urandom_range(0, 1)) @(negedge clk);
        rready = 1;
        @(posedge clk);
        @(negedge clk) rready = 0;
      end
    end
  endtask

  // ---- CRV snoop: expected CR/CD from the scoreboard, then update ----
  task automatic crv_snoop(input logic [31:0] addr, input logic [3:0] stype);
    logic        hit, dty;
    logic [4:0]  exp_resp;
    logic        exp_cd;
    logic [31:0] exp_data;
    begin
      hit = m_valid[addr[7:2]] && (m_tag[addr[7:2]] === addr[31:8]);
      dty = m_dirty[addr[7:2]];
      exp_resp = 5'b0; exp_cd = 1'b0; exp_data = '0;
      case (stype)
        SNP_READSHARED, SNP_READCLEAN: if (hit) begin
          exp_resp = {1'b0, 1'b1, dty, 1'b0, 1'b1};
          exp_cd   = 1'b1;
          exp_data = m_data[addr[7:2]];
        end
        SNP_CLEANINVALID: if (hit && dty) begin
          exp_resp = {1'b0, 1'b0, 1'b1, 1'b0, 1'b1};
          exp_cd   = 1'b1;
          exp_data = m_data[addr[7:2]];
        end
        default: ;   // MakeUnique / unsupported: plain miss response
      endcase
      // AC
      @(negedge clk);
      acvalid = 1; acaddr = addr; acsnoop = stype;
      while (!acready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) acvalid = 0;
      // CR
      while (!crvalid) @(negedge clk);
      if (crresp !== exp_resp) begin
        errors++;
        $display("ERROR: CRV ACE snoop @%h type=%h crresp=%b exp=%b",
                 addr, stype, crresp, exp_resp);
      end
      @(negedge clk) crready = 1;
      @(posedge clk);
      @(negedge clk) crready = 0;
      // CD if DataTransfer expected
      if (exp_cd) begin
        while (!cdvalid) @(negedge clk);
        if (cddata !== exp_data || cdlast !== 1'b1) begin
          errors++;
          $display("ERROR: CRV ACE snoop CD @%h data=%h last=%b exp=%h",
                   addr, cddata, cdlast, exp_data);
        end
        @(negedge clk) cdready = 1;
        @(posedge clk);
        @(negedge clk) cdready = 0;
      end
      // scoreboard update (mirrors RTL exactly)
      case (stype)
        SNP_READSHARED, SNP_READCLEAN:
          if (hit) m_dirty[addr[7:2]] = 1'b0;
        SNP_MAKEUNIQUE: begin   // invalidate unconditionally
          m_valid[addr[7:2]] = 1'b0;
          m_dirty[addr[7:2]] = 1'b0;
        end
        SNP_CLEANINVALID: if (hit) begin
          m_valid[addr[7:2]] = 1'b0;
          m_dirty[addr[7:2]] = 1'b0;
        end
        default: ;
      endcase
    end
  endtask
`endif

  // -------------------------------------------------
  // AXI write burst: data = base+i for beat i
  // -------------------------------------------------
  task automatic axi_write(input logic [AW-1:0] addr, input logic [7:0] len,
                           input logic [DW-1:0] base, input logic [1:0] burst,
                           input logic [1:0] exp_resp);
    int stall;
    begin
      // AW
      @(negedge clk);
      awvalid = 1; awaddr = addr; awlen = len; awsize = 3'd2;
      awburst = burst; awsnoop = 3'b000; awdomain = 2'b01; awbar = 2'b00;
      while (!awready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) awvalid = 0;
      // W beats (with occasional wvalid stall)
      for (int i = 0; i <= len; i++) begin
        stall = ($random & 1);
        repeat (stall) @(negedge clk);
        wvalid = 1; wdata = base + i; wstrb = 4'hF; wlast = (i == len);
        while (!wready) @(negedge clk);
        @(posedge clk);
        @(negedge clk) wvalid = 0; wlast = 0;
      end
      // B (bready backpressure: hold low a couple of cycles)
      bready = 0;
      while (!bvalid) @(negedge clk);
      if (bresp !== exp_resp) begin
        errors++;
        $display("ERROR: ACE write @%h bresp=%b exp=%b", addr, bresp, exp_resp);
      end
      repeat (2) @(negedge clk);
      bready = 1;
      @(posedge clk);
      @(negedge clk) bready = 0;
    end
  endtask

  // -------------------------------------------------
  // AXI read burst: compare data = base+i, check rlast/rresp
  // -------------------------------------------------
  task automatic axi_read(input logic [AW-1:0] addr, input logic [7:0] len,
                          input logic [DW-1:0] base, input logic [1:0] exp_resp,
                          input bit exp_zero);
    logic [DW-1:0] exp;
    begin
      @(negedge clk);
      arvalid = 1; araddr = addr; arlen = len; arsize = 3'd2;
      arburst = 2'b01; arsnoop = 4'h0; ardomain = 2'b01; arbar = 2'b00;
      while (!arready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) arvalid = 0;
      for (int i = 0; i <= len; i++) begin
        rready = 0;
        while (!rvalid) @(negedge clk);
        exp = exp_zero ? 32'h0 : base + i;
        if (rdata !== exp) begin
          errors++;
          $display("ERROR: ACE read @%h beat%0d got=%h exp=%h", addr, i, rdata, exp);
        end
        if (rlast !== (i == len)) begin
          errors++;
          $display("ERROR: ACE read @%h beat%0d rlast=%b", addr, i, rlast);
        end
        if (rresp !== exp_resp) begin
          errors++;
          $display("ERROR: ACE read @%h beat%0d rresp=%b exp=%b", addr, i, rresp, exp_resp);
        end
        repeat ($random & 1) @(negedge clk);  // rready backpressure
        rready = 1;
        @(posedge clk);
        @(negedge clk) rready = 0;
      end
    end
  endtask

  // -------------------------------------------------
  // Snoop transaction: returns crresp; if DataTransfer, returns CD data
  // -------------------------------------------------
  task automatic do_snoop(input logic [AW-1:0] addr, input logic [3:0] stype,
                          output logic [4:0] resp, output logic [DW-1:0] dat);
    begin
      @(negedge clk);
      acvalid = 1; acaddr = addr; acsnoop = stype;
      while (!acready) @(negedge clk);
      @(posedge clk);
      @(negedge clk) acvalid = 0;
      // CR
      while (!crvalid) @(negedge clk);
      resp = crresp;
      @(negedge clk) crready = 1;
      @(posedge clk);
      @(negedge clk) crready = 0;
      // CD if DataTransfer
      dat = '0;
      if (resp[0]) begin
        while (!cdvalid) @(negedge clk);
        dat = cddata;
        if (cdlast !== 1'b1) begin
          errors++;
          $display("ERROR: ACE snoop @%h cdlast not set on single-beat CD", addr);
        end
        @(negedge clk) cdready = 1;
        @(posedge clk);
        @(negedge clk) cdready = 0;
      end
    end
  endtask

  logic [4:0] sresp;
  logic [DW-1:0] sdat_q;

  initial begin
    // ---------------- 1. reset state check ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    @(negedge clk);
    if (bvalid !== 0 || rvalid !== 0 || crvalid !== 0 || cdvalid !== 0) begin
      errors++;
      $display("ERROR: ACE reset state bvalid=%b rvalid=%b crvalid=%b cdvalid=%b",
               bvalid, rvalid, crvalid, cdvalid);
    end
    rst_n = 1; repeat (2) @(posedge clk);

    // ---------------- 2. burst write then read-back compare ----------------
    axi_write(32'h0000_0040, 8'd3,  32'hA5A5_0000, 2'b01, AXI_OKAY);
    axi_read (32'h0000_0040, 8'd3,  32'hA5A5_0000, AXI_OKAY, 0);
    axi_write(32'h0000_0100, 8'd15, 32'h1111_0000, 2'b01, AXI_OKAY);  // max len
    axi_read (32'h0000_0100, 8'd15, 32'h1111_0000, AXI_OKAY, 0);
    axi_write(32'h0000_0004, 8'd0,  32'h5A5A_5A5A, 2'b01, AXI_OKAY);  // single beat
    axi_read (32'h0000_0004, 8'd0,  32'h5A5A_5A5A, AXI_OKAY, 0);

    // ---------------- 3. snoop ReadShared hit on dirty line ----------------
    axi_write(32'h0000_0200, 8'd0, 32'hDEAD_BEEF, 2'b01, AXI_OKAY);
    do_snoop(32'h0000_0200, SNP_READSHARED, sresp, sdat_q);
    if (sresp[0] !== 1'b1 || sresp[2] !== 1'b1 || sresp[3] !== 1'b1) begin
      errors++;
      $display("ERROR: ACE snoop dirty hit crresp=%b (exp DataTransfer+PassDirty+IsShared)", sresp);
    end
    if (sdat_q !== 32'hDEAD_BEEF) begin
      errors++;
      $display("ERROR: ACE snoop CD data got=%h exp=DEADBEEF", sdat_q);
    end

    // ---------------- 4. snoop miss (never-written address) ----------------
    do_snoop(32'h0000_3000, SNP_READSHARED, sresp, sdat_q);
    if (sresp !== 5'b00000) begin
      errors++;
      $display("ERROR: ACE snoop miss crresp=%b exp=00000", sresp);
    end

    // ---------------- 5. MakeUnique invalidation ----------------
    axi_write(32'h0000_0400, 8'd0, 32'hCAFE_F00D, 2'b01, AXI_OKAY);
    do_snoop(32'h0000_0400, SNP_MAKEUNIQUE, sresp, sdat_q);
    if (sresp !== 5'b00000) begin
      errors++;
      $display("ERROR: ACE MakeUnique crresp=%b exp=00000 (no data)", sresp);
    end
    // line must be invalidated: re-snoop misses now
    do_snoop(32'h0000_0400, SNP_READSHARED, sresp, sdat_q);
    if (sresp !== 5'b00000) begin
      errors++;
      $display("ERROR: ACE post-MakeUnique snoop crresp=%b exp=00000", sresp);
    end
    // and AXI read of invalidated line reads as miss (zero)
    axi_read(32'h0000_0400, 8'd0, 32'h0, AXI_OKAY, 1);

    // ---------------- 6. error injection: out-of-range -> SLVERR + irq ----
    irq_seen = 0;
    axi_write(32'h0002_0000, 8'd0, 32'hBAD0_BAD0, 2'b01, AXI_SLVERR);
    axi_read (32'h0002_0000, 8'd0, 32'h0, AXI_SLVERR, 0);
    repeat (2) @(posedge clk);
    if (irq_seen == 0) begin
      errors++;
      $display("ERROR: ACE irq not asserted on SLVERR protocol error");
    end

    // ---------------- 7. back-to-back transactions ----------------
    axi_write(32'h0000_0080, 8'd1, 32'h0ACE_0000, 2'b01, AXI_OKAY);
    axi_write(32'h0000_00C0, 8'd1, 32'h0ACE_1000, 2'b01, AXI_OKAY);
    axi_read (32'h0000_0080, 8'd1, 32'h0ACE_0000, AXI_OKAY, 0);
    axi_read (32'h0000_00C0, 8'd1, 32'h0ACE_1000, AXI_OKAY, 0);
    // snoop ReadClean on clean line (written by back-to-back, still dirty)
    do_snoop(32'h0000_0080, SNP_READCLEAN, sresp, sdat_q);
    if (sresp[0] !== 1'b1 || sdat_q !== 32'h0ACE_0000) begin
      errors++;
      $display("ERROR: ACE back-to-back snoop resp=%b data=%h", sresp, sdat_q);
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 64-line init sweep (resyncs the scoreboard) + 140 randomized
    // transactions: write bursts / read bursts / snoops. Randomized:
    // burst len (0..255, mostly short, sometimes long for counter
    // toggle), burst type (mostly INCR, sometimes illegal -> SLVERR),
    // size (mostly 2, sometimes >2 -> SLVERR), address class (in-range
    // tag0 / in-range nonzero-tag / boundary / out-of-range high bits /
    // misaligned), per-beat data + strobes, ACE side fields, snoop type
    // (ReadShared/ReadClean/MakeUnique/CleanInvalid/unsupported) and
    // backpressure stalls.
    begin : crv_phase
      int n_wr = 0, n_rd = 0, n_snp = 0;
      int roll;
      logic [31:0] c_addr;
      logic [7:0]  c_len;
      logic [1:0]  c_burst;
      logic [2:0]  c_size;
      logic [3:0]  c_snp;
      logic        c_stall;
      // resync sweep: full-strobe write of every line (tag 0) so both
      // the DUT line data and the scoreboard are fully overwritten
      for (int i = 0; i < 64; i++)
        crv_write(32'(i * 4), 8'd0, 2'b01, 3'd2, 1'b0, 1'b0);
      for (int t = 0; t < 140; t++) begin
        c_stall = $urandom_range(0, 1);
        // length class
        roll  = $urandom_range(0, 19);
        c_len = (roll < 13) ? 8'($urandom_range(0, 15)) :
                (roll < 18) ? 8'(16 + $urandom_range(0, 47))
                            : 8'(64 + $urandom_range(0, 191));
        // burst type: mostly INCR, sometimes illegal -> SLVERR
        roll    = $urandom_range(0, 19);
        c_burst = (roll < 15) ? 2'b01 : 2'($urandom_range(0, 3));
        // size: mostly 32-bit, sometimes >2 -> SLVERR
        roll   = $urandom_range(0, 9);
        c_size = (roll < 8) ? 3'd2 : 3'(3 + $urandom_range(0, 4));
        // address class
        roll = $urandom_range(0, 19);
        if (roll < 9)
          c_addr = 32'($urandom_range(0, 63) * 4);            // in-range, tag0
        else if (roll < 13)
          c_addr = 32'($urandom_range(64, 16383) * 4);        // in-range, tag
        else if (roll < 15)
          c_addr = 32'($urandom_range(56, 63) * 4);           // boundary
        else if (roll < 18)
          c_addr = $urandom | 32'hFFFF_0000;                  // oob high bits
        else
          c_addr = 32'($urandom_range(0, 63) * 4) +
                   32'($urandom_range(1, 3));                 // misaligned
        // transaction type
        roll = $urandom_range(0, 19);
        if (roll < 8) begin
          n_wr++;
          crv_write(c_addr, c_len, c_burst, c_size, c_stall);
        end else if (roll < 15) begin
          n_rd++;
          crv_read(c_addr, c_len, c_burst, c_size, c_stall);
        end else begin
          n_snp++;
          roll = $urandom_range(0, 9);
          case (roll)
            0, 1:    c_snp = SNP_READSHARED;
            2, 3:    c_snp = SNP_READCLEAN;
            4, 5:    c_snp = SNP_MAKEUNIQUE;
            6, 7:    c_snp = SNP_CLEANINVALID;
            default: c_snp = 4'($urandom_range(2, 6));  // unsupported
          endcase
          // snoop addresses favor recently-written lines for hits
          if ($urandom_range(0, 1))
            c_addr = 32'($urandom_range(0, 63) * 4);
          crv_snoop(c_addr, c_snp);
        end
      end
      // ---- targeted toggle closure: all-ones/all-zeros patterns make
      // every wdata/rdata/cddata bit toggle deterministically (uses the
      // directed tasks; placed last, scoreboard no longer needed)
      axi_write(32'h020, 8'd0, 32'hFFFF_FFFF, 2'b01, AXI_OKAY);
      axi_read (32'h020, 8'd0, 32'hFFFF_FFFF, AXI_OKAY, 0);
      do_snoop(32'h020, SNP_READSHARED, sresp, sdat_q);   // CD all-ones
      axi_write(32'h020, 8'd0, 32'h0000_0000, 2'b01, AXI_OKAY);
      axi_read (32'h020, 8'd0, 32'h0000_0000, AXI_OKAY, 0);
      do_snoop(32'h020, SNP_READSHARED, sresp, sdat_q);   // CD all-zeros
      // targeted: CleanInvalid on a dirty line (hit+dirty arm returns
      // PassDirty + DataTransfer, then invalidates)
      axi_write(32'h020, 8'd0, 32'h5A5A_5A5A, 2'b01, AXI_OKAY);
      do_snoop(32'h020, SNP_CLEANINVALID, sresp, sdat_q);
      if (sresp !== 5'b00101 || sdat_q !== 32'h5A5A_5A5A) begin
        errors++;
        $display("ERROR: ACE CleanInvalid dirty hit resp=%b data=%h",
                 sresp, sdat_q);
      end
      $display("CRV: 64 init + 140 txns (wr=%0d rd=%0d snp=%0d)",
               n_wr, n_rd, n_snp);
    end
`endif
    if (errors == 0) $display("TEST PASSED: ACE");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 3; s++) visited += wfsm_seen[s];
      for (int s = 0; s < 2; s++) visited += rfsm_seen[s];
      for (int s = 0; s < 3; s++) visited += sfsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, ACE_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (5000) #1000;   // 5 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #200000;
    $display("TIMEOUT");
    $finish;
  end
`endif
endmodule
