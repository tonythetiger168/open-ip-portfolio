// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for USB_top (USB 1.1 Full-Speed device)
// Host model drives dp/dm at bit level (NRZI + bit stuffing + EOP) and
// decodes device responses at bit level.
// Checks:
//   1. reset state (irq low, device not driving the bus)
//   2. GET_DESCRIPTOR control read: SETUP->ACK + 8x8 regfile write-back
//      compare, IN->DATA1 descriptor payload+CRC16 compare, host ACK
//   3. EP1 interrupt IN x2 back-to-back: payload counter increments,
//      DATA0/DATA1 toggle alternates
//   4. DATA toggle misorder injection: SETUP with DATA1 -> ACK but
//      register file NOT written (duplicate discarded)
//   5. lost-ACK retransmission: IN without ACK -> same DATA payload/toggle
//      re-sent on next IN
//   6. bad CRC5 token injection: no device response + irq raised,
//      next good token clears irq
//   7. bad CRC16 data injection: no handshake + irq raised
//   8. IN to illegal endpoint -> STALL handshake
// ============================================================================
`timescale 1ns/1ps
module USB_tb;
  localparam int BIT_CLKS = 4;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // USB bus: weak pull-up on D+ (device pull-up), weak pull-down on D- (host)
  tri1 dp;
  tri0 dm;
  logic host_oe = 0, host_dp = 1, host_dm = 0;
  assign dp = host_oe ? host_dp : 1'bz;
  assign dm = host_oe ? host_dm : 1'bz;

  wire irq;
  int  errors = 0;

  USB_top #(.DW(32), .AW(32), .BIT_CLKS(BIT_CLKS)) dut (
    .clk(clk), .rst_n(rst_n), .dp(dp), .dm(dm), .irq(irq)
  );

  // ------------------------------------------------------------------
  // check helper
  // ------------------------------------------------------------------
  task automatic check(input bit cond, input string msg);
    begin
      if (cond) $display("[OK]   %s", msg);
      else begin
        errors++;
        $display("[FAIL] %s", msg);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // CRC models (mirror of DUT, verified against USB spec vectors)
  // ------------------------------------------------------------------
  function automatic logic [4:0] crc5_token(input logic [6:0] a, input logic [3:0] e);
    logic [4:0] c; logic fb; logic b;
    begin
      c = 5'h1F;
      for (int i = 0; i < 11; i++) begin
        b  = (i < 7) ? a[i] : e[i-7];
        fb = c[0] ^ b;
        c  = fb ? (c >> 1) ^ 5'h14 : (c >> 1);
      end
      crc5_token = ~c;
    end
  endfunction

  function automatic logic [15:0] crc16_upd(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] r;
    begin
      r = c;
      for (int k = 0; k < 8; k++)
        r = (r[0] ^ d[k]) ? (r >> 1) ^ 16'hA001 : (r >> 1);
      crc16_upd = r;
    end
  endfunction

  // ------------------------------------------------------------------
  // host bit-level transmit (NRZI + stuffing), driven on negedge
  // payload passed through global h_pl[] (iverilog: no array task ports)
  // ------------------------------------------------------------------
  logic       h_lvl;   // current NRZI level (1=J, 0=K)
  int         h_ones;
  logic [7:0] h_pl [0:7];

  task automatic h_bit(input logic b);
    begin
      if (!b) h_lvl = ~h_lvl;
      host_oe = 1; host_dp = h_lvl; host_dm = ~h_lvl;
      repeat (BIT_CLKS) @(negedge clk);
    end
  endtask

  task automatic h_raw_bit(input logic b);   // with bit-stuff accounting
    begin
      h_bit(b);
      if (b) begin
        h_ones = h_ones + 1;
        if (h_ones == 6) begin h_bit(1'b0); h_ones = 0; end
      end else h_ones = 0;
    end
  endtask

  task automatic h_byte(input logic [7:0] d);
    for (int i = 0; i < 8; i++) h_raw_bit(d[i]);
  endtask

  task automatic h_sop_sync;
    begin
      h_ones = 0; h_lvl = 1'b1;
      host_oe = 1; host_dp = 1; host_dm = 0;   // idle J
      @(negedge clk);
      h_byte(8'h80);                            // SYNC: KJKJKJKK
      h_ones = 0;                               // stuffing starts after SYNC
    end
  endtask

  task automatic h_eop;
    begin
      host_oe = 1; host_dp = 0; host_dm = 0;
      repeat (2*BIT_CLKS) @(negedge clk);       // SE0 x2 bit times
      host_dp = 1; host_dm = 0;
      repeat (BIT_CLKS) @(negedge clk);         // J x1 bit time
      host_oe = 0;                              // release bus
      @(negedge clk);
    end
  endtask

  task automatic h_token(input logic [3:0] pid, input logic [6:0] addr,
                         input logic [3:0] endp, input bit corrupt);
    logic [4:0]  c5;
    logic [15:0] tf;
    begin
      c5 = crc5_token(addr, endp) ^ (corrupt ? 5'h1F : 5'h00);
      tf = {c5, endp, addr};
      h_sop_sync;
      h_byte({~pid, pid});
      for (int i = 0; i < 16; i++) h_raw_bit(tf[i]);
      h_eop;
    end
  endtask

  task automatic h_data(input logic [3:0] pid, input int len, input bit corrupt);
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      h_sop_sync;
      h_byte({~pid, pid});
      for (int i = 0; i < len; i++) begin
        h_byte(h_pl[i]);
        c = crc16_upd(c, h_pl[i]);
      end
      c = ~c ^ (corrupt ? 16'hFFFF : 16'h0000);
      h_byte(c[7:0]);
      h_byte(c[15:8]);
      h_eop;
    end
  endtask

  task automatic h_handshake(input logic [3:0] pid);
    begin
      h_sop_sync;
      h_byte({~pid, pid});
      h_eop;
    end
  endtask

  // ------------------------------------------------------------------
  // host bit-level receive (samples at bit centers on negedge)
  //   fills rbuf/rlen; rto=1 if no SOP within timeout
  // ------------------------------------------------------------------
  logic [7:0] rbuf [0:15];
  int         rlen;
  bit         rto;

  task automatic h_recv(input int to_clks);
    int  to;
    logic prev, raw;
    int  ones;
    logic [7:0] sh;
    int  bc;
    int  guard;
    bit  done;
    bit  got_sync;
    begin : recv_blk
      rto = 0; rlen = 0;
      host_oe = 0;                               // release while device talks
      to = 0;
      while (!(dp === 1'b0 && dm === 1'b1)) begin   // wait SOP (J->K)
        @(negedge clk);
        to = to + 1;
        if (to > to_clks) begin rto = 1; disable recv_blk; end
      end
      repeat (BIT_CLKS/2) @(negedge clk);        // to center of first bit
      prev = 1'b1;                               // idle J before SOP
      ones = 0; bc = 0; sh = 8'h00; guard = 0; done = 0; got_sync = 0;
      while (!done) begin
        if (dp === 1'b0 && dm === 1'b0) done = 1;   // EOP (SE0)
        else begin
          raw = (dp === prev);
          prev = dp;
          if (ones == 6) begin                   // stuffed bit, drop
            ones = 0;
          end else begin
            sh = {raw, sh[7:1]};
            bc = bc + 1;
            if (raw) ones = ones + 1; else ones = 0;
            if (bc == 8) begin
              bc = 0;
              if (!got_sync) begin               // first byte is SYNC, drop it
                got_sync = 1;
                ones = 0;                        // stuffing starts after SYNC
              end else if (rlen < 16) begin
                rbuf[rlen] = sh; rlen = rlen + 1;
              end
            end
          end
          guard = guard + 1;
          if (guard > 400) done = 1;
          else repeat (BIT_CLKS) @(negedge clk);
        end
      end
      repeat (3*BIT_CLKS) @(negedge clk);        // let device finish EOP
    end
  endtask

  // ------------------------------------------------------------------
  // PID constants / expected descriptor
  // ------------------------------------------------------------------
  localparam logic [3:0] P_OUT=4'h1, P_IN=4'h9, P_SETUP=4'hD,
                         P_DATA0=4'h3, P_DATA1=4'hB,
                         P_ACK=4'h2, P_NAK=4'hA, P_STALL=4'hE;
  localparam logic [7:0] B_ACK   = 8'hD2, B_STALL = 8'h1E,
                         B_DATA0 = 8'hC3, B_DATA1 = 8'h4B;

  function automatic logic [7:0] desc_byte(input int i);
    begin
      case (i)
        0:       desc_byte = 8'h12;
        1:       desc_byte = 8'h01;
        2:       desc_byte = 8'h00;
        3:       desc_byte = 8'h02;
        4:       desc_byte = 8'h00;
        5:       desc_byte = 8'h00;
        6:       desc_byte = 8'h00;
        default: desc_byte = 8'h08;
      endcase
    end
  endfunction

  // decode + verify a received data packet against expected payload exp_pl[]
  logic [7:0] exp_pl [0:7];

  task automatic expect_data_pkt(input logic [7:0] pid_byte,
                                 input int len, input string tag);
    logic [15:0] c;
    bit ok;
    begin
      h_recv(600);
      check(!rto, {tag, ": device responded (no timeout)"});
      if (!rto) begin
        check(rlen == len+3, {tag, ": byte count = payload+PID+CRC16"});
        check(rbuf[0] === pid_byte, {tag, ": PID byte as expected"});
        ok = 1'b1;
        for (int i = 0; i < len; i++)
          if (rbuf[i+1] !== exp_pl[i]) begin
            ok = 0;
            $display("       mismatch byte %0d: got %02x exp %02x", i, rbuf[i+1], exp_pl[i]);
          end
        check(ok, {tag, ": payload compare"});
        c = 16'hFFFF;
        for (int i = 0; i < len; i++) c = crc16_upd(c, rbuf[i+1]);
        c = ~c;
        check(rbuf[len+1] === c[7:0] && rbuf[len+2] === c[15:8],
              {tag, ": CRC16 valid"});
      end
    end
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  logic [7:0] saved_rf [0:7];
  bit         same;

  task automatic set_exp_count(input logic [7:0] v);
    begin
      for (int i = 0; i < 8; i++) exp_pl[i] = 8'h00;
      exp_pl[0] = v;
    end
  endtask

  initial begin
    // ---------------- 1. reset ----------------
    rst_n = 0;
    repeat (8) @(negedge clk);
    check(irq === 1'b0, "reset: irq low");
    check(dp === 1'b1 && dm === 1'b0, "reset: device not driving bus (idle J via pull-up)");
    rst_n = 1;
    repeat (4) @(negedge clk);

    // ---------------- 2. GET_DESCRIPTOR ----------------
    $display("-- GET_DESCRIPTOR control read on EP0 --");
    h_pl[0]=8'h80; h_pl[1]=8'h06; h_pl[2]=8'h00; h_pl[3]=8'h01;
    h_pl[4]=8'h00; h_pl[5]=8'h00; h_pl[6]=8'h08; h_pl[7]=8'h00;
    h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
    h_data(P_DATA0, 8, 1'b0);
    h_recv(600);
    check(!rto && rlen == 1 && rbuf[0] === B_ACK, "SETUP data stage ACKed");
    same = 1'b1;
    for (int i = 0; i < 8; i++) begin
      if (dut.setup_q[i] !== h_pl[i]) same = 0;
      saved_rf[i] = dut.setup_q[i];
    end
    check(same, "SETUP 8x8 register file written with request bytes");
    check(dut.ep0in_tgl === 1'b1, "SETUP resets EP0 IN toggle to DATA1");

    h_token(P_IN, 7'd0, 4'd0, 1'b0);
    for (int i = 0; i < 8; i++) exp_pl[i] = desc_byte(i);
    expect_data_pkt(B_DATA1, 8, "GET_DESCRIPTOR IN");
    h_handshake(P_ACK);
    repeat (4) @(negedge clk);
    check(dut.ep0in_tgl === 1'b0, "EP0 IN toggle flips after ACK");

    // ---------------- 3. EP1 interrupt IN x2 (back-to-back) ----------------
    $display("-- EP1 interrupt IN x2 --");
    set_exp_count(8'h00);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA0, 4, "EP1 IN #1 (count=0)");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);
    set_exp_count(8'h01);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA1, 4, "EP1 IN #2 (count=1)");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);

    // ---------------- 4. toggle misorder injection ----------------
    $display("-- SETUP with wrong toggle (DATA1) injected --");
    h_pl[0]=8'hAA; h_pl[1]=8'hBB; h_pl[2]=8'hCC; h_pl[3]=8'hDD;
    h_pl[4]=8'h11; h_pl[5]=8'h22; h_pl[6]=8'h33; h_pl[7]=8'h44;
    h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
    h_data(P_DATA1, 8, 1'b0);                   // wrong: SETUP expects DATA0
    h_recv(600);
    check(!rto && rlen == 1 && rbuf[0] === B_ACK,
          "misordered SETUP data still ACKed (duplicate discarded)");
    same = 1'b1;
    for (int i = 0; i < 8; i++)
      if (dut.setup_q[i] !== saved_rf[i]) same = 0;
    check(same, "register file NOT overwritten by misordered data");

    // ---------------- 5. lost-ACK retransmission ----------------
    $display("-- IN without ACK -> device retransmits --");
    set_exp_count(8'h02);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA0, 4, "EP1 IN #3 (count=2)");
    repeat (100) @(negedge clk);                // no ACK: let DUT time out
    h_token(P_IN, 7'd0, 4'd1, 1'b0);            // retry
    expect_data_pkt(B_DATA0, 4, "EP1 IN retry: same toggle+payload re-sent");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);
    set_exp_count(8'h03);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);
    expect_data_pkt(B_DATA1, 4, "EP1 IN #4 advances after ACK (count=3)");
    h_handshake(P_ACK);
    repeat (2) @(negedge clk);

    // ---------------- 6. bad CRC5 token ----------------
    $display("-- bad CRC5 token injected --");
    h_token(P_IN, 7'd0, 4'd0, 1'b1);
    h_recv(300);
    check(rto, "bad CRC5 token: no device response");
    check(irq === 1'b1, "bad CRC5 token: irq raised");
    set_exp_count(8'h04);
    h_token(P_IN, 7'd0, 4'd1, 1'b0);            // good token clears irq
    expect_data_pkt(B_DATA0, 4, "recovery IN after bad CRC5 (count=4)");
    h_handshake(P_ACK);
    check(irq === 1'b0, "irq cleared by next valid token");

    // ---------------- 7. bad CRC16 data ----------------
    $display("-- bad CRC16 data injected --");
    h_token(P_SETUP, 7'd0, 4'd0, 1'b0);
    h_data(P_DATA0, 8, 1'b1);
    h_recv(300);
    check(rto, "bad CRC16 data: no handshake from device");
    check(irq === 1'b1, "bad CRC16 data: irq raised");

    // ---------------- 8. illegal endpoint STALL ----------------
    $display("-- IN to illegal endpoint --");
    h_token(P_IN, 7'd0, 4'd2, 1'b0);
    h_recv(600);
    check(!rto && rlen == 1 && rbuf[0] === B_STALL, "IN ep2 -> STALL handshake");
    check(irq === 1'b0, "irq cleared by valid token");

    // ---------------- summary ----------------
    repeat (20) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: USB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
