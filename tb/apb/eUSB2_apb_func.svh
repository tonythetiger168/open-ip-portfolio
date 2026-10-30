// SPDX-License-Identifier: Apache-2.0
// IP part of eUSB2_apb_tb: the eUSB2 host model of the core TB (NRZI bit
// cells with stuffing on edp / edm, control packets with CRC8, read
// responses decoded from dp / dm, a retime monitor). Register writes and
// reads over the line, retimed data frames, squelch in STATUS.SQUELCH
// against the pin, and every error class (SE1, CRC8, over-long packets)
// in IRQ_STATUS.ERR, sticky until PRESETN (masked and on the irq pin).
  logic tb_cur;          // currently driven state: 1 = J, 0 = K
  int   ones_tb;         // consecutive 1-bits (for stuffing)
  initial begin edp = 1'b1; edm = 1'b0; tb_cur = 1'b1; ones_tb = 0; end
  task automatic presetn_pulse;
    PRESETN = 0; repeat (2) drive(1'b1, 1'b0); PRESETN = 1;
    check_reset_values();
    rd_exp(A_IRQ_STATUS, 0); rd_exp(A_STATUS, 0);
  endtask

  // ------------------------------------------------------------------
  // retime monitor: dp/dm must equal eD+/eD- delayed by exactly 1 PCLK
  // ------------------------------------------------------------------
  logic mon_en = 1'b0;
  logic edp_d = 1'b0, edm_d = 1'b0;
  int   retime_errs = 0;
  always @(posedge PCLK) begin
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
  // bit-stream drivers (one bit cell per PCLK)
  // ------------------------------------------------------------------
  task automatic drive(input logic p, input logic m);
    begin
      @(negedge PCLK);
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
        @(negedge PCLK); t = t + 1;
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
          @(negedge PCLK); guard = guard + 1;
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

  // read request with a stretched EOP (squelch fires during the response)
  task automatic read_req_long_eop(input logic [2:0] addr, input int se0);
    logic [7:0] cmd;
    begin
      cmd = {1'b1, addr, 4'b0000};
      send_sync;
      send_byte(8'hC3);
      send_byte(cmd);
      send_byte(crc8_b(8'hFF, cmd));
      repeat (se0) drive(1'b0, 1'b0);
      drive(1'b1, 1'b0);
      tb_cur = 1'b1; ones_tb = 0;
    end
  endtask

  task automatic expect_irq_clear(input string what);
    begin
      if (dut.c_irq !== 1'b1) begin errors++; $display("ERROR: %s: no dut.c_irq", what); end
      presetn_pulse(); repeat (2) drive(1'b1, 1'b0);
    end
  endtask

  task automatic extra_tests;
    logic [7:0] cmd;
    begin
      presetn_pulse(); repeat (3) drive(1'b1, 1'b0);
      // long sync (9 zeros before the 1)
      cmd = {1'b0, 3'd2, 4'b0000};
      repeat (9) send_bit(1'b0); send_bit(1'b1); ones_tb = 0;
      send_byte(8'hC3); send_byte(cmd); send_byte(8'h67);
      send_byte(crc8_b(crc8_b(8'hFF, cmd), 8'h67)); send_eop;
      repeat (3) drive(1'b1, 1'b0);
      // response whose CRC ends in six 1s: stuffed bit before the EOP
      ctrl_read(3'd2, 8'h67);
      // runt packet: sync + 3 bits, no dut.c_irq
      send_sync; send_bit(1'b0); send_bit(1'b1); send_bit(1'b0); send_eop;
      repeat (3) drive(1'b1, 1'b0);
      if (dut.c_irq !== 1'b0) begin errors++; $display("ERROR: runt packet raised dut.c_irq"); end
      // over-long write: ignored, dut.c_irq
      cmd = {1'b0, 3'd3, 4'b0000};
      send_sync; send_byte(8'hC3); send_byte(cmd); send_byte(8'h11);
      // the extra byte repeats the CRC, so only the length check catches it
      send_byte(crc8_b(crc8_b(8'hFF, cmd), 8'h11)); send_byte(crc8_b(crc8_b(8'hFF, cmd), 8'h11)); send_eop;
      repeat (3) drive(1'b1, 1'b0);
      expect_irq_clear("over-long write");
      ctrl_read(3'd3, 8'h00);
      // over-long read: no response, dut.c_irq
      cmd = {1'b1, 3'd3, 4'b0000};
      send_sync; send_byte(8'hC3); send_byte(cmd); send_byte(crc8_b(8'hFF, cmd));
      send_byte(crc8_b(8'hFF, cmd)); send_eop;
      repeat (50) drive(1'b1, 1'b0);
      expect_irq_clear("over-long read");
      // a read queued behind a response, and traffic received meanwhile
      ctrl_write(3'd5, 8'hC4, 1'b0);
      ctrl_read_req(3'd2);
      ctrl_read_req(3'd5);
      send_data_frame;
      repeat (120) drive(1'b1, 1'b0);
      // squelch during a response
      read_req_long_eop(3'd5, 20);
      repeat (60) drive(1'b1, 1'b0);
      // se0 counter saturates
      repeat (300) drive(1'b0, 1'b0);
      repeat (3) drive(1'b1, 1'b0);
      // every register bit back to 0
      for (int a = 0; a < 8; a++) ctrl_write(3'(a), 8'h00, 1'b0);
      for (int a = 0; a < 8; a++) ctrl_read(3'(a), 8'h00);
      // reset during a response
      ctrl_read_req(3'd1);
      repeat (15) drive(1'b1, 1'b0);
      presetn_pulse(); repeat (3) drive(1'b1, 1'b0);
      if (dut.c_irq !== 1'b0 || squelch !== 1'b0) begin errors++; $display("ERROR: reset during response"); end
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


  // ERR set and held (sticky in the core): w1c cannot clear it
  task automatic err_held(input bit en, input string m);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({m, ": irq pin vs enable"});
  endtask

  task automatic ip_func;
    rd_exp(A_FLAGS, 0);
    rd_exp(A_STATUS, 0);
    repeat (4) drive(1'b1, 1'b0);
    if ({dp, dm} !== 2'b10) fail("idle J not retimed");

    // ---- register file over the line ----
    ctrl_write(3'd1, 8'hA5, 1'b0);
    ctrl_write(3'd2, 8'h3C, 1'b0);
    ctrl_read(3'd1, 8'hA5);
    ctrl_read(3'd2, 8'h3C);
    ctrl_write(3'd0, 8'd6, 1'b0);                   // squelch threshold
    ctrl_read(3'd0, 8'd6);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- retimed data frames ----
    retime_errs = 0;
    repeat (2) drive(1'b1, 1'b0);
    mon_en = 1'b1;
    send_data_frame;
    repeat (2) drive(1'b1, 1'b0);
    send_data_frame;
    repeat (3) drive(1'b1, 1'b0);
    mon_en = 1'b0;
    if (retime_errs != 0) fail("retime mismatches on data frames");

    // ---- squelch ----
    repeat (10) drive(1'b0, 1'b0);
    rd_exp(A_STATUS, 1);
    if (squelch !== 1'b1 || {dp, dm} !== 2'b00) fail("squelch pin / silenced outputs");
    drive(1'b0, 1'b1); drive(1'b0, 1'b1);           // K holds squelch
    rd_exp(A_STATUS, 1);
    repeat (3) drive(1'b1, 1'b0);                   // J clears it
    rd_exp(A_STATUS, 0);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- SE1: ERR, masked ----
    drive(1'b1, 1'b1);
    drive(1'b1, 1'b0);
    drive(1'b1, 1'b0);
    err_held(0, "SE1");
    ctrl_write(3'd4, 8'h77, 1'b1);                  // bad CRC8: ignored
    ctrl_read(3'd4, 8'h00);

    // ---- bad CRC8 after PRESETN, on the irq pin ----
    presetn_pulse();
    repeat (3) drive(1'b1, 1'b0);
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    ctrl_write(3'd4, 8'h77, 1'b1);
    err_held(1, "bad CRC8");
    presetn_pulse();
    repeat (3) drive(1'b1, 1'b0);
    rd_exp(A_IRQ_ENABLE, 0);

    // ---- over-long packets, runts, queued reads (core TB's extra tests) ----
    extra_tests;
    rd_exp(A_IRQ_STATUS, 0);

    // leave ERR pending (masked) for the final reset
    drive(1'b1, 1'b1); drive(1'b1, 1'b0); drive(1'b1, 1'b0);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
