// SPDX-License-Identifier: Apache-2.0
// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module USB4_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

`ifdef VERILATOR
  wire busy, irq;   // v2.5: observed for assertions/self-check (Verilator only)
`endif
  USB4_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx),
`ifdef VERILATOR
    .busy(busy), .irq(irq));
`else
    .busy(), .irq());
`endif
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int USB4_FSM_TOTAL = 5;  // rstate {R_IDLE,R_BYTE} + tstate {T_IDLE,T_PKT,T_END}
  logic [4:0] fsm_seen = '0;           // visited-state bitmap
  wire  [1:0] dut_rstate = dut.rstate; // hierarchical FSM probes
  wire  [1:0] dut_tstate = dut.tstate;

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

  // irq/rx_done pulse counter for the CRV self-checks
  int irq_cnt = 0;
  always @(posedge clk) if (irq) irq_cnt <= irq_cnt + 1;
`ifdef CRV_DEBUG
  logic err_qq = 0;
  logic [1:0] rs_qq = 0;
  always @(posedge clk) begin
    if (dut.rx_err && !err_qq)
      $display("DBG rx_err set @%0t rstate=%0d ridx=%0d len_q=%0d rsh=%h",
               $time, dut.rstate, dut.ridx, dut.len_q, dut.rsh);
    err_qq <= dut.rx_err;
    if (dut.rstate == 1 && rs_qq == 0)
      $display("DBG frame start @%0t tstate=%0d", $time, dut.tstate);
    if (dut.rstate == 0 && rs_qq == 1)
      $display("DBG frame end @%0t", $time);
    rs_qq <= dut.rstate;
    if (dut.rx_done) $display("DBG rx_done @%0t", $time);
  end
`endif

  // FSM coverage: sample both DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_rstate]     <= 1'b1;
    fsm_seen[2 + dut_tstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic irq_q = 0, err_q = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(busy === 1'b0 && irq === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: both state registers hold legal enum encodings
      sva_check(dut_rstate <= 2'd1 && dut_tstate <= 2'd2, "A2 state encoding legal");
      // A3: busy flag consistent with RX/TX FSM states
      sva_check(busy === ((dut_rstate != 2'd0) || (dut_tstate != 2'd0)),
                "A3 busy matches FSM activity");
      // A4: irq (rx_done) is a single-cycle pulse
      sva_check(!(irq && irq_q), "A4 irq single-cycle pulse");
      // A5: rx_err is sticky once set (cleared only by reset)
      sva_check(!err_q || dut.rx_err, "A5 rx_err sticky");
      // A6: tx line never X
      sva_check(tx !== 1'bx, "A6 tx not X");
      // A7: device pulls tx low only while its TX output stage is enabled
      sva_check((tx !== 1'b0) || (dut.oe_q === 1'b1), "A7 tx low implies oe_q");
    end
    irq_q <= irq;
    err_q <= dut.rx_err;
  end

  // ---- CRV frame tasks (error injection) ------------------------------
  // cmode: 0 = good frame, 1 = corrupt CRC32, 2 = corrupt END byte,
  //        3 = wrong STP byte (rx_err set but frame completes -> echo)
  task automatic crv_send(input int plen, input int cmode);
    logic [31:0] c; logic [7:0] fb;
    begin
      repeat (20) #(BIT);   // inter-frame gap: let echo END/T_END fully retire
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = (cmode == 3) ? 8'h00 : 8'hFB;
      for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c; if (cmode == 1) c = c ^ 32'h5A5A5A5A;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = (cmode == 2) ? 8'h00 : 8'hFD;
      for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  // one CRV transaction with self-check (echo compare / silence check)
  logic [7:0] exp_hdr [0:7];
  logic [7:0] exp_pl  [0:7];
  task automatic crv_txn(input int plen, input int cmode);
    int rl;
    begin
      for (int i=0;i<8;i++) begin exp_hdr[i] = hdr[i]; exp_pl[i] = pl[i]; end
      irq_cnt = 0;
      crv_send(plen, cmode);
      if (cmode == 0 || cmode == 3) begin
        // good / wrong-STP frame: echo expected, content must match
        recv_tlp(rl);
        if (rl !== plen) begin
          errors++; $display("ERROR: CRV plen got=%0d exp=%0d", rl, plen);
        end
        // v2.5.1 FIXED (rtl/USB4_top.sv echo-copy loop): bound is now
        // HB+MAXB+2 so tx_mem[0..15] = buf_mem[2..17] exactly; hdr[0..3]
        // are no longer clobbered, all 8 header bytes are checked.
        for (int i=0;i<HB;i++)
          if (hdr[i] !== exp_hdr[i]) begin
            errors++; $display("ERROR: CRV hdr[%0d] got=%h exp=%h", i, hdr[i], exp_hdr[i]);
          end
        for (int i=0;i<plen;i++)
          if (pl[i] !== exp_pl[i]) begin
            errors++; $display("ERROR: CRV pl[%0d] got=%h exp=%h", i, pl[i], exp_pl[i]);
          end
        if (irq_cnt != 1) begin
          errors++; $display("ERROR: CRV irq pulses=%0d exp=1", irq_cnt);
        end
        if (cmode == 3 && dut.rx_err !== 1'b1) begin
          // wrong STP must be flagged (proves the ridx==0 rx_err assignment)
          errors++; $display("ERROR: CRV rx_err not set after wrong-STP frame");
        end
      end else begin
        // corrupt CRC / END: no rx_done, no echo, rx_err flagged.
        // Wait longer than a full echo frame (chunked short delays only:
        // a single long-pending #delay corrupts the 5.006 timing heap).
        repeat (230) #(BIT);
        if (irq_cnt != 0) begin
          errors++; $display("ERROR: CRV bad frame echoed (irq_cnt=%0d)", irq_cnt);
        end
        if (busy !== 1'b0) begin
          errors++; $display("ERROR: CRV busy stuck after bad frame");
        end
        if (dut.rx_err !== 1'b1) begin
          errors++; $display("ERROR: CRV rx_err not set after bad frame (cmode=%0d)", cmode);
        end
      end
    end
  endtask
`endif

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: USB4 plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: USB4 pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB4 rx_err set"); end
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    begin : crv_phase
      int n_good = 0, n_badcrc = 0, n_badend = 0, n_badstp = 0;
      int roll, plen_c;
      for (int t = 0; t < 100; t++) begin
        roll   = $urandom_range(0, 9);
        plen_c = $urandom_range(1, 8);          // payload 1..8 bytes
        for (int i = 0; i < 8; i++) begin
          hdr[i] = $urandom_range(0, 255);
          pl[i]  = $urandom_range(0, 255);
        end
        if (t == 0) begin
          n_good++;  crv_txn(1, 0);             // force min payload boundary
        end else if (t == 1) begin
          n_good++;  crv_txn(8, 0);             // force max payload boundary
        end else if (t == 2) begin
          // deterministic wrong-STP probe: rx_err must go 0->1 on this frame
          // (no prior error injection), proving the ridx==0 rx_err line runs
          if (dut.rx_err !== 1'b0) begin
            errors++; $display("ERROR: CRV rx_err set before first bad frame");
          end
          n_badstp++; crv_txn(plen_c, 3);
        end else if (roll < 6) begin
          n_good++;  crv_txn(plen_c, 0);
        end else if (roll < 8) begin
          n_badcrc++; crv_txn(plen_c, 1);
        end else if (roll < 9) begin
          n_badend++; crv_txn(plen_c, 2);
        end else begin
          n_badstp++; crv_txn(plen_c, 3);
        end
      end
      $display("CRV: 100 txns (good=%0d bad_crc=%0d bad_end=%0d bad_stp=%0d)",
               n_good, n_badcrc, n_badend, n_badstp);
    end
`endif
    if (errors == 0) $display("TEST PASSED: USB4");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < USB4_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, USB4_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end
`ifdef VERILATOR
  // CRV phase adds ~15 ms of lane traffic: extend the guard. The timeout
  // is chunked into 1-us delays: with Verilator 5.006 a single long-pending
  // #delay event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (see docs/COVERAGE.md note 1).
  initial begin
    repeat (30000) #1000;   // 30 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
`endif
endmodule
