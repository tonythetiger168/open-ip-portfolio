// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for OCP_IP_Open_Core_Protocol_top (OCP-IP master)
// TB contains a behavioral OCP slave model: configurable SCmdAccept delay,
// per-beat write-burst acceptance, 2-cycle read/write response latency,
// 64x32 memory, reserved region (0x100+) -> SResp=ERR, dead region
// (0xFFFF_0000) -> never accepts (exercises the master timeout).
// Checks: reset state, single/burst/posted write+read data paths, SCmdAccept
// backpressure + request stability, ERR response injection + irq, timeout
// abort + irq + recovery, consecutive transactions.
// ============================================================================
`timescale 1ns/1ps
module OCP_IP_Open_Core_Protocol_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  // cpu-side
  logic          req_valid, req_ready, req_rw, req_posted;
  logic [AW-1:0] req_addr;
  logic [4:0]    req_len;
  logic [DW-1:0] req_wdata;
  logic          resp_valid, resp_err;
  logic [DW-1:0] resp_rdata;
  // OCP
  logic [2:0]    MCmd;
  logic [AW-1:0] MAddr;
  logic [DW-1:0] MData;
  logic [3:0]    MByteEn;
  logic [4:0]    MBurstLength;
  logic [2:0]    MBurstSeq;
  logic          SCmdAccept;
  logic [1:0]    SResp;
  logic [DW-1:0] SData;
  logic          SRespLast;
  logic          irq;

  int errors = 0;

  OCP_IP_Open_Core_Protocol_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_ready(req_ready), .req_rw(req_rw),
    .req_posted(req_posted), .req_addr(req_addr), .req_len(req_len),
    .req_wdata(req_wdata),
    .resp_valid(resp_valid), .resp_rdata(resp_rdata), .resp_err(resp_err),
    .MCmd(MCmd), .MAddr(MAddr), .MData(MData), .MByteEn(MByteEn),
    .MBurstLength(MBurstLength), .MBurstSeq(MBurstSeq),
    .SCmdAccept(SCmdAccept), .SResp(SResp), .SData(SData),
    .SRespLast(SRespLast), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.state (O_IDLE..O_DONE), 6 states.
  // =====================================================================
  localparam int OCPI_FSM_TOTAL = 6;
  logic [5:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.state;

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

  // FSM coverage: sample DUT state register on both edges (scheduler
  // failure mode #3 mitigation: dual-edge probe tolerates lost wakeups)
  always @(posedge clk or negedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (level/comb checks, negedge-sampled
  // so all NBA updates are settled; no history-dependent properties)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(MCmd === 3'd0 && req_ready === 1'b1 &&
                  resp_valid === 1'b0 && irq === 1'b0,
                  "A1 reset: outputs quiescent");
    end else begin
      // A2: req_ready exactly reflects IDLE/WCOL
      sva_check(req_ready === (dut_state <= 3'd1), "A2 req_ready rule");
      // A3: MCmd is IDLE unless a request is being issued
      sva_check((dut_state == 3'd2) || (MCmd === 3'd0), "A3 MCmd only in O_ISSUE");
      // A4: resp_valid exactly reflects a response beat or O_DONE
      sva_check(resp_valid === ((((dut_state == 3'd3) || (dut_state == 3'd4)) &&
                                 (SResp != 2'd0)) || (dut_state == 3'd5)),
                "A4 resp_valid rule");
      // A5: SCmdAccept timeout counter bounded by the abort threshold
      sva_check(dut.to_cnt <= 7'd64, "A5 to_cnt <= 64 (63+abort-cycle overshoot)");
      // A6: state register holds a legal encoding (6 of 8 used)
      sva_check(dut_state <= 3'd5, "A6 state legal");
    end
    rst_n_q <= rst_n;
  end
`endif

  // ==================================================================
  // OCP slave model
  // ==================================================================
  localparam int ACC_DLY = 2;   // cycles before SCmdAccept (backpressure)

  logic [31:0] smem [0:63];
  typedef enum logic [2:0] {SLV_IDLE, SLV_WRB, SLV_WRWAIT, SLV_RDWAIT, SLV_RDRESP} slv_t;
  slv_t sstate;
  logic [31:0] s_addr;
  logic [4:0]  s_len, s_idx;
  logic [1:0]  s_dly;
  logic        s_err, s_posted;
  int acc_cnt = 0;

  wire slv_see_cmd  = (MCmd != 3'd0);
  wire slv_dead     = (MAddr == 32'hFFFF_0000);   // never accepts
  wire slv_acc_ph   = (sstate == SLV_IDLE) || (sstate == SLV_WRB);
  wire slv_acc      = SCmdAccept & slv_see_cmd;

  // SCmdAccept generation with configurable accept delay
  always @(posedge clk) begin
    if (!rst_n) begin
      SCmdAccept <= 1'b0; acc_cnt <= 0;
    end else begin
      if (slv_see_cmd && !slv_dead && slv_acc_ph) begin
        if (acc_cnt == ACC_DLY-1) begin
          SCmdAccept <= 1'b1; acc_cnt <= 0;
        end else begin
          SCmdAccept <= 1'b0; acc_cnt <= acc_cnt + 1;
        end
      end else begin
        SCmdAccept <= 1'b0; acc_cnt <= 0;
      end
    end
  end

  // slave FSM : capture writes, serve reads, error region -> SResp=ERR
  always @(posedge clk) begin
    if (!rst_n) begin
      sstate <= SLV_IDLE; SResp <= 2'd0; SRespLast <= 1'b0; SData <= 32'd0;
      s_addr <= 32'd0; s_len <= 5'd1; s_idx <= 5'd0; s_dly <= 2'd0;
      s_err  <= 1'b0;  s_posted <= 1'b0;
    end else begin
      SResp     <= 2'd0;                    // default : no response
      SRespLast <= 1'b0;
      case (sstate)
        SLV_IDLE : if (slv_acc) begin
          s_addr <= MAddr; s_len <= MBurstLength; s_idx <= 5'd1;
          s_err  <= (MAddr >= 32'h0000_0100);
          if (MCmd == 3'd2) begin                    // RD
            s_dly <= 2'd2; sstate <= SLV_RDWAIT;
          end else begin                             // WR / WRNP : beat 0
            if (MAddr < 32'h100) smem[MAddr[7:2]] <= MData;
            s_posted <= (MCmd == 3'd5);
            if (MBurstLength > 5'd1)      sstate <= SLV_WRB;
            else if (MCmd == 3'd5)        sstate <= SLV_IDLE;   // posted : done
            else begin s_dly <= 2'd2; sstate <= SLV_WRWAIT; end
          end
        end
        SLV_WRB : if (slv_acc) begin                 // write beats 1..n-1
          if (!s_err) smem[s_addr[7:2] + s_idx] <= MData;
          if (s_idx == s_len - 5'd1) begin
            if (s_posted) sstate <= SLV_IDLE;
            else begin s_dly <= 2'd2; sstate <= SLV_WRWAIT; end
          end
          s_idx <= s_idx + 5'd1;
        end
        SLV_WRWAIT : begin
          if (s_dly > 2'd1) s_dly <= s_dly - 2'd1;
          else begin
            SResp     <= s_err ? 2'd2 : 2'd1;        // ERR / DVA
            SRespLast <= 1'b1;
            sstate    <= SLV_IDLE;
          end
        end
        SLV_RDWAIT : begin
          if (s_dly > 2'd1) s_dly <= s_dly - 2'd1;
          else begin s_idx <= 5'd0; sstate <= SLV_RDRESP; end
        end
        SLV_RDRESP : begin
          SResp     <= s_err ? 2'd2 : 2'd1;
          SData     <= s_err ? 32'd0 : smem[s_addr[7:2] + s_idx];
          SRespLast <= s_err | (s_idx == s_len - 5'd1);
          if (s_err || (s_idx == s_len - 5'd1)) sstate <= SLV_IDLE;
          s_idx <= s_idx + 5'd1;
        end
        default : sstate <= SLV_IDLE;
      endcase
    end
  end

  // ==================================================================
  // protocol monitors : backpressure seen / request stability
  // ==================================================================
  int bp_cycles = 0, stab_viol = 0;
  logic prev_hold = 0;
  logic [2:0]  prev_mcmd;
  logic [31:0] prev_maddr;
  always @(posedge clk) begin
    if (rst_n) begin
      if (MCmd != 3'd0 && !SCmdAccept) begin
        bp_cycles++;
        if (prev_hold && (MCmd !== prev_mcmd || MAddr !== prev_maddr)) begin
          stab_viol++;
          $display("ERROR: request not held stable under backpressure @%0t", $time);
        end
        prev_hold  = 1'b1;
        prev_mcmd  = MCmd;
        prev_maddr = MAddr;
      end else prev_hold = 1'b0;
    end
  end

  // ==================================================================
  // cpu-side tasks
  // ==================================================================
  task automatic cpu_idle;
    begin
      @(negedge clk);
      req_valid <= 1'b0;
    end
  endtask

  // non-posted/posted write of len words (base, base+1, ...) ; waits resp
  task automatic cpu_write(input logic [31:0] addr, input logic [4:0] len,
                           input logic [31:0] base, input logic posted,
                           input logic exp_err);
    int i, to;
    begin
      @(negedge clk);
      req_valid <= 1'b1; req_rw <= 1'b1; req_posted <= posted;
      req_addr <= addr; req_len <= len; req_wdata <= base;
      to = 0;
      while (to < 100) begin
        @(posedge clk);
        if (req_ready) to = 200; else to++;
      end
      if (to != 200) begin errors++; $display("ERROR: desc accept timeout @%h", addr); end
      for (i = 1; i < len; i++) begin
        @(negedge clk);
        req_wdata <= base + i;
        to = 0;
        while (to < 100) begin
          @(posedge clk);
          if (req_ready) to = 200; else to++;
        end
        if (to != 200) begin errors++; $display("ERROR: wdata accept timeout beat %0d", i); end
      end
      cpu_idle();
      // completion response
      to = 0;
      while (to < 200) begin
        @(posedge clk);
        if (resp_valid) to = 300; else to++;
      end
      if (to != 300) begin
        errors++; $display("ERROR: write resp timeout @%h", addr);
      end else if (resp_err !== exp_err) begin
        errors++; $display("ERROR: write resp_err=%b exp %b @%h", resp_err, exp_err, addr);
      end
    end
  endtask

  // read of len words, expects base+i in order ; exp_err for error injection
  task automatic cpu_read(input logic [31:0] addr, input logic [4:0] len,
                          input logic [31:0] base, input logic exp_err);
    int i, to;
    begin
      @(negedge clk);
      req_valid <= 1'b1; req_rw <= 1'b0; req_posted <= 1'b0;
      req_addr <= addr; req_len <= len; req_wdata <= 32'd0;
      to = 0;
      while (to < 100) begin
        @(posedge clk);
        if (req_ready) to = 200; else to++;
      end
      if (to != 200) begin errors++; $display("ERROR: rd desc accept timeout @%h", addr); end
      cpu_idle();
      if (exp_err) begin
        to = 0;
        while (to < 200) begin
          @(posedge clk);
          if (resp_valid) to = 300; else to++;
        end
        if (to != 300) begin
          errors++; $display("ERROR: err read resp timeout @%h", addr);
        end else if (!resp_err) begin
          errors++; $display("ERROR: expected resp_err @%h", addr);
        end
      end else begin
        for (i = 0; i < len; i++) begin
          to = 0;
          while (to < 200) begin
            @(posedge clk);
            if (resp_valid) to = 300; else to++;
          end
          if (to != 300) begin
            errors++; $display("ERROR: read beat %0d timeout @%h", i, addr);
          end else begin
            if (resp_err) begin
              errors++; $display("ERROR: unexpected resp_err on read beat %0d", i);
            end
            if (resp_rdata !== base + i) begin
              errors++; $display("ERROR: read data beat %0d exp %h got %h",
                                 i, base + i, resp_rdata);
            end
          end
        end
      end
    end
  endtask

  // ==================================================================
  // test sequence
  // ==================================================================
  int to;

  initial begin
    req_valid = 0; req_rw = 0; req_posted = 0; req_addr = 0;
    req_len = 1; req_wdata = 0;
    SCmdAccept = 0; SResp = 0; SData = 0; SRespLast = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // CHECK 1: reset / idle state
    if (MCmd !== 3'd0 || req_ready !== 1'b1 || resp_valid !== 1'b0 || irq !== 1'b0) begin
      errors++; $display("ERROR: bad reset state MCmd=%0d rdy=%b rv=%b irq=%b",
                         MCmd, req_ready, resp_valid, irq);
    end

    // CHECK 2: single non-posted write + single read (data path)
    cpu_write(32'h0000_0010, 5'd1, 32'hDEAD_BEEF, 1'b0, 1'b0);
    cpu_read (32'h0000_0010, 5'd1, 32'hDEAD_BEEF, 1'b0);

    // CHECK 3: write burst len 4 + read burst len 4 (in order)
    cpu_write(32'h0000_0020, 5'd4, 32'hA000_0000, 1'b0, 1'b0);
    cpu_read (32'h0000_0020, 5'd4, 32'hA000_0000, 1'b0);

    // CHECK 4: posted write (WRNP) -- completion without SResp; verify by read
    cpu_write(32'h0000_0030, 5'd1, 32'hCAFE_0001, 1'b1, 1'b0);
    cpu_read (32'h0000_0030, 5'd1, 32'hCAFE_0001, 1'b0);

    // CHECK 5: consecutive transactions back-to-back
    cpu_write(32'h0000_0040, 5'd1, 32'hB000_0001, 1'b0, 1'b0);
    cpu_write(32'h0000_0044, 5'd1, 32'hB000_0002, 1'b0, 1'b0);
    cpu_read (32'h0000_0040, 5'd1, 32'hB000_0001, 1'b0);
    cpu_read (32'h0000_0044, 5'd1, 32'hB000_0002, 1'b0);

    // CHECK 6: SCmdAccept backpressure really occurred & request held stable
    if (bp_cycles == 0) begin
      errors++; $display("ERROR: SCmdAccept backpressure never observed");
    end
    if (stab_viol != 0) begin
      errors++; $display("ERROR: %0d request-stability violations", stab_viol);
    end

    // CHECK 7: error injection -- reserved region -> SResp=ERR -> resp_err + irq
    cpu_read (32'h0000_0100, 5'd1, 32'h0, 1'b1);
    cpu_write(32'h0000_0108, 5'd1, 32'hFFFF_FFFF, 1'b0, 1'b1);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after SResp=ERR");
    end

    // CHECK 8: timeout -- dead region never asserts SCmdAccept
    //          (64 clk) -> resp_err + irq, MCmd returns to IDLE
    @(negedge clk);
    req_valid <= 1'b1; req_rw <= 1'b0; req_posted <= 1'b0;
    req_addr <= 32'hFFFF_0000; req_len <= 5'd1; req_wdata <= 32'd0;
    to = 0;
    while (to < 100) begin
      @(posedge clk);
      if (req_ready) to = 200; else to++;
    end
    cpu_idle();
    to = 0;
    while (to < 200) begin
      @(posedge clk);
      if (resp_valid) to = 300; else to++;
    end
    if (to != 300) begin
      errors++; $display("ERROR: timeout abort never signalled");
    end else if (!resp_err) begin
      errors++; $display("ERROR: timeout abort missing resp_err");
    end
    @(posedge clk);
    if (MCmd !== 3'd0) begin
      errors++; $display("ERROR: MCmd not IDLE after timeout abort");
    end
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after timeout");
    end

    // CHECK 9: recovery -- normal transaction still works after abort
    cpu_write(32'h0000_0050, 5'd1, 32'h1234_5678, 1'b0, 1'b0);
    cpu_read (32'h0000_0050, 5'd1, 32'h1234_5678, 1'b0);

    repeat (2) @(posedge clk);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 130 randomized transactions through the CPU-side port: single/burst
    // reads and writes (len 1..8, len=0 -> 1 clamp), posted writes,
    // len>8 clamp (+ irq, custom 8-word flow), reserved-region ERR
    // (resp_err + sticky irq), dead-region 64-clk timeout aborts (+ irq)
    // with recovery checks. Read data predicted by a shadow of the slave
    // model memory. Reuses the bounded cpu_write/cpu_read tasks.
    begin : crv_phase
      int n_wr = 0, n_rd = 0, n_np = 0, n_err = 0, n_to = 0, n_clamp = 0;
      logic [31:0] sh_smem [0:63];
      logic [31:0] exp_c [0:15];
      logic [31:0] ba, base_v;
      logic [4:0]  len_v;
      int roll;
      for (int w = 0; w < 64; w++) sh_smem[w] = 32'h0;
      // seed the slave-model memory (write every word once)
      for (int w = 0; w < 64; w += 4) begin
        base_v = $urandom;
        cpu_write(w*4, 5'd4, base_v, 1'b1, 1'b0);   // posted bursts
        for (int j = 0; j < 4; j++) sh_smem[w+j] = base_v + j;
      end
      for (int t = 0; t < 130; t++) begin
        roll = $urandom_range(0, 11);
        len_v = $urandom_range(1, 8);
        base_v = $urandom;
        if (roll < 4) begin
          // write burst in valid space, update shadow
          ba = {$urandom_range(0, 56), 2'b00};
          if (ba[7:2] + len_v > 63) len_v = 63 - ba[7:2];
          cpu_write(ba, len_v, base_v, (roll == 3), 1'b0);
          for (int j = 0; j < len_v; j++) sh_smem[ba[7:2]+j] = base_v + j;
          if (roll == 3) n_np++; else n_wr++;
        end else if (roll < 8) begin
          // read burst, data predicted from the shadow
          ba = {$urandom_range(0, 56), 2'b00};
          if (ba[7:2] + len_v > 63) len_v = 63 - ba[7:2];
          for (int j = 0; j < len_v; j++) begin
            exp_c[j] = sh_smem[ba[7:2]+j];
          end
          // cpu_read checks base+i: use per-beat loop with exact shadow data
          begin
            int i2, to2;
            @(negedge clk);
            req_valid <= 1'b1; req_rw <= 1'b0; req_posted <= 1'b0;
            req_addr <= ba; req_len <= len_v; req_wdata <= 32'd0;
            to2 = 0;
            while (to2 < 100) begin
              @(posedge clk); if (req_ready) to2 = 200; else to2++;
            end
            cpu_idle();
            for (i2 = 0; i2 < len_v; i2++) begin
              to2 = 0;
              while (to2 < 200) begin
                @(posedge clk); if (resp_valid) to2 = 300; else to2++;
              end
              if (to2 != 300) begin
                errors++; $display("ERROR: CRV read beat timeout t=%0d i=%0d", t, i2);
              end else if (resp_rdata !== exp_c[i2]) begin
                errors++; $display("ERROR: CRV read t=%0d i=%0d got=%h exp=%h",
                                   t, i2, resp_rdata, exp_c[i2]);
              end
            end
          end
          n_rd++;
        end else if (roll < 10) begin
          // reserved region -> SResp=ERR -> resp_err (+ sticky irq)
          ba = 32'h0000_0100 + ($urandom & 32'h00FF_FFFF); // wide bits
          if (roll == 8) cpu_write(ba, 5'd1, base_v, 1'b0, 1'b1);
          else           cpu_read (ba, 5'd1, 32'h0, 1'b1);
          n_err++;
        end else if (roll == 10) begin
          // len clamp: descriptor len>8, DUT clamps to 8 (custom flow)
          int i3, to3;
          ba = {$urandom_range(0, 55), 2'b00};
          @(negedge clk);
          req_valid <= 1'b1; req_rw <= 1'b1; req_posted <= 1'b0;
          req_addr <= ba; req_len <= 5'd9 + $urandom_range(0, 22);
          req_wdata <= base_v;
          to3 = 0;
          while (to3 < 100) begin
            @(posedge clk); if (req_ready) to3 = 200; else to3++;
          end
          for (i3 = 1; i3 < 8; i3++) begin
            @(negedge clk); req_wdata <= base_v + i3;
            to3 = 0;
            while (to3 < 100) begin
              @(posedge clk); if (req_ready) to3 = 200; else to3++;
            end
          end
          cpu_idle();
          to3 = 0;
          while (to3 < 200) begin
            @(posedge clk); if (resp_valid) to3 = 300; else to3++;
          end
          if (to3 != 300) begin
            errors++; $display("ERROR: CRV clamp write resp timeout t=%0d", t);
          end
          for (i3 = 0; i3 < 8; i3++) sh_smem[ba[7:2]+i3] = base_v + i3;
          n_clamp++;
        end else begin
          // dead region -> 64-clk timeout abort -> resp_err + irq
          int to4;
          @(negedge clk);
          req_valid <= 1'b1; req_rw <= 1'b0; req_posted <= 1'b0;
          req_addr <= 32'hFFFF_0000; req_len <= 5'd1; req_wdata <= 32'd0;
          to4 = 0;
          while (to4 < 100) begin
            @(posedge clk); if (req_ready) to4 = 200; else to4++;
          end
          cpu_idle();
          to4 = 0;
          while (to4 < 200) begin
            @(posedge clk); if (resp_valid) to4 = 300; else to4++;
          end
          if (to4 != 300) begin
            errors++; $display("ERROR: CRV timeout abort never signalled t=%0d", t);
          end else if (!resp_err) begin
            errors++; $display("ERROR: CRV timeout abort missing resp_err t=%0d", t);
          end
          @(posedge clk);
          if (MCmd !== 3'd0) begin
            errors++; $display("ERROR: CRV MCmd not IDLE after abort t=%0d", t);
          end
          n_to++;
        end
      end
      if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq not sticky after error classes");
      end
      // recovery after aborts + shadow re-verify
      cpu_write(32'h0000_0004, 5'd2, 32'hEC00_0000, 1'b0, 1'b0);
      sh_smem[1] = 32'hEC00_0000; sh_smem[2] = 32'hEC00_0001;
      for (int w = 0; w < 64; w += 9) begin
        int to5;
        @(negedge clk);
        req_valid <= 1'b1; req_rw <= 1'b0; req_posted <= 1'b0;
        req_addr <= w*4; req_len <= 5'd1; req_wdata <= 32'd0;
        to5 = 0;
        while (to5 < 100) begin
          @(posedge clk); if (req_ready) to5 = 200; else to5++;
        end
        cpu_idle();
        to5 = 0;
        while (to5 < 200) begin
          @(posedge clk); if (resp_valid) to5 = 300; else to5++;
        end
        if (to5 != 300 || resp_rdata !== sh_smem[w]) begin
          errors++; $display("ERROR: CRV verify w=%0d got=%h exp=%h",
                             w, resp_rdata, sh_smem[w]);
        end
      end
      $display("CRV: 146 txns (seed=16 wr=%0d rd=%0d posted=%0d err=%0d clamp=%0d timeout=%0d)",
               n_wr, n_rd, n_np, n_err, n_clamp, n_to);
    end
`endif

    if (errors == 0) $display("TEST PASSED: OCP_IP_Open_Core_Protocol");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < OCPI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, OCPI_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave
  initial begin
    repeat (4000) #1000;
    $display("TIMEOUT"); $finish;
  end
`else
  // TIMEOUT guard
  initial begin
    #500000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
`endif

endmodule
