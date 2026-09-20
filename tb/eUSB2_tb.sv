// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for eUSB2_top -- SystemVerilog
// Link-partner model: drives eD+/eD- single-ended NRZI bit streams (control
// packets, data frames, squelch/SE1 scenarios) and checks the retimed dp/dm
// output plus register read responses.
// IP design verification v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module eUSB2_tb;

  logic clk = 0, rst_n = 0;
  logic edp, edm;
  logic dp, dm, squelch, irq;

  int errors = 0;

  // host-side bit-stream state
  logic tb_cur;          // currently driven state: 1 = J, 0 = K
  int   ones_tb;         // consecutive 1-bits (for stuffing)

  eUSB2_top dut (
    .clk(clk), .rst_n(rst_n),
    .edp(edp), .edm(edm),
    .dp(dp), .dm(dm),
    .squelch(squelch), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // retime monitor: dp/dm must equal eD+/eD- delayed by exactly 1 clk
  // ------------------------------------------------------------------
  logic mon_en = 1'b0;
  logic edp_d = 1'b0, edm_d = 1'b0;
  int   retime_errs = 0;
  always @(posedge clk) begin
    if (mon_en && ({dp, dm} !== {edp_d, edm_d}))
      retime_errs = retime_errs + 1;
    edp_d <= edp;
    edm_d <= edm;
  end

  // ------------------------------------------------------------------
  // CRC8 (mirror DUT), poly 0x07, init 0xFF, MSB-first
  // ------------------------------------------------------------------
  function automatic logic [7:0] crc8_b(input logic [7:0] c_in,
                                        input logic [7:0] d);
    logic [7:0] c;
    logic       fb;
    begin
      c = c_in;
      for (int i = 7; i >= 0; i--) begin
        fb = d[i] ^ c[7];
        c  = {c[6:0], 1'b0};
        if (fb) c = c ^ 8'h07;
      end
      crc8_b = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // bit-stream drivers (one bit cell per clk)
  // ------------------------------------------------------------------
  task automatic drive(input logic p, input logic m);
    begin
      @(negedge clk);
      edp <= p;
      edm <= m;
    end
  endtask

  task automatic send_bit(input logic b);
    begin
      if (!b) tb_cur = ~tb_cur;      // NRZI: 0 = toggle
      drive(tb_cur, ~tb_cur);
    end
  endtask

  task automatic send_byte(input logic [7:0] d);
    begin
      for (int i = 0; i < 8; i++) begin
        send_bit(d[i]);              // LSB first
        if (d[i]) begin
          ones_tb = ones_tb + 1;
          if (ones_tb == 6) begin
            send_bit(1'b0);          // bit stuffing
            ones_tb = 0;
          end
        end else begin
          ones_tb = 0;
        end
      end
    end
  endtask

  task automatic send_sync;
    begin
      repeat (7) send_bit(1'b0);     // KJKJKJKK from idle J
      send_bit(1'b1);
      ones_tb = 0;
    end
  endtask

  task automatic send_eop;
    begin
      drive(1'b0, 1'b0);             // SE0
      drive(1'b0, 1'b0);             // SE0
      drive(1'b1, 1'b0);             // J
      tb_cur  = 1'b1;
      ones_tb = 0;
    end
  endtask

  // ------------------------------------------------------------------
  // control packet transactions (PID 8'hC3)
  // ------------------------------------------------------------------
  task automatic ctrl_write(input logic [2:0] addr, input logic [7:0] data,
                            input logic corrupt);
    logic [7:0] cmd, c;
    begin
      cmd = {1'b0, addr, 4'b0000};
      send_sync;
      send_byte(8'hC3);
      send_byte(cmd);
      send_byte(data);
      c = crc8_b(crc8_b(8'hFF, cmd), data);
      if (corrupt) c = c ^ 8'h01;
      send_byte(c);
      send_eop;
      repeat (3) drive(1'b1, 1'b0);
    end
  endtask

  task automatic ctrl_read_req(input logic [2:0] addr);
    logic [7:0] cmd;
    begin
      cmd = {1'b1, addr, 4'b0000};
      send_sync;
      send_byte(8'hC3);
      send_byte(cmd);
      send_byte(crc8_b(8'hFF, cmd));
      send_eop;
    end
  endtask

  // receive and verify a read-response frame on dp/dm
  task automatic recv_resp(input logic [2:0] exp_addr,
                           input logic [7:0] exp_data);
    logic       prev, cur, b;
    int         zeros, ones, nbits, nb, t, guard;
    logic [7:0] sh;
    logic [7:0] bytes [0:3];
    logic       sync_done, eop_seen;
    begin
      t = 0;
      while ({dp, dm} !== 2'b01 && t < 300) begin  // wait for K (sync start)
        @(negedge clk); t = t + 1;
      end
      if (t >= 300) begin
        errors++;
        $display("ERROR: timeout waiting for read response");
      end else begin
        prev = 1'b0;                  // first cell already observed: K
        zeros = 1;                    // first K cell = sync bit 0
        ones = 0; nbits = 0; nb = 0; sh = 8'h00; guard = 0;
        sync_done = 1'b0; eop_seen = 1'b0;
        while (!eop_seen && guard < 300) begin
          @(negedge clk); guard = guard + 1;
          if ({dp, dm} == 2'b00) begin
            eop_seen = 1'b1;
          end else if ({dp, dm} == 2'b11) begin
            errors++;
            $display("ERROR: SE1 inside read response");
            eop_seen = 1'b1;
          end else begin
            cur  = dp;
            b    = (cur == prev);
            prev = cur;
            if (!sync_done) begin
              if (!b) begin
                zeros = zeros + 1;
              end else begin
                if (zeros == 7) sync_done = 1'b1;
                zeros = 0;
              end
            end else if (ones == 6) begin
              if (!b) begin
                ones = 0;             // stuffed bit dropped
              end else begin
                errors++;
                $display("ERROR: bit-stuff error in read response");
                ones = 0;
              end
            end else begin
              sh = {b, sh[7:1]};
              nbits = nbits + 1;
              if (b) ones = ones + 1; else ones = 0;
              if (nbits == 8) begin
                if (nb < 4) begin
                  bytes[nb] = sh;
                  nb = nb + 1;
                end
                nbits = 0;
              end
            end
          end
        end
        if (guard >= 300) begin
          errors++;
          $display("ERROR: read response EOP missing");
        end
        if (nb != 4) begin
          errors++;
          $display("ERROR: response byte count %0d, expected 4", nb);
        end else begin
          if (bytes[0] !== 8'h3C) begin
            errors++;
            $display("ERROR: response PID %h, expected 3C", bytes[0]);
          end
          if (bytes[1] !== {1'b1, exp_addr, 4'b0000}) begin
            errors++;
            $display("ERROR: response cmd %h, addr mismatch", bytes[1]);
          end
          if (bytes[2] !== exp_data) begin
            errors++;
            $display("ERROR: read data %h, expected %h", bytes[2], exp_data);
          end
          if (bytes[3] !== crc8_b(crc8_b(8'hFF, bytes[1]), bytes[2])) begin
            errors++;
            $display("ERROR: response CRC8 %h mismatch", bytes[3]);
          end
        end
      end
      repeat (4) drive(1'b1, 1'b0);   // let DUT return to retime mode
    end
  endtask

  task automatic ctrl_read(input logic [2:0] addr, input logic [7:0] exp);
    begin
      ctrl_read_req(addr);
      recv_resp(addr, exp);
    end
  endtask

  // non-control USB2 data frame (content irrelevant; retime-checked)
  task automatic send_data_frame;
    begin
      send_sync;
      send_byte(8'h3C);               // DATA0-style PID
      send_byte(8'h11);
      send_byte(8'hFE);               // long 1-runs exercise stuffing
      send_byte(8'hFF);
      send_byte(8'h55);
      send_byte(8'h9A);
      send_eop;
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    edp = 1'b1; edm = 1'b0;           // idle J
    tb_cur = 1'b1; ones_tb = 0;
    rst_n = 0;
    repeat (5) @(negedge clk);

    // ---- check 1: reset state --------------------------------------
    if ({dp, dm} !== 2'b00) begin
      errors++; $display("ERROR: reset dp/dm=%b%b, expected SE0", dp, dm);
    end
    if (squelch !== 1'b0) begin
      errors++; $display("ERROR: reset squelch=%b", squelch);
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: reset irq=%b", irq);
    end
    rst_n = 1;

    // ---- check 2: idle J retimed to dp/dm --------------------------
    repeat (4) drive(1'b1, 1'b0);
    if ({dp, dm} !== 2'b10) begin
      errors++; $display("ERROR: idle J not retimed, dp/dm=%b%b", dp, dm);
    end

    // ---- check 3: control register write/read x3 (back-to-back) ----
    ctrl_write(3'd1, 8'hA5, 1'b0);
    ctrl_write(3'd2, 8'h3C, 1'b0);
    ctrl_write(3'd3, 8'hFF, 1'b0);
    ctrl_read(3'd1, 8'hA5);
    ctrl_read(3'd2, 8'h3C);
    ctrl_read(3'd3, 8'hFF);

    // ---- check 4: squelch-threshold register write/read ------------
    ctrl_write(3'd0, 8'd6, 1'b0);
    ctrl_read(3'd0, 8'd6);

    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq set during error-free operations");
    end

    // ---- check 5: end-to-end retime of USB2 data frames ------------
    retime_errs = 0;
    repeat (2) drive(1'b1, 1'b0);
    mon_en = 1'b1;
    send_data_frame;
    repeat (2) drive(1'b1, 1'b0);
    send_data_frame;                // consecutive frames
    repeat (3) drive(1'b1, 1'b0);
    mon_en = 1'b0;
    if (retime_errs != 0) begin
      errors++;
      $display("ERROR: %0d retime mismatches on data frames", retime_errs);
    end

    // ---- check 6: squelch scenario (threshold now 6) ---------------
    repeat (10) drive(1'b0, 1'b0);    // long SE0 -> signal loss
    if (squelch !== 1'b1) begin
      errors++; $display("ERROR: squelch not detected after long SE0");
    end
    if ({dp, dm} !== 2'b00) begin
      errors++; $display("ERROR: outputs not silenced during squelch");
    end
    drive(1'b0, 1'b1);                // K while squelched: squelch holds
    drive(1'b0, 1'b1);
    if (squelch !== 1'b1) begin
      errors++; $display("ERROR: squelch cleared by K (only J may clear)");
    end
    if ({dp, dm} !== 2'b00) begin
      errors++; $display("ERROR: outputs not silenced during squelched K");
    end
    repeat (3) drive(1'b1, 1'b0);     // J: exit squelch
    if (squelch !== 1'b0) begin
      errors++; $display("ERROR: squelch did not clear on J");
    end
    retime_errs = 0;                  // recovery: retime works again
    mon_en = 1'b1;
    send_data_frame;
    repeat (3) drive(1'b1, 1'b0);
    mon_en = 1'b0;
    if (retime_errs != 0) begin
      errors++;
      $display("ERROR: %0d retime mismatches after squelch", retime_errs);
    end

    // ---- check 7: SE1 injection -> irq ------------------------------
    drive(1'b1, 1'b1);                // illegal single-ended state
    drive(1'b1, 1'b0);
    drive(1'b1, 1'b0);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after SE1 injection");
    end

    // ---- check 8: bad CRC8 control write is ignored -----------------
    ctrl_write(3'd4, 8'h77, 1'b1);    // corrupted CRC8
    ctrl_read(3'd4, 8'h00);           // register must keep reset value

    // ---- summary -----------------------------------------------------
    if (errors == 0)
      $display("TEST PASSED: eUSB2");
    else
      $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #2000000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
