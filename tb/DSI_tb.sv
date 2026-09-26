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

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int DSI_FSM_TOTAL = 18;  // TX: 13 states + BTA RX sub-FSM: 5
  logic [17:0] fsm_seen = '0;         // visited-state bitmap
  wire  [3:0] dut_state = dut.state;  // hierarchical FSM probes
  wire  [2:0] dut_rbst  = dut.rbst;

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

  // FSM coverage: sample both DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_state]      <= 1'b1;
    fsm_seen[13 + dut_rbst]  <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit        first_cycle = 1;  // skip the very first posedge (DUT reset
                               // values land in that NBA region)
  logic [15:0] pc_q = 0;
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(tx_valid === 1'b0 && tx_oe === 1'b1 && cmd_busy === 1'b0 &&
                irq === 1'b0 && pkt_cnt === 16'h0 && bta_done === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: the host only drives the lane while it owns it
      sva_check(!tx_valid || tx_oe === 1'b1, "A2 tx_valid implies tx_oe");
      // A3: packet counter never decreases
      sva_check(pkt_cnt >= pc_q, "A3 pkt_cnt monotone");
      // A4: the bus is turned around only inside the BTA window states
      sva_check(tx_oe === 1'b1 ||
                (dut_state == 4'd10 || dut_state == 4'd11 ||
                 dut_state == 4'd12), "A4 tx_oe low only in BTA");
      // A5: cmd_busy mirrors the FSM being out of idle
      sva_check(cmd_busy === (dut_state != 4'd0), "A5 cmd_busy mirrors FSM");
      // A6: a completed BTA never coincides with the error flag
      sva_check(!bta_done || irq === 1'b0, "A6 bta_done excludes irq");
    end
    pc_q <= pkt_cnt;
  end
`endif

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

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized command transactions. Classes: DCS short writes
    // (0/1 random param), DCS long writes (random len/payload), raw
    // short packets (random DT/data), video-mode lines (random HACT/
    // HBP), DCS reads with good BTA responses (random param). Error
    // injection (round-robin): BTA response with single-bit ECC error
    // (corrected), double-bit ECC error (irq + recovery), BTA timeout
    // (irq + recovery). Every packet is received and checked byte by
    // byte (SoT/ECC/CRC/payload); a scoreboard tracks pkt_cnt.
    begin : crv_phase
      int n_s0 = 0, n_s1 = 0, n_l = 0, n_sp = 0, n_vl = 0, n_rd = 0;
      int n_e1 = 0, n_e2 = 0, n_to = 0, n_fr = 0;
      int roll, eroll = 0, nl, m_pc;
      logic [7:0] dcs_c, prm_c, dt8_c;
      logic [15:0] dat_c;
      m_pc = pkt_cnt;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 5) begin
          // ---- DCS short write 0 param ----
          n_s0++;
          dcs_c = 8'($urandom_range(0, 255));
          do_cmd(OP_DCS_S0, 6'h0, dcs_c, 16'h0, 16'h0);
          recv_packet("CRV dcs_s0");
          check(rx_dt == 8'h05, "CRV dcs_s0 DT");
          check(rx_len == {8'h00, dcs_c}, "CRV dcs_s0 data field");
          wait (cmd_busy == 1'b0);
          m_pc++;
          if (pkt_cnt !== 16'(m_pc)) begin
            errors++; $display("ERROR: CRV pkt_cnt got=%0d exp=%0d",
                               pkt_cnt, m_pc);
          end
        end else if (roll < 9) begin
          // ---- DCS short write 1 param ----
          n_s1++;
          dcs_c = 8'($urandom_range(0, 255));
          prm_c = 8'($urandom_range(0, 255));
          exp_pay[0] = prm_c;
          pl_write(1);
          do_cmd(OP_DCS_S1, 6'h0, dcs_c, 16'h0, 16'h0);
          recv_packet("CRV dcs_s1");
          check(rx_dt == 8'h15, "CRV dcs_s1 DT");
          check(rx_len == {prm_c, dcs_c}, "CRV dcs_s1 data field");
          wait (cmd_busy == 1'b0);
          m_pc++;
        end else if (roll < 13) begin
          // ---- DCS long write, random length + payload ----
          n_l++;
          dcs_c = 8'($urandom_range(0, 255));
          nl = 1 + $urandom_range(0, 15);
          for (int i = 0; i < nl; i++)
            exp_pay[i] = 8'($urandom_range(0, 255));
          pl_write(nl);
          do_cmd(OP_DCS_L, 6'h0, dcs_c, 16'(nl), 16'h0);
          recv_packet("CRV dcs_l");
          check(rx_dt == 8'h39, "CRV dcs_l DT");
          check(rx_len == 16'(nl), "CRV dcs_l WC");
          for (int i = 0; i < nl; i++)
            check(rx_pay[i] == exp_pay[i], "CRV dcs_l payload mismatch");
          wait (cmd_busy == 1'b0);
          m_pc++;
        end else if (roll < 16) begin
          // ---- raw short packet (passthrough DT + data) ----
          n_sp++;
          dt8_c = 8'($urandom_range(0, 255));
          if (!is_short_dt(dt8_c))                  // rejection sampling:
            dt8_c = {2'b00, 6'h01};                 // short-packet DTs only
          dat_c = 16'($urandom_range(0, 65535));
          do_cmd(OP_SPKT, dt8_c[5:0], 8'h00, dat_c, 16'h0);
          recv_packet("CRV spkt");
          check(rx_dt == {2'b00, dt8_c[5:0]}, "CRV spkt DT");
          check(rx_len == dat_c, "CRV spkt data field");
          wait (cmd_busy == 1'b0);
          m_pc++;
        end else if (roll < 19) begin
          // ---- video-mode line: HSS/HSE/HBP/HACT ----
          n_vl++;
          nl = 1 + $urandom_range(0, 7);        // HACT payload bytes
          for (int i = 0; i < nl; i++)
            exp_pay[i] = 8'($urandom_range(0, 255));
          pl_write(nl);
          do_cmd(OP_VLINE, 6'h0, 8'h00, 16'(nl),
                 16'(1 + $urandom_range(0, 5)));  // HBP blanking bytes
          recv_packet("CRV vline.hss");
          check(rx_dt == 8'h21 && !rx_long, "CRV vline HSS");
          recv_packet("CRV vline.hse");
          check(rx_dt == 8'h31 && !rx_long, "CRV vline HSE");
          recv_packet("CRV vline.hbp");
          check(rx_dt == 8'h19 && rx_long, "CRV vline HBP");
          recv_packet("CRV vline.hact");
          check(rx_dt == 8'h3E && rx_long && rx_len == 16'(nl),
                "CRV vline HACT");
          for (int i = 0; i < nl; i++)
            check(rx_pay[i] == exp_pay[i], "CRV vline HACT payload");
          wait (cmd_busy == 1'b0);
          m_pc += 4;
        end else if (roll < 24) begin
          // ---- DCS read + good BTA response (random param) ----
          n_rd++;
          dcs_c = 8'($urandom_range(0, 255));
          dat_c = 16'($urandom_range(0, 65535));
          dt8_c = 8'($urandom_range(0, 255));   // random response DT
          do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
          recv_packet("CRV dcs_rd");
          check(rx_dt == 8'h06, "CRV dcs_rd DT");
          check(rx_len == {8'h00, dcs_c}, "CRV dcs_rd data field");
          recv_bta_trig();
          send_resp(dt8_c, dat_c, 8'h00);
          wait (bta_done === 1'b1);
          check(bta_data == {dat_c, dt8_c}, "CRV BTA data");
          wait (cmd_busy == 1'b0);
          check(tx_oe == 1'b1 && irq == 1'b0, "CRV BTA clean return");
          m_pc++;
        end else begin
          // ---- error-injection classes (round-robin) ----
          dcs_c = 8'($urandom_range(0, 255));
          prm_c = 8'($urandom_range(0, 255));
          case (eroll)
            0: begin
              // BTA response with single-bit ECC error: corrected
              n_e1++;
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV e1.rd");
              recv_bta_trig();
              send_resp(8'h21, {8'h00, prm_c}, 8'h1 << $urandom_range(0, 5));
              wait (bta_done === 1'b1);
              check(bta_data == {8'h00, prm_c, 8'h21} && irq == 1'b0,
                    "CRV BTA single-bit corrected");
              wait (cmd_busy == 1'b0);
              m_pc++;
            end
            1: begin
              // BTA response with double-bit ECC error: irq + recovery
              n_e2++;
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV e2.rd");
              recv_bta_trig();
              send_resp(8'h21, {8'h00, prm_c},
                        (8'h1 << $urandom_range(0, 2)) |
                        (8'h1 << $urandom_range(3, 5)));
              wait (cmd_busy == 1'b0);
              #1;
              check(irq == 1'b1 && bta_done == 1'b0, "CRV BTA bad ECC irq");
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV e2.rec");
              recv_bta_trig();
              send_resp(8'h21, {8'h00, prm_c}, 8'h00);
              wait (bta_done === 1'b1);
              check(bta_data == {8'h00, prm_c, 8'h21} && irq == 1'b0,
                    "CRV BTA recovery clears irq");
              wait (cmd_busy == 1'b0);
              m_pc += 2;
            end
            2: begin
              // BTA response with bad framing (no SoT): irq + recovery
              n_fr++;
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV fr.rd");
              recv_bta_trig();
              begin
                logic [7:0] resp [0:4];
                resp[0] = 8'($urandom_range(0, 255));
                if (resp[0] == 8'hB8) resp[0] = 8'hB9;  // rejection sampling
                resp[1] = 8'h21;
                resp[2] = prm_c;
                resp[3] = 8'h00;
                resp[4] = {2'b00, ecc24({8'h00, prm_c, 8'h21})};
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
              wait (cmd_busy == 1'b0);
              #1;
              check(irq == 1'b1, "CRV BTA bad framing: no irq");
              m_pc++;
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV fr.rec");
              recv_bta_trig();
              send_resp(8'h21, {8'h00, prm_c}, 8'h00);
              wait (bta_done === 1'b1);
              check(irq == 1'b0, "CRV framing recovery clears irq");
              wait (cmd_busy == 1'b0);
              m_pc++;
            end
            default: begin
              // BTA timeout: nobody answers -> irq, bus reclaimed
              n_to++;
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV to.rd");
              recv_bta_trig();
              wait (cmd_busy == 1'b0);
              #1;
              check(irq == 1'b1 && tx_oe == 1'b1,
                    "CRV BTA timeout irq + bus reclaimed");
              m_pc++;
              // recovery: good short write keeps irq semantics clean
              do_cmd(OP_DCS_RD, 6'h0, dcs_c, 16'h0, 16'h0);
              recv_packet("CRV to.rec");
              recv_bta_trig();
              send_resp(8'h21, {8'h00, prm_c}, 8'h00);
              wait (bta_done === 1'b1);
              check(irq == 1'b0, "CRV timeout recovery clears irq");
              wait (cmd_busy == 1'b0);
              m_pc++;
            end
          endcase
          eroll = (eroll + 1) % 4;
        end
      end
      // ---- pl_ram toggle sweep: 32-byte long writes with 0xFF then
      //      0x00 payloads -> every payload-RAM bit toggles both ways
      for (int i = 0; i < 32; i++) exp_pay[i] = 8'hFF;
      pl_write(32);
      do_cmd(OP_DCS_L, 6'h0, 8'h00, 16'd32, 16'h0);
      recv_packet("sweep ff");
      check(rx_len == 16'd32, "sweep ff WC");
      for (int i = 0; i < 32; i++)
        check(rx_pay[i] == 8'hFF, "sweep ff payload");
      wait (cmd_busy == 1'b0);
      for (int i = 0; i < 32; i++) exp_pay[i] = 8'h00;
      pl_write(32);
      do_cmd(OP_DCS_L, 6'h0, 8'h00, 16'd32, 16'h0);
      recv_packet("sweep 00");
      check(rx_len == 16'd32, "sweep 00 WC");
      wait (cmd_busy == 1'b0);
      m_pc += 2;
      if (pkt_cnt !== 16'(m_pc)) begin
        errors++; $display("ERROR: CRV final pkt_cnt got=%0d exp=%0d",
                           pkt_cnt, m_pc);
      end
      $display("CRV: 120 txns (s0=%0d s1=%0d long=%0d spkt=%0d vline=%0d read=%0d | ecc1=%0d ecc2=%0d timeout=%0d)",
               n_s0, n_s1, n_l, n_sp, n_vl, n_rd, n_e1, n_e2, n_to);
    end
`endif

    // ---- report ----
    if (errors == 0) $display("TEST PASSED: DSI");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < DSI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, DSI_FSM_TOTAL);
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
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (8000) #1000;    // 8 ms in 1-us chunks
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #1000000;
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
