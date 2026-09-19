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
    if (errors == 0) $display("TEST PASSED: OCP_IP_Open_Core_Protocol");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // TIMEOUT guard
  initial begin
    #500000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
