// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for Toggle_Mode_NAND_top -- NAND host model
// The dq bus is modelled as tri1 (pull-up); the host drives it only
// during command/address/data-in cycles, the DUT drives it during
// data-output cycles while re_n is low.
// Checks:
//   1. reset state: rb_n=1, irq=0, dq released (reads pulled-up FF)
//   2. Read ID (0x90): 5-byte ID compare
//   3. Page Program (0x80+0x10) -> Page Read (0x00+0x30) readback
//      compare on 3 pages; program rb_n busy ~200 clk, read ~25 clk
//   4. Read Status (0x70): bit6 ready / bit0 fail semantics
//   5. Block Erase (0x60+0xD0): rb_n ~1000 clk, erased page reads FF
//   6. protected block (pages 12..15) program -> status fail, array FF
//   7. bad command sequence injection (0x30 / unknown 0xAB in idle)
//      -> ignored + irq; 0xFF Reset clears irq
`timescale 1ns/1ps
module Toggle_Mode_NAND_tb;

  logic clk = 0, rst_n = 0;
  logic ce_n, cle, ale, we_n, re_n;
  tri1  [7:0] dq;
  wire        dqs;
  logic       rb_n, irq;

  logic       host_oe;
  logic [7:0] host_dq;
  assign dq = host_oe ? host_dq : 8'hzz;

  int errors = 0;

  localparam logic [39:0] DEV_ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};

  Toggle_Mode_NAND_top dut (
    .clk(clk), .rst_n(rst_n),
    .ce_n(ce_n), .cle(cle), .ale(ale), .we_n(we_n), .re_n(re_n),
    .dq(dq), .dqs(dqs), .rb_n(rb_n), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  //
  // FSM probe path (DUT is not a wrapper; probe the RTL directly):
  //   dut.state -- state_t, 10 states ST_CMD..ST_STOUT
  // =====================================================================
  localparam int CRV_FSM_TOTAL = 10;  // ST_CMD..ST_STOUT
  logic [9:0] fsm_seen = '0;          // visited-state bitmap
  wire  [3:0] dut_state = dut.state;

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

  // FSM coverage: sample DUT state register every clock
  always @(posedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  int rst_cyc = 0;   // consecutive reset clocks (skip the fall-edge cycle)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (from the 2nd reset clock on)
      if (rst_cyc >= 1)
        sva_check(rb_n === 1'b1 && irq === 1'b0 && dut_state === 4'd0,
                  "A1 reset: rb_n high, irq low, ST_CMD");
      rst_cyc <= rst_cyc + 1;
    end else begin
      rst_cyc <= 0;
      // A2: state register holds a legal enum encoding
      sva_check(dut_state <= 4'd9, "A2 state encoding legal");
      // A3: rb_n low only in the busy state
      sva_check(rb_n === 1'b1 || (dut_state == 4'd8), "A3 rb_n low implies BUSY");
      // A4: dq pad driven only in data-output states
      sva_check(!dut.drive_en || (dut_state == 4'd2) || (dut_state == 4'd8) ||
                (dut_state == 4'd9), "A4 dq drive only in output states");
      // A5: outside BUSY the target is always ready
      sva_check((dut_state == 4'd8) || (rb_n === 1'b1), "A5 ready outside BUSY");
      // A6: dqs is driven only when dq is driven
      sva_check((dqs === 1'bz) || (dq !== 8'hzz), "A6 dqs driven implies dq driven");
      // A7: address-cycle counter within the 5-cycle protocol bound
      sva_check(dut.addr_cnt <= 3'd4, "A7 addr_cnt <= 4");
      // A8: busy counter within the erase-time bound
      sva_check(dut.busy_cnt <= 10'd999, "A8 busy_cnt <= 999");
    end
  end
`endif

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
    end
  endtask

  // one host write cycle (command / address / data-in selected by cle/ale)
  task automatic h_wr(input logic [7:0] d, input logic c, input logic a);
    begin
      @(negedge clk); ce_n = 0; cle = c; ale = a;
                      host_oe = 1; host_dq = d; we_n = 1;
      repeat (2) @(negedge clk); we_n = 0;          // setup
      repeat (4) @(negedge clk); we_n = 1;          // hold, latch on rise
      repeat (4) @(negedge clk);                    // keep dq stable for sync
      cle = 0; ale = 0; host_oe = 0;
    end
  endtask

  // one host read cycle (data out while re_n low)
  task automatic h_rd(output logic [7:0] d);
    begin
      @(negedge clk); ce_n = 0; cle = 0; ale = 0; host_oe = 0; re_n = 1;
      repeat (2) @(negedge clk); re_n = 0;
`ifdef VERILATOR
      // Drift-immune sampling: with Verilator 5.006 --timing, coroutine
      // resumes can lag clock edges by whole cycles in bursts (scheduler
      // pathology), so fixed edge counts drift out of the DUT drive
      // window (dq reads back as 2-state 00). drive_en and re_n are
      // levels, so waiting on them is skew-immune; dq is stable for the
      // whole window and ptr advances as re_s rises (drive_en falls).
      wait (dut.drive_en === 1'b1);
      #1;
      d = dq;                                       // sample while driven
      re_n = 1;
      wait (dut.drive_en === 1'b0);                 // ptr has advanced
      repeat (2) @(negedge clk);
`else
      repeat (4) @(negedge clk);                    // pad turnaround + sync
      d = dq;                                       // sample while re_n low
      @(negedge clk); re_n = 1;
      repeat (4) @(negedge clk);                    // let ptr advance
`endif
    end
  endtask

  // data pattern generator (8-bit truncation)
  function automatic logic [7:0] pat(input logic [7:0] s, input int i);
    return s + i * 8'h11;
  endfunction

  task automatic h_cmd(input logic [7:0] d);  h_wr(d, 1'b1, 1'b0); endtask
  task automatic h_addr(input logic [7:0] d); h_wr(d, 1'b0, 1'b1); endtask
  task automatic h_din(input logic [7:0] d);  h_wr(d, 1'b0, 1'b0); endtask

  // wait for a busy pulse and return its width in clk cycles
  task automatic busy_width(output int w);
    begin
      w = 0;
      while (rb_n !== 1'b0) @(posedge clk);         // wait for busy
      while (rb_n === 1'b0) begin @(posedge clk); w++; end
    end
  endtask

  task automatic nand_reset;
    begin
      rst_n = 0;
      ce_n = 1; cle = 0; ale = 0; we_n = 1; re_n = 1;
      host_oe = 0; host_dq = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic read_id;
    logic [7:0] b;
    begin
      h_cmd(8'h90);
      h_addr(8'h00);
      for (int i = 0; i < 5; i++) begin
        h_rd(b);
        check(b === DEV_ID[39-8*i -: 8],
              $sformatf("Read ID byte %0d: got %02h", i, b));
      end
    end
  endtask

  task automatic read_status(output logic [7:0] s);
    begin
      h_cmd(8'h70);
      h_rd(s);
    end
  endtask

  task automatic page_program(input logic [3:0] page,
                              input logic [5:0] col,
                              input logic [7:0] seed,
                              input int n,
                              output int busy);
    begin
      h_cmd(8'h80);
      h_addr({2'b00, col});       // col cycle 0
      h_addr(8'h00);              // col cycle 1
      h_addr({4'b0000, page});    // row cycle 0
      h_addr(8'h00);              // row cycle 1
      h_addr(8'h00);              // row cycle 2
      for (int i = 0; i < n; i++) h_din(seed + 8'(i*8'h11));
      h_cmd(8'h10);
      busy_width(busy);
    end
  endtask

  task automatic page_read(input logic [3:0] page,
                           input logic [5:0] col,
                           input logic [7:0] seed,
                           input int n,
                           input logic [7:0] fill,
                           input logic use_fill,
                           output int busy);
    logic [7:0] b;
    begin
      h_cmd(8'h00);
      h_addr({2'b00, col});
      h_addr(8'h00);
      h_addr({4'b0000, page});
      h_addr(8'h00);
      h_addr(8'h00);
      h_cmd(8'h30);
      busy_width(busy);
      check(busy >= 20 && busy <= 30,
            $sformatf("read busy %0d clk (expected ~25)", busy));
      for (int i = 0; i < n; i++) begin
        h_rd(b);
        if (use_fill) check(b === fill,
              $sformatf("page %0d byte %0d: got %02h exp %02h", page, i, b, fill));
        else check(b === pat(seed, i),
              $sformatf("page %0d byte %0d: got %02h", page, i, b));
      end
    end
  endtask

`ifdef VERILATOR
  // ---- v2.5 CRV helpers ------------------------------------------------
  // page read with compare against the CRV scoreboard model (the directed
  // page_read task checks against its own pattern/fill arguments instead)
  task automatic crv_read_cmp(input logic [3:0] page, input logic [5:0] col,
                              input int n, ref logic [7:0] model [0:15][0:63]);
    logic [7:0] b;
    int bw;
    begin
      h_cmd(8'h00);
      h_addr({2'b00, col});
      h_addr(8'h00);
      h_addr({4'b0000, page});
      h_addr(8'h00);
      h_addr(8'h00);
      h_cmd(8'h30);
      busy_width(bw);
      if (bw < 20 || bw > 30) begin
        errors++; $display("ERROR: CRV read busy %0d clk (expected ~25)", bw);
      end
      for (int i = 0; i < n; i++) begin
        h_rd(b);
        if (b !== model[page][6'(col + i)]) begin
          errors++;
          $display("ERROR: CRV RD p%0d col%0d got=%h exp=%h",
                   page, col + i, b, model[page][6'(col + i)]);
        end
      end
    end
  endtask

  // block erase with model update (pages 4b..4b+3 become known-erased)
  task automatic crv_erase(input logic [1:0] blk,
                           ref logic [7:0] model [0:15][0:63],
                           ref logic [15:0] known);
    int bw;
    begin
      h_cmd(8'h60);
      h_addr({6'b000000, blk, 2'b00});    // row = first page of block
      h_addr(8'h00);
      h_addr(8'h00);
      h_cmd(8'hD0);
      busy_width(bw);
      if (bw < 990 || bw > 1010) begin
        errors++; $display("ERROR: CRV erase busy %0d clk (expected ~1000)", bw);
      end
      for (int p = 0; p < 4; p++) begin
        for (int i = 0; i < 64; i++) model[{blk, 2'(p)}][i] = 8'hFF;
        known[{blk, 2'(p)}] = 1'b1;
      end
    end
  endtask
`endif

  logic [7:0] st;
  int  bw;

  initial begin
    nand_reset;

    // -- check 1: reset state --------------------------------------
    check(rb_n === 1'b1, "reset: rb_n != 1");
    check(irq === 1'b0,  "reset: irq != 0");
    check(dq === 8'hFF,  "reset: dq not released (tri1 pull-up expected)");

    // -- check 2: Read ID -------------------------------------------
    read_id;
    check(irq === 1'b0, "irq set after Read ID");

    // -- check 3: program -> readback on 3 pages ---------------------
    page_program(4'd0, 6'd0, 8'h10, 64, bw);
    check(bw >= 195 && bw <= 210,
          $sformatf("program busy %0d clk (expected ~200)", bw));
    page_program(4'd1, 6'd0, 8'hA0, 64, bw);
    page_program(4'd5, 6'd4, 8'h55, 60, bw);        // partial page @col4
    read_status(st);
    check(st === 8'h40, $sformatf("status after good prog: %02h", st));

    page_read(4'd0, 6'd0, 8'h10, 64, 8'h00, 1'b0, bw);
    page_read(4'd1, 6'd0, 8'hA0, 64, 8'h00, 1'b0, bw);
    page_read(4'd5, 6'd4, 8'h55, 60, 8'h00, 1'b0, bw);
    check(irq === 1'b0, "irq set after prog/read");

    // -- check 4: erase block 0 -> pages 0..3 all FF ------------------
    h_cmd(8'h60);
    h_addr(8'h00);                                  // row = page 0
    h_addr(8'h00);
    h_addr(8'h00);
    h_cmd(8'hD0);
    busy_width(bw);
    check(bw >= 990 && bw <= 1010,
          $sformatf("erase busy %0d clk (expected ~1000)", bw));
    read_status(st);
    check(st === 8'h40, $sformatf("status after erase: %02h", st));
    page_read(4'd0, 6'd0, 8'h00, 64, 8'hFF, 1'b1, bw);
    page_read(4'd3, 6'd0, 8'h00, 64, 8'hFF, 1'b1, bw);

    // -- check 5: protected block program -> fail, array untouched ----
    page_program(4'd12, 6'd0, 8'h77, 64, bw);
    read_status(st);
    check(st === 8'h41,
          $sformatf("status after protected prog: %02h (exp 41)", st));
    page_read(4'd12, 6'd0, 8'h00, 64, 8'hFF, 1'b1, bw); // still erased

    // -- check 6: bad command sequence injection ----------------------
    h_cmd(8'h30);                                   // confirm w/o 0x00
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "0x30 in idle: irq not raised");
    h_cmd(8'hAB);                                   // unknown opcode
    repeat (2) @(negedge clk);
    check(irq === 1'b1, "unknown cmd: irq not raised");
    h_cmd(8'hFF);                                   // reset clears irq
    busy_width(bw);
    check(irq === 1'b0, "irq not cleared by 0xFF reset");
    check(rb_n === 1'b1, "rb_n not ready after reset");
    read_id;                                        // target still alive
    check(irq === 1'b0, "irq set at end of test");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 130 randomized transactions over a page-granular scoreboard model
    // with 1->0 program semantics:
    //   ~15% block erase (blocks 0..2; model := FF, page becomes known)
    //   ~25% page program on known pages (random col/len/seed; model &=)
    //   ~30% page read on known pages (compare vs model)
    //   ~15% read status (fail bit must stay clear on legal ops)
    //   ~15% error injection: unknown opcode / out-of-sequence abort at
    //         rotating FSM sites (irq must set; 0xFF reset must clear)
    //   + 1 protected-block erase (status fail) with 0xFF cleanup
    begin : crv_phase
      logic [7:0] model [0:15][0:63];
      logic [15:0] known;
      logic [7:0] seed, b, s;
      int n_er = 0, n_pg = 0, n_rd = 0, n_st = 0, n_bad = 0;
      int roll, page, col, len, site, nkw;
      logic [7:0] badops [0:7];
      badops[0] = 8'h01; badops[1] = 8'h31; badops[2] = 8'h61;
      badops[3] = 8'h71; badops[4] = 8'h81; badops[5] = 8'h91;
      badops[6] = 8'hAB; badops[7] = 8'hD1;
      known = '0;
      for (int t = 0; t < 130; t++) begin
        roll = $urandom_range(0, 19);
        nkw = 0;
        for (int p = 0; p < 16; p++) nkw += known[p];
        if (roll < 3 || nkw == 0) begin
          // block erase on blocks 0..2 (protected block 3 covered below)
          n_er++;
          crv_erase(2'($urandom_range(0, 2)), model, known);
        end else if (roll < 8) begin
          // page program on a random known page, boundary-weighted col
          n_pg++;
          page = $urandom_range(0, 15);
          while (!known[page]) page = $urandom_range(0, 15);
          col  = $urandom_range(0, 63);
          if ($urandom_range(0, 9) < 3) col = ($urandom_range(0, 1) == 0) ? 0 : 60;
          len  = 1 + $urandom_range(0, 7);
          if (col + len > 64) len = 64 - col;
          seed = $urandom_range(0, 255);
          page_program(4'(page), 6'(col), seed, len, bw);
          for (int i = 0; i < len; i++)
            model[page][6'(col + i)] = model[page][6'(col + i)] & pat(seed, i);
        end else if (roll < 14) begin
          // page read + model compare
          n_rd++;
          page = $urandom_range(0, 15);
          while (!known[page]) page = $urandom_range(0, 15);
          col  = $urandom_range(0, 63);
          if ($urandom_range(0, 9) < 3) col = ($urandom_range(0, 1) == 0) ? 0 : 60;
          len  = 1 + $urandom_range(0, 7);
          if (col + len > 64) len = 64 - col;
          crv_read_cmp(4'(page), 6'(col), len, model);
        end else if (roll < 17) begin
          // read status: ready=1, fail=0 after legal operations
          n_st++;
          read_status(s);
          if (s !== 8'h40) begin
            errors++; $display("ERROR: CRV status got=%h exp=40", s);
          end
        end else begin
          // error injection: unknown opcode in idle, or out-of-sequence
          // abort at a rotating FSM site; irq must set and 0xFF must clear
          n_bad++;
          site = n_bad % 6;
          case (site)
            0: begin                               // unknown opcode in ST_CMD
              h_cmd(badops[$urandom_range(0, 7)]);
            end
            1: begin                               // abort Read ID addr phase
              h_cmd(8'h90);
              h_cmd(badops[$urandom_range(0, 7)]);
            end
            2: begin                               // abort read addr phase
              h_cmd(8'h00);
              h_addr(8'h00);
              h_cmd(badops[$urandom_range(0, 7)]);
            end
            3: begin                               // abort WAIT30 confirm
              h_cmd(8'h00);
              h_addr(8'h00); h_addr(8'h00); h_addr(8'h00);
              h_addr(8'h00); h_addr(8'h00);
              h_cmd(badops[$urandom_range(0, 7)]);
            end
            4: begin                               // abort program data phase
              h_cmd(8'h80);
              h_addr(8'h00); h_addr(8'h00); h_addr(8'h00);
              h_addr(8'h00); h_addr(8'h00);
              h_din(8'h55);
              h_cmd(badops[$urandom_range(0, 7)]);
            end
            default: begin                         // abort erase confirm
              h_cmd(8'h60);
              h_addr(8'h00); h_addr(8'h00); h_addr(8'h00);
              h_cmd(badops[$urandom_range(0, 7)]);
            end
          endcase
          repeat (2) @(negedge clk);
          if (irq !== 1'b1) begin
            errors++; $display("ERROR: CRV bad cmd site %0d: irq not raised", site);
          end
          h_cmd(8'hFF);                            // reset clears irq
          busy_width(bw);
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq not cleared by 0xFF");
          end
        end
      end
      // protected-block erase: status fail bit, array untouched; then
      // 0xFF reset clears the fail flag (directed covers protected prog)
      begin
        int bw2;
        h_cmd(8'h60);
        h_addr(8'h0C);                            // row = page 12 (block 3)
        h_addr(8'h00);
        h_addr(8'h00);
        h_cmd(8'hD0);
        busy_width(bw2);
        if (bw2 < 990 || bw2 > 1010) begin
          errors++; $display("ERROR: CRV prot erase busy %0d clk", bw2);
        end
        read_status(s);
        if (s !== 8'h41) begin
          errors++; $display("ERROR: CRV status after prot erase got=%h exp=41", s);
        end
        h_cmd(8'hFF);
        busy_width(bw2);
        read_status(s);
        if (s !== 8'h40) begin
          errors++; $display("ERROR: CRV status after 0xFF got=%h exp=40", s);
        end
      end
      $display("CRV: 130 txns (erase=%0d prog=%0d read=%0d status=%0d bad=%0d) + prot-erase",
               n_er, n_pg, n_rd, n_st, n_bad);
    end
`endif

    if (errors == 0) $display("TEST PASSED: Toggle_Mode_NAND");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CRV_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CRV_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Random phase adds traffic: extend the guard. The timeout is chunked
  // into 1-us delays: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (see docs/COVERAGE.md note 1).
  initial begin
    repeat (80) #100000;  // 8 ms in 100-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #5000000;
    $display("TIMEOUT");
    $finish;
  end
`endif

endmodule
