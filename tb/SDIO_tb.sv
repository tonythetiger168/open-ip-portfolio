// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SDIO_top -- host model driving CMD/DAT lines
// Checks: reset idle state, CMD52 R/W readback, CMD53 block transfer with
//         CRC16, bad CRC7 injection (no response + irq), illegal command,
//         bad CRC16 injection (block discarded + irq), recovery after errors.
// -- Apache-2.0
// Open IP design implementation v2.4
// ============================================================================
`timescale 1ns/1ps
module SDIO_tb;
  logic      clk = 0, rst_n = 0, sd_clk = 0;
  tri1       cmd;                 // CMD line with pull-up (open-drain model)
  tri1 [3:0] dat;                 // DAT lines with pull-ups
  logic      irq;

  // host-side line drivers
  logic       host_cmd_oe  = 0, host_cmd_out = 1;
  logic       host_dat_oe  = 0;
`ifdef VERILATOR
  // NOTE(vlt-5.006 tristate bug): a parent-scope driver of a vector tri1
  // net whose value variable ever holds z bits is mis-resolved (driver
  // dropped from the net expression / z->0). Drive explicit 1s (= the
  // pull-up value) on unused lanes instead of z; iverilog path unchanged.
  logic [3:0] host_dat_out = 4'b1111;
`else
  logic [3:0] host_dat_out = 4'bzzzz;
`endif

  int  errors = 0;
  bit  irq_seen = 0;

  assign cmd = host_cmd_oe ? host_cmd_out : 1'bz;
  assign dat = host_dat_oe ? host_dat_out : 4'bzzzz;

  SDIO_top dut (
    .clk(clk), .rst_n(rst_n), .sd_clk(sd_clk),
    .cmd(cmd), .dat(dat), .irq(irq)
  );

  always #5  clk    = ~clk;     // 100 MHz system clock (card core ignores it)
  always #10 sd_clk = ~sd_clk;  // 50 MHz SDIO bus clock

  // edge-triggered irq monitor: catches one-sd_clk error pulses
  always @(posedge irq) irq_seen = 1'b1;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // =====================================================================
  // FSM probe: single 12-state card FSM
  localparam int SDIO_FSM_TOTAL = 12;
  logic [11:0] fsm_seen = '0;
  always @(posedge sd_clk) if (dut.state < 12) fsm_seen[dut.state] <= 1'b1;

  int sva_total = 0, sva_fail = 0;
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

  // output-invariant assertion suite (sd_clk domain, pre-NBA coherent)
  int  rst_cyc = 0;
  logic irq_q = 1'b0;
  logic [3:0] state_q = 4'd0;
  always @(posedge sd_clk) begin
    if (!rst_n) begin
      // A1: idle after reset
      if (rst_cyc > 0)
        sva_check((dut.state === 0 /*S_IDLE*/) && (irq === 1'b0) &&
                  (dut.cmd_oe === 1'b0) && (dut.dat_oe === 1'b0),
                  "A1 reset: idle");
      rst_cyc++;
    end else begin
      // A2: irq is a single-sd_clk pulse
      if (irq_q) sva_check(irq === 1'b0, "A2 irq pulse width");
      // A3: FSM encoding in range
      sva_check(dut.state < 12, "A3 state encoding valid");
      // A4: card drives CMD only during the response state (and always
      //     after its first cycle)
      if (dut.cmd_oe)
        sva_check(dut.state === 3 /*S_RSP*/, "A4a cmd_oe window");
      if ((dut.state === 3) && (dut.bit_cnt !== 7'd0))
        sva_check(dut.cmd_oe === 1'b1, "A4b cmd driven in S_RSP");
      // A5: card drives DAT only in the read-data states (one-cycle release
      //     lag into S_IDLE allowed via state_q)
      if (dut.dat_oe)
        sva_check((dut.state >= 8 && dut.state <= 11) || (state_q === 11),
                  "A5 dat_oe window");
      // A6: byte counters bounded by the 32-byte block
      sva_check((dut.wr_byte_cnt <= 7'd32) && (dut.rd_byte_cnt <= 7'd32),
                "A6 byte counters bounded");
    end
    irq_q   <= irq;
    state_q <= dut.state;
  end

  // DEBUG (temporary): trace write-data path
  int dbg_n = 0;
  always @(posedge sd_clk) begin
    if (host_dat_oe && dbg_n < 200) begin
      dbg_n++;
      $display("T st=%0d host_out=%b dat=%b", dut.state, host_dat_out, dat);
    end
  end

  // CMD53 non-incrementing variants (arg_incr=0): all bytes hit base addr
  task automatic cmd53_write_ni(input logic [16:0] addr, input int n,
                                input logic bad_crc, output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    logic [15:0] c;
    begin
      arg = {1'b1, 3'd1, 1'b0, 1'b0 /*no incr*/, addr, n[8:0]};
      host_send_cmd(6'd53, arg, 1'b0);
      host_recv_rsp(r, ok);
      if (ok && r[45:40] !== 6'd53) ok = 0;
      if (ok) begin
        c = 16'h0000;
        for (int i = 0; i < n; i++)
          for (int b = 7; b >= 0; b--) c = crc16_bit(c, txb[i][b]);
        if (bad_crc) c = c ^ 16'h00FF;
        repeat (3) @(negedge sd_clk);
        host_dat_oe  = 1'b1;
`ifdef VERILATOR
        host_dat_out = 4'b1110;
`else
        host_dat_out = 4'bzzz0;
`endif
        @(negedge sd_clk);
        for (int i = 0; i < n; i++)
          for (int b = 7; b >= 0; b--) begin
            host_dat_out[0] = txb[i][b];
            @(negedge sd_clk);
          end
        for (int b = 15; b >= 0; b--) begin
          host_dat_out[0] = c[b];
          @(negedge sd_clk);
        end
`ifdef VERILATOR
        host_dat_out = 4'b1111;
`else
        host_dat_out = 4'bzzz1;
`endif
        @(negedge sd_clk);
        host_dat_oe = 1'b0;
      end
    end
  endtask

  task automatic cmd53_read_ni(input logic [16:0] addr, input int n,
                               output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    logic [15:0] crc_calc [0:3];
    logic [15:0] crc_rcv  [0:3];
    int k;
    bit saw;
    begin
      arg = {1'b0, 3'd1, 1'b0, 1'b0 /*no incr*/, addr, n[8:0]};
      host_send_cmd(6'd53, arg, 1'b0);
      host_recv_rsp(r, ok);
      if (ok && r[45:40] !== 6'd53) ok = 0;
      if (ok) begin
        saw = 0; k = 0;
        while (k < 32 && !saw) begin
          @(posedge sd_clk); #1;
          if (dat === 4'b0000) saw = 1;
          k++;
        end
        if (!saw) begin
          ok = 0;
        end else begin
          for (int l = 0; l < 4; l++) begin
            crc_calc[l] = 16'h0000;
            crc_rcv[l]  = 16'h0000;
          end
          for (int i = 0; i < n; i++) begin
            @(posedge sd_clk); #1;
            rxb[i][7:4] = dat;
            @(posedge sd_clk); #1;
            rxb[i][3:0] = dat;
          end
          for (int i = 0; i < n; i++) begin
            for (int l = 0; l < 4; l++)
              crc_calc[l] = crc16_bit(crc_calc[l], rxb[i][4+l]);
            for (int l = 0; l < 4; l++)
              crc_calc[l] = crc16_bit(crc_calc[l], rxb[i][l]);
          end
          for (int b = 0; b < 16; b++) begin
            @(posedge sd_clk); #1;
            for (int l = 0; l < 4; l++)
              crc_rcv[l] = {crc_rcv[l][14:0], dat[l]};
          end
          @(posedge sd_clk); #1;
          if (dat !== 4'b1111) ok = 0;
          for (int l = 0; l < 4; l++)
            if (crc_rcv[l] !== crc_calc[l]) ok = 0;
        end
      end
    end
  endtask
`endif

  // ---------------- CRC helpers (independent reference model) -------------
  function automatic logic [6:0] crc7_bit(input logic [6:0] c, input logic d);
    logic fb;
    begin
      fb       = c[6] ^ d;
      crc7_bit = {c[5:3], c[2] ^ fb, c[1:0], fb};
    end
  endfunction

  function automatic logic [6:0] crc7_40(input logic [39:0] m);
    logic [6:0] c;
    begin
      c = 7'h00;
      for (int i = 39; i >= 0; i--) c = crc7_bit(c, m[i]);
      crc7_40 = c;
    end
  endfunction

  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input logic d);
    logic fb;
    begin
      fb        = c[15] ^ d;
      crc16_bit = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb};
    end
  endfunction

  // ---------------- host primitives ---------------------------------------
  // drive one 48-bit command frame on CMD (optionally corrupt the CRC7)
  task automatic host_send_cmd(input logic [5:0] idx, input logic [31:0] arg,
                               input logic corrupt);
    logic [47:0] f;
    logic [6:0]  c;
    begin
      f = {1'b0, 1'b1, idx, arg, 7'h00, 1'b1};
      c = crc7_40(f[47:8]);
      if (corrupt) c = c ^ 7'h55;
      f[7:1] = c;
      @(negedge sd_clk);
      host_cmd_oe = 1'b1;
      for (int i = 47; i >= 0; i--) begin
        host_cmd_out = f[i];
        @(negedge sd_clk);
      end
      host_cmd_oe  = 1'b0;
      host_cmd_out = 1'b1;
    end
  endtask

  // receive a 48-bit response; ok=0 on timeout or bad structure/CRC7
  task automatic host_recv_rsp(output logic [47:0] r, output logic ok);
    int k;
    bit saw;
    begin
      r = '0; ok = 0; saw = 0; k = 0;
      while (k < 64 && !saw) begin            // wait for start bit
        @(posedge sd_clk); #1;
        if (cmd === 1'b0) saw = 1;
        k++;
      end
      if (saw) begin
        r[47] = 1'b0;
        for (int i = 46; i >= 0; i--) begin
          @(posedge sd_clk); #1;
          r[i] = cmd;
        end
        if (r[46] === 1'b0 && r[0] === 1'b1 && crc7_40(r[47:8]) === r[7:1])
          ok = 1;
      end
    end
  endtask

  // inter-transaction gap (card returns to IDLE, lines released)
  task automatic gap;
    begin
      repeat (4) @(negedge sd_clk);
    end
  endtask

  // CMD52 IO_RW_DIRECT; rdata/ok valid on return
  task automatic cmd52(input logic rw, input logic [16:0] addr,
                       input logic [7:0] wdata, output logic [7:0] rdata,
                       output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    begin
      arg = {rw, 3'd1, 1'b0, 1'b0, addr, 1'b0, wdata};
      host_send_cmd(6'd52, arg, 1'b0);
      host_recv_rsp(r, ok);
      rdata = r[15:8];
      if (ok && r[45:40] !== 6'd52) ok = 0;
    end
  endtask

  // shared block buffers (iverilog-friendly, no dynamic arrays)
  logic [7:0] txb [0:31];
  logic [7:0] rxb [0:31];

  // CMD53 write: R5 response, then host shifts block on DAT0
  task automatic cmd53_write(input logic [16:0] addr, input int n,
                             input logic bad_crc, output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    logic [15:0] c;
    begin
      arg = {1'b1, 3'd1, 1'b0, 1'b1, addr, n[8:0]};
      host_send_cmd(6'd53, arg, 1'b0);
      host_recv_rsp(r, ok);
      if (ok && r[45:40] !== 6'd53) ok = 0;
      if (ok) begin
        c = 16'h0000;
        for (int i = 0; i < n; i++)
          for (int b = 7; b >= 0; b--) c = crc16_bit(c, txb[i][b]);
        if (bad_crc) c = c ^ 16'h00FF;
        repeat (3) @(negedge sd_clk);
        host_dat_oe  = 1'b1;
`ifdef VERILATOR
        host_dat_out = 4'b1110;
`else
        host_dat_out = 4'bzzz0;
`endif                 // start bit on DAT0
        @(negedge sd_clk);
        for (int i = 0; i < n; i++)
          for (int b = 7; b >= 0; b--) begin
            host_dat_out[0] = txb[i][b];
            @(negedge sd_clk);
          end
        for (int b = 15; b >= 0; b--) begin
          host_dat_out[0] = c[b];               // CRC16, MSB first
          @(negedge sd_clk);
        end
        host_dat_out = 4'bzzz1;                 // end bit
        @(negedge sd_clk);
        host_dat_oe = 1'b0;
      end
    end
  endtask

  // CMD53 read: R5 response, then card drives block on DAT[3:0]
  task automatic cmd53_read(input logic [16:0] addr, input int n,
                            output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    logic [15:0] crc_calc [0:3];
    logic [15:0] crc_rcv  [0:3];
    int k;
    bit saw;
    begin
      arg = {1'b0, 3'd1, 1'b0, 1'b1, addr, n[8:0]};
      host_send_cmd(6'd53, arg, 1'b0);
      host_recv_rsp(r, ok);
      if (ok && r[45:40] !== 6'd53) ok = 0;
      if (ok) begin
        saw = 0; k = 0;
        while (k < 32 && !saw) begin            // wait for start 4'b0000
          @(posedge sd_clk); #1;
          if (dat === 4'b0000) saw = 1;
          k++;
        end
        if (!saw) begin
          ok = 0;
        end else begin
          for (int l = 0; l < 4; l++) begin
            crc_calc[l] = 16'h0000;
            crc_rcv[l]  = 16'h0000;
          end
          for (int i = 0; i < n; i++) begin     // 2 nibbles per byte
            @(posedge sd_clk); #1;
            rxb[i][7:4] = dat;
            @(posedge sd_clk); #1;
            rxb[i][3:0] = dat;
          end
          for (int i = 0; i < n; i++) begin     // per-line reference CRC16
            for (int l = 0; l < 4; l++)
              crc_calc[l] = crc16_bit(crc_calc[l], rxb[i][4+l]);
            for (int l = 0; l < 4; l++)
              crc_calc[l] = crc16_bit(crc_calc[l], rxb[i][l]);
          end
          for (int b = 0; b < 16; b++) begin    // 16 CRC clocks, one per line
            @(posedge sd_clk); #1;
            for (int l = 0; l < 4; l++)
              crc_rcv[l] = {crc_rcv[l][14:0], dat[l]};
          end
          @(posedge sd_clk); #1;                // end pattern
          if (dat !== 4'b1111) begin
            ok = 0;
            $display("ERROR: CMD53 read end pattern got=%b exp=1111", dat);
          end
          for (int l = 0; l < 4; l++)
            if (crc_rcv[l] !== crc_calc[l]) begin
              ok = 0;
              $display("ERROR: CMD53 read CRC16 line %0d got=%h exp=%h",
                       l, crc_rcv[l], crc_calc[l]);
            end
        end
      end
    end
  endtask

  // ---------------- test sequence -----------------------------------------
  logic [16:0] a;
  logic [7:0]  d, rd;
  logic        ok;
  logic [47:0] r;

  initial begin
    rst_n = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (6) @(posedge sd_clk);

    // (a) post-reset idle state: irq low, card not driving CMD/DAT
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq not low after reset");
    end
    if (cmd !== 1'b1) begin
      errors++; $display("ERROR: CMD line not idle-high after reset");
    end
    if (dat !== 4'b1111) begin
      errors++; $display("ERROR: DAT lines not idle-high after reset");
    end

    // (b) CMD52 write + read-back, 4 rounds, distinct addresses/data
    for (int i = 0; i < 4; i++) begin
      a = 17'h0010 + i[16:0] * 17'h0007;
      d = 8'hA5 ^ (8'(i) * 8'h3C);
      cmd52(1'b1, a, d, rd, ok);
      if (!ok) begin
        errors++; $display("ERROR: CMD52 write %0d: missing/bad R5", i);
      end else if (rd !== d) begin
        errors++; $display("ERROR: CMD52 write %0d echo got=%h exp=%h", i, rd, d);
      end
      gap();
      cmd52(1'b0, a, 8'h00, rd, ok);
      if (!ok) begin
        errors++; $display("ERROR: CMD52 read %0d: missing/bad R5", i);
      end else if (rd !== d) begin
        errors++; $display("ERROR: CMD52 read %0d got=%h exp=%h", i, rd, d);
      end
      gap();
    end

    // (c) CMD53 block write of 8 bytes, then read back and compare
    for (int i = 0; i < 8; i++) txb[i] = 8'h11 * 8'(i) + 8'h42;
    cmd53_write(17'h0040, 8, 1'b0, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 write: missing/bad R5");
    end
    gap();
    cmd53_read(17'h0040, 8, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 read: missing/bad R5 or CRC16");
    end else begin
      for (int i = 0; i < 8; i++)
        if (rxb[i] !== txb[i]) begin
          errors++;
          $display("ERROR: CMD53 readback byte %0d got=%h exp=%h", i, rxb[i], txb[i]);
        end
    end
    gap();
    // cross-check one CMD53-written byte through CMD52
    cmd52(1'b0, 17'h0043, 8'h00, rd, ok);
    if (!ok || rd !== txb[3]) begin
      errors++; $display("ERROR: CMD52 cross-check of CMD53 data got=%h exp=%h",
                         rd, txb[3]);
    end
    gap();

    // (d) error injection: corrupt CRC7 -> no response + irq pulse
    irq_seen = 0;
    host_send_cmd(6'd52, {1'b0, 3'd1, 1'b0, 1'b0, 17'h0010, 1'b0, 8'h00}, 1'b1);
    host_recv_rsp(r, ok);
    if (ok) begin
      errors++; $display("ERROR: bad-CRC7 command was answered");
    end
    repeat (8) @(posedge sd_clk);
    if (!irq_seen) begin
      errors++; $display("ERROR: bad-CRC7 command did not raise irq");
    end
    gap();

    // illegal command index (CMD0) -> no response + irq pulse
    irq_seen = 0;
    host_send_cmd(6'd0, 32'h0000_0000, 1'b0);
    host_recv_rsp(r, ok);
    if (ok) begin
      errors++; $display("ERROR: illegal CMD0 was answered");
    end
    repeat (8) @(posedge sd_clk);
    if (!irq_seen) begin
      errors++; $display("ERROR: illegal CMD0 did not raise irq");
    end
    gap();

    // (e) error injection: bad CRC16 on CMD53 write -> block discarded + irq
    for (int i = 0; i < 8; i++) txb[i] = 8'hF0 ^ 8'(i);
    irq_seen = 0;
    cmd53_write(17'h0060, 8, 1'b1, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 bad-CRC16 write: missing/bad R5");
    end
    repeat (8) @(posedge sd_clk);
    if (!irq_seen) begin
      errors++; $display("ERROR: bad CRC16 block did not raise irq");
    end
    gap();
    cmd53_read(17'h0060, 8, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 verify read after bad CRC16 failed");
    end else begin
      for (int i = 0; i < 8; i++)
        if (rxb[i] !== 8'h00) begin
          errors++;
          $display("ERROR: bad-CRC16 block was committed: byte %0d got=%h exp=00",
                   i, rxb[i]);
        end
    end
    gap();

    // (f) still healthy after errors: two back-to-back CMD52 round-trips
    for (int i = 0; i < 2; i++) begin
      a = 17'h0070 + i[16:0];
      d = 8'h5A ^ (8'(i) * 8'hA5);
      cmd52(1'b1, a, d, rd, ok);
      if (!ok || rd !== d) begin
        errors++; $display("ERROR: post-error CMD52 write %0d failed", i);
      end
      gap();
      cmd52(1'b0, a, 8'h00, rd, ok);
      if (!ok || rd !== d) begin
        errors++; $display("ERROR: post-error CMD52 read %0d failed", i);
      end
      gap();
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized transactions vs a 128-byte shadow of the function-1
    // register file (modulo-128 wrap like the RTL's wrap_addr):
    //  - ~35% CMD52 write + read-back (random addr/data + corners)
    //  - ~20% CMD53 write + read (n 1..32 incl. 1/32 boundaries, wrap
    //    addresses), mixed incrementing / non-incrementing opcode
    //  - ~15% bad CRC7 command -> no response + irq
    //  - ~10% illegal command index -> no response + irq
    //  - ~10% bad CRC16 block -> discarded + irq, shadow verified unchanged
    //  - ~10% CMD53 write with no data block -> start-bit timeout + irq
    begin : crv_phase
      logic [7:0] shadow [0:127];
      int sel, nb, ba, wa;
      logic [5:0] badidx;
      logic [16:0] ra;
      logic [7:0]  rd2;
      int n_52 = 0, n_53 = 0, n_c7 = 0, n_il = 0, n_c16 = 0, n_nblk = 0;
      for (int i = 0; i < 128; i++) shadow[i] = 8'h00;
      // directed-phase survivors: CMD52 at 0x10/0x17/0x1E/0x25,
      // CMD53 block of 8 at 0x40 (0x42 + 0x11*i)
      shadow[8'h10] = 8'hA5; shadow[8'h17] = 8'h99;
      shadow[8'h1E] = 8'hDD; shadow[8'h25] = 8'h11;
      for (int i = 0; i < 8; i++) shadow[8'h40 + i] = 8'h42 + 8'h11 * i;
      for (int i = 0; i < 120; i++) begin
        sel = $urandom_range(0, 19);
        if (sel < 7) begin
          // ---- CMD52 write + read-back ----
          n_52++;
          a = $urandom_range(0, 127);
          d = $urandom_range(0, 255);
          if ($urandom_range(0, 9) == 0) d = 8'h00;
          if ($urandom_range(0, 9) == 0) d = 8'hFF;
          $display("CRV T%0d cmd52w a=%0d d=%h", i, a, d);
          cmd52(1'b1, a, d, rd, ok);
          if (!ok || rd !== d) begin
            errors++; $display("ERROR: CRV %0d CMD52 wr a=%h ok=%b rd=%h exp=%h",
                               i, a, ok, rd, d);
          end
          shadow[a[6:0]] = d;
          gap();
          cmd52(1'b0, a, 8'h00, rd, ok);
          if (!ok || rd !== d) begin
            errors++; $display("ERROR: CRV %0d CMD52 rd a=%h ok=%b rd=%h exp=%h",
                               i, a, ok, rd, d);
          end
          gap();
        end else if (sel < 11) begin
          // ---- CMD53 write + read (incr / non-incr, wrap) ----
          n_53++;
          $display("CRV T%0d cmd53 ba=%0d nb=%0d d0=%h dl=%h", i, ba, nb, txb[0], txb[nb-1]);
          nb = $urandom_range(1, 32);
          if ($urandom_range(0, 9) == 0) nb = 1;
          if ($urandom_range(0, 9) == 0) nb = 32;
          ba = $urandom_range(0, 127);
          for (int j = 0; j < nb; j++) begin
            txb[j] = $urandom_range(0, 255);
            if ($urandom_range(0, 15) == 0) txb[j] = 8'h00;
            if ($urandom_range(0, 15) == 0) txb[j] = 8'hFF;
          end
          if ($urandom_range(0, 1)) begin
            cmd53_write(ba[16:0], nb, 1'b0, ok);
            if (ok) for (int j = 0; j < nb; j++)
              shadow[(ba + j) & 127] = txb[j];
          end else begin
            cmd53_write_ni(ba[16:0], nb, 1'b0, ok);
            if (ok) shadow[ba[6:0]] = txb[nb-1];  // last byte wins
          end
          if (!ok) begin
            errors++; $display("ERROR: CRV %0d CMD53 write failed", i);
          end
          gap();
          if ($urandom_range(0, 1)) begin
            cmd53_read(ba[16:0], nb, ok);
            if (ok) for (int j = 0; j < nb; j++)
              if (rxb[j] !== shadow[(ba + j) & 127]) begin
                errors++;
                $display("ERROR: CRV %0d CMD53 rd byte %0d got=%h exp=%h",
                         i, j, rxb[j], shadow[(ba + j) & 127]);
              end
          end else begin
            cmd53_read_ni(ba[16:0], nb, ok);
            if (ok) for (int j = 0; j < nb; j++)
              if (rxb[j] !== shadow[ba[6:0]]) begin
                errors++;
                $display("ERROR: CRV %0d CMD53-ni rd byte %0d got=%h exp=%h",
                         i, j, rxb[j], shadow[ba[6:0]]);
              end
          end
          if (!ok) begin
            errors++; $display("ERROR: CRV %0d CMD53 read failed", i);
          end
          gap();
        end else if (sel < 14) begin
          // ---- bad CRC7: no response + irq ----
          n_c7++;
          irq_seen = 0;
          ra  = $urandom_range(0, 131071);
          rd2 = $urandom_range(0, 255);
          host_send_cmd(6'd52, {1'b0, 3'd1, 1'b0, 1'b0, ra, 1'b0, rd2}, 1'b1);
          host_recv_rsp(r, ok);
          if (ok) begin
            errors++; $display("ERROR: CRV %0d bad-CRC7 command answered", i);
          end
          repeat (8) @(posedge sd_clk);
          if (!irq_seen) begin
            errors++; $display("ERROR: CRV %0d bad CRC7 no irq", i);
          end
          gap();
        end else if (sel < 16) begin
          // ---- illegal command index: no response + irq ----
          n_il++;
          do badidx = $urandom_range(0, 63);
          while (badidx == 6'd52 || badidx == 6'd53);
          irq_seen = 0;
          host_send_cmd(badidx, $urandom(), 1'b0);
          host_recv_rsp(r, ok);
          if (ok) begin
            errors++; $display("ERROR: CRV %0d illegal CMD%0d answered", i, badidx);
          end
          repeat (8) @(posedge sd_clk);
          if (!irq_seen) begin
            errors++; $display("ERROR: CRV %0d illegal cmd no irq", i);
          end
          gap();
        end else if (sel < 18) begin
          // ---- bad CRC16 block: discarded + irq, shadow unchanged ----
          n_c16++;
          nb = $urandom_range(1, 32);
          ba = $urandom_range(0, 127);
          for (int j = 0; j < nb; j++) txb[j] = $urandom_range(0, 255);
          irq_seen = 0;
          $display("CRV T%0d badCRC16 ba=%0d nb=%0d", i, ba, nb);
          cmd53_write(ba[16:0], nb, 1'b1, ok);
          if (!ok) begin
            errors++; $display("ERROR: CRV %0d bad-CRC16 write: no R5", i);
          end
          repeat (8) @(posedge sd_clk);
          if (!irq_seen) begin
            errors++; $display("ERROR: CRV %0d bad CRC16 no irq", i);
          end
          gap();
          cmd53_read(ba[16:0], nb, ok);
          if (ok) for (int j = 0; j < nb; j++)
            if (rxb[j] !== shadow[(ba + j) & 127]) begin
              errors++;
              $display("ERROR: CRV %0d bad block committed byte %0d", i, j);
            end
          if (!ok) begin
            errors++; $display("ERROR: CRV %0d verify read failed", i);
          end
          gap();
        end else begin
          // ---- CMD53 write, no data block: start-bit timeout + irq ----
          n_nblk++;
          irq_seen = 0;
          ra = $urandom_range(0, 127);
          host_send_cmd(6'd53, {1'b1, 3'd1, 1'b0, 1'b1, ra, 9'd8}, 1'b0);
          host_recv_rsp(r, ok);
          if (!ok) begin
            errors++; $display("ERROR: CRV %0d no-block CMD53: no R5", i);
          end
          repeat (80) @(posedge sd_clk);   // dwr_timeout fires at 64
          if (!irq_seen) begin
            errors++; $display("ERROR: CRV %0d missing block: no timeout irq", i);
          end
          gap();
        end
      end
      $display("CRV: 120 txns (cmd52=%0d cmd53=%0d badCRC7=%0d illegal=%0d badCRC16=%0d no-block=%0d)",
               n_52, n_53, n_c7, n_il, n_c16, n_nblk);
      for (int j = 0; j < 128; j++) begin
        cmd52(1'b0, j[16:0], 8'h00, rd, ok);
        if (ok && rd !== shadow[j])
          $display("SWEEP addr=%0d dev=%h shadow=%h", j, rd, shadow[j]);
        gap();
      end
    end
`endif

    if (errors == 0) $display("TEST PASSED: SDIO");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < SDIO_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, SDIO_FSM_TOTAL);
      $display("FSM seen %012b", fsm_seen);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: Verilator 5.006 corrupts the --timing delay heap on a
  // single long-pending #delay once many short-delay resumptions interleave.
  initial begin
    repeat (10000) #1000;   // 10 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
