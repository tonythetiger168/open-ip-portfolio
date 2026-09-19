// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for DSI_top (MIPI DSI host TX + BTA)
// TB plays the DSI peripheral: it decodes the host serial packet stream
// (SoT/header/ECC/payload/CRC-16 checked with independent reference models)
// and answers DCS read requests after the bus turn-around.
// Checks: reset state / DCS short writes (set_display_on, set_pixel_format)
// / DCS long write payload+CRC (column_address) / video-mode line sequence
// HSS/HSE/HBP/HACT / DCS read + BTA response data / BTA response ECC
// single-bit correction / BTA uncorrectable ECC -> irq / BTA timeout -> irq
// / back-to-back commands + pkt_cnt.
// ============================================================================
`timescale 1ns/1ps
module DSI_tb;

  logic        clk = 0, rst_n = 0;
  logic        irq;
  logic        tx_bit, tx_valid, tx_oe;
  logic        rx_bit = 1;
  logic        cmd_valid = 0;
  logic [2:0]  cmd_op = 0;
  logic [5:0]  cmd_dt = 0;
  logic [7:0]  cmd_dcs = 0;
  logic [15:0] cmd_len = 0, cmd_len2 = 0;
  logic        cmd_busy;
  logic        pl_we = 0;
  logic [4:0]  pl_addr = 0;
  logic [7:0]  pl_wdata = 0;
  logic        bta_done;
  logic [23:0] bta_data;
  logic [15:0] pkt_cnt;

  int errors = 0;

  DSI_top dut (
    .clk(clk), .rst_n(rst_n), .irq(irq),
    .tx_bit(tx_bit), .tx_valid(tx_valid), .tx_oe(tx_oe), .rx_bit(rx_bit),
    .cmd_valid(cmd_valid), .cmd_op(cmd_op), .cmd_dt(cmd_dt),
    .cmd_dcs(cmd_dcs), .cmd_len(cmd_len), .cmd_len2(cmd_len2),
    .cmd_busy(cmd_busy),
    .pl_we(pl_we), .pl_addr(pl_addr), .pl_wdata(pl_wdata),
    .bta_done(bta_done), .bta_data(bta_data), .pkt_cnt(pkt_cnt)
  );

  always #5 clk = ~clk;

  localparam logic [2:0] OP_SPKT   = 3'd0;
  localparam logic [2:0] OP_DCS_S0 = 3'd1;
  localparam logic [2:0] OP_DCS_S1 = 3'd2;
  localparam logic [2:0] OP_DCS_L  = 3'd3;
  localparam logic [2:0] OP_VLINE  = 3'd4;
  localparam logic [2:0] OP_DCS_RD = 3'd5;

  // decoded packet record
  logic [7:0]  rx_dt;
  logic [15:0] rx_len;
  bit          rx_long;
  logic [7:0]  rx_pay [0:255];
  logic [7:0]  exp_pay [0:255];

  // ------------------------------------------------------------------
  // reference models (independent copies of the spec math)
  // ------------------------------------------------------------------
  function automatic logic [5:0] ecc24(input logic [23:0] d);
    begin
      ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
      ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
      ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
      ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
      ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
      ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    end
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c,
                                             input logic [7:0]  d);
    logic [15:0] v;
    begin
      v = c ^ {8'h00, d};
      for (int k = 0; k < 8; k++)
        v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      crc16_byte = v;
    end
  endfunction

  task automatic check(input bit cond, input string tag);
    begin
      if (!cond) begin
        errors++;
        $display("ERROR: %s", tag);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // peripheral receive tasks (sample host bits at negedge)
  // ------------------------------------------------------------------
  task automatic recv_byte(output logic [7:0] b, input string tag);
    begin
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        b[i] = tx_bit;
        if (tx_valid !== 1'b1) begin
          errors++;
          $display("ERROR: %s tx_valid dropped mid-byte (bit %0d)", tag, i);
        end
      end
    end
  endtask

  // DSI data-type table: short packets carry a 16-bit data field, long
  // packets carry WC payload bytes (unlike CSI-2, not a plain 0x10 split)
  function automatic bit is_short_dt(input logic [7:0] dt);
    begin
      case (dt[5:0])
        6'h01, 6'h11, 6'h21, 6'h31,                 // video sync events
        6'h08,                                      // EoTp
        6'h02, 6'h12, 6'h22, 6'h32,                 // color mode/shutdown
        6'h03, 6'h13, 6'h23,                        // generic short write
        6'h04, 6'h14, 6'h24,                        // generic read
        6'h05, 6'h15, 6'h06, 6'h37:                 // DCS short/read, max ret
          is_short_dt = 1'b1;
        default:
          is_short_dt = 1'b0;
      endcase
    end
  endfunction

  // receive one packet: checks SoT, ECC, CRC; fills rx_* record
  task automatic recv_packet(input string tag);
    logic [7:0]  b, b0, b1, b2, be, cl, ch;
    logic [15:0] c;
    begin
      wait (tx_valid === 1'b1);
      recv_byte(b, tag);
      check(b == 8'hB8, {tag, " SoT != 8'hB8"});
      recv_byte(b0, tag);
      recv_byte(b1, tag);
      recv_byte(b2, tag);
      recv_byte(be, tag);
      check(be[5:0] == ecc24({b2, b1, b0}), {tag, " header ECC mismatch"});
      check(be[7:6] == 2'b00, {tag, " ECC P7/P6 not zero"});
      rx_dt   = b0;
      rx_len  = {b2, b1};
      rx_long = !is_short_dt(b0);
      c = 16'hFFFF;
      if (rx_long) begin
        for (int i = 0; i < rx_len; i++) begin
          recv_byte(b, tag);
          rx_pay[i] = b;
          c = crc16_byte(c, b);
        end
        recv_byte(cl, tag);
        recv_byte(ch, tag);
        check({ch, cl} == c, {tag, " payload CRC-16 mismatch"});
      end
      // do not race the tx_valid tail cycle into the next packet hunt
      wait (tx_valid === 1'b0);
    end
  endtask

  // ------------------------------------------------------------------
  // host-side command helpers
  // ------------------------------------------------------------------
  task automatic do_cmd(input logic [2:0] op, input logic [5:0] dt,
                        input logic [7:0] dcs, input logic [15:0] len,
                        input logic [15:0] len2);
    begin
      @(negedge clk);
      cmd_op    <= op;
      cmd_dt    <= dt;
      cmd_dcs   <= dcs;
      cmd_len   <= len;
      cmd_len2  <= len2;
      cmd_valid <= 1'b1;
      @(negedge clk);
      cmd_valid <= 1'b0;
    end
  endtask

  task automatic pl_write(input int n);
    begin
      for (int i = 0; i < n; i++) begin
        @(negedge clk);
        pl_we    <= 1'b1;
        pl_addr  <= 5'(i);
        pl_wdata <= exp_pay[i];
      end
      @(negedge clk);
      pl_we <= 1'b0;
    end
  endtask

  // peripheral BTA response: short packet, ecc_xor corrupts the ECC byte
  task automatic send_resp(input logic [7:0] dt, input logic [15:0] data,
                           input logic [7:0] ecc_xor);
    logic [7:0] resp [0:4];
    begin
      resp[0] = 8'hB8;
      resp[1] = dt;
      resp[2] = data[7:0];
      resp[3] = data[15:8];
      resp[4] = {2'b00, ecc24({data[15:8], data[7:0], dt})} ^ ecc_xor;
      wait (tx_oe === 1'b0);
      repeat (4) @(negedge clk);
      for (int j = 0; j < 5; j++)
        for (int i = 0; i < 8; i++) begin
          @(negedge clk);
          rx_bit <= resp[j][i];
        end
      @(negedge clk);
      rx_bit <= 1'b1;
    end
  endtask

  // receive the BTA trigger byte after a read request
  task automatic recv_bta_trig;
    logic [7:0] b;
    begin
      wait (tx_valid === 1'b1);
      recv_byte(b, "BTA trigger");
      check(b == 8'h84, "BTA trigger byte != 8'h84");
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // (1) reset state
    check(tx_valid == 1'b0 && tx_oe == 1'b1 && cmd_busy == 1'b0 &&
          irq == 1'b0 && pkt_cnt == 0, "reset state");

    // (2) DCS short write 0 param: set_display_on (0x29)
    do_cmd(OP_DCS_S0, 6'h0, 8'h29, 16'h0, 16'h0);
    recv_packet("dcs_s0");
    check(rx_dt == 8'h05, "dcs_s0 DT != 0x05");
    check(rx_len == 16'h0029, "dcs_s0 data field != {0x00,0x29}");
    wait (cmd_busy == 1'b0);
    check(pkt_cnt == 1, "pkt_cnt after dcs_s0");

    // (3) DCS short write 1 param: set_pixel_format (0x3A), param 0x77
    exp_pay[0] = 8'h77;
    pl_write(1);
    do_cmd(OP_DCS_S1, 6'h0, 8'h3A, 16'h0, 16'h0);
    recv_packet("dcs_s1");
    check(rx_dt == 8'h15, "dcs_s1 DT != 0x15");
    check(rx_len == 16'h773A, "dcs_s1 data field != {param,0x3A}");
    wait (cmd_busy == 1'b0);

    // (4) DCS long write: column_address_set (0x2A) + 4 params
    exp_pay[0] = 8'h00; exp_pay[1] = 8'h00;
    exp_pay[2] = 8'h01; exp_pay[3] = 8'h3F;
    pl_write(4);
    do_cmd(OP_DCS_L, 6'h0, 8'h2A, 16'd4, 16'h0);
    recv_packet("dcs_l");
    check(rx_dt == 8'h39, "dcs_l DT != 0x39");
    check(rx_len == 16'd4, "dcs_l WC != 4");
    for (int i = 0; i < 4; i++)
      check(rx_pay[i] == exp_pay[i], "dcs_l payload mismatch");
    wait (cmd_busy == 1'b0);

    // (5) video-mode line: HSS/HSE/HBP(4)/HACT(RGB888, 2 px = 6 B)
    exp_pay[0] = 8'h11; exp_pay[1] = 8'h22; exp_pay[2] = 8'h33;
    exp_pay[3] = 8'hAA; exp_pay[4] = 8'hBB; exp_pay[5] = 8'hCC;
    pl_write(6);
    do_cmd(OP_VLINE, 6'h0, 8'h00, 16'd6, 16'd4);
    recv_packet("vline.hss");
    check(rx_dt == 8'h21 && !rx_long, "vline HSS");
    recv_packet("vline.hse");
    check(rx_dt == 8'h31 && !rx_long, "vline HSE");
    recv_packet("vline.hbp");
    check(rx_dt == 8'h19 && rx_long && rx_len == 16'd4, "vline HBP");
    for (int i = 0; i < 4; i++)
      check(rx_pay[i] == 8'h00, "vline HBP blanking not zero");
    recv_packet("vline.hact");
    check(rx_dt == 8'h3E && rx_long && rx_len == 16'd6, "vline HACT");
    for (int i = 0; i < 6; i++)
      check(rx_pay[i] == exp_pay[i], "vline HACT pixel mismatch");
    wait (cmd_busy == 1'b0);
    check(pkt_cnt == 7, "pkt_cnt after vline (3+4)");

    // (6) DCS read + BTA: peripheral answers power-mode 0x9C
    do_cmd(OP_DCS_RD, 6'h0, 8'h0A, 16'h0, 16'h0);
    recv_packet("dcs_rd");
    check(rx_dt == 8'h06, "dcs_rd DT != 0x06");
    check(rx_len == 16'h000A, "dcs_rd data field != {0x00,0x0A}");
    recv_bta_trig();
    send_resp(8'h21, 16'h009C, 8'h00);      // DCS read short resp 1 param
    wait (bta_done === 1'b1);
    check(bta_data == 24'h009C21, "BTA response data mismatch");
    wait (cmd_busy == 1'b0);
    check(tx_oe == 1'b1 && irq == 1'b0, "bus returned to host, no irq");

    // (7) BTA response with single-bit error in ECC byte: corrected
    do_cmd(OP_DCS_RD, 6'h0, 8'h0A, 16'h0, 16'h0);
    recv_packet("dcs_rd2");
    recv_bta_trig();
    send_resp(8'h21, 16'h009C, 8'h08);      // flip one ECC bit
    wait (bta_done === 1'b1);
    check(bta_data == 24'h009C21 && irq == 1'b0,
          "BTA single-bit ECC corrected");
    wait (cmd_busy == 1'b0);

    // (8) BTA response with double-bit ECC error: uncorrectable -> irq
    do_cmd(OP_DCS_RD, 6'h0, 8'h0A, 16'h0, 16'h0);
    recv_packet("dcs_rd3");
    recv_bta_trig();
    send_resp(8'h21, 16'h009C, 8'h03);      // two ECC bits flipped
    wait (cmd_busy == 1'b0);
    #1;
    check(irq == 1'b1 && bta_done == 1'b0, "BTA bad ECC -> irq");

    // (9) recovery: good read again clears irq
    do_cmd(OP_DCS_RD, 6'h0, 8'h0A, 16'h0, 16'h0);
    recv_packet("dcs_rd4");
    recv_bta_trig();
    send_resp(8'h21, 16'h0055, 8'h00);
    wait (bta_done === 1'b1);
    check(bta_data == 24'h005521 && irq == 1'b0, "BTA recovery clears irq");
    wait (cmd_busy == 1'b0);

    // (10) BTA timeout: nobody answers -> irq
    do_cmd(OP_DCS_RD, 6'h0, 8'h0A, 16'h0, 16'h0);
    recv_packet("dcs_rd5");
    recv_bta_trig();
    wait (cmd_busy == 1'b0);
    #1;
    check(irq == 1'b1 && tx_oe == 1'b1, "BTA timeout -> irq, bus reclaimed");

    // (11) back-to-back commands after errors
    do_cmd(OP_DCS_S0, 6'h0, 8'h29, 16'h0, 16'h0);
    recv_packet("b2b.1");
    check(rx_dt == 8'h05, "b2b.1 DT");
    wait (cmd_busy == 1'b0);
    do_cmd(OP_SPKT, 6'h01, 8'h00, 16'h0000, 16'h0);   // VSS raw short
    recv_packet("b2b.2");
    check(rx_dt == 8'h01, "b2b.2 VSS DT");
    wait (cmd_busy == 1'b0);
    check(pkt_cnt == 14, "pkt_cnt final");

    // ---- report ----
    if (errors == 0) $display("TEST PASSED: DSI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #1000000;
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
