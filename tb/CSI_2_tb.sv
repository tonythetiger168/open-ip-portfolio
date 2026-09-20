// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for CSI_2_top (MIPI CSI-2 RX, packet layer)
// TB plays the camera/CSI-2 transmitter: serial SoT + packets (1 bit/clk),
// with ECC + CRC-16 computed here the same way the spec defines them.
// Checks: reset state / FS-FE short packets / RAW8 long packet line-buffer
// readback / ECC single-bit correction (data + ECC byte) / ECC double-bit
// drop + irq / CRC-16 corruption drop + irq / mid-packet abort / back-to-back
// frames.
// ============================================================================
`timescale 1ns/1ps
module CSI_2_tb;

  logic        clk = 0, rst_n = 0;
  logic        rx_bit = 0, rx_valid = 0;
  logic        irq, frame_active;
  logic [15:0] frame_cnt, line_cnt, last_wc, lb_len;
  logic [7:0]  last_dt;
  logic [3:0]  err_flags;
  logic [8:0]  lb_addr = 0;
  logic [7:0]  lb_rdata;

  int errors = 0;

  CSI_2_top dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .rx_valid(rx_valid),
    .irq(irq), .frame_active(frame_active),
    .frame_cnt(frame_cnt), .line_cnt(line_cnt),
    .last_dt(last_dt), .last_wc(last_wc),
    .err_flags(err_flags), .lb_len(lb_len),
    .lb_addr(lb_addr), .lb_rdata(lb_rdata)
  );

  always #5 clk = ~clk;

  // payload staging memory (camera image line)
  logic [7:0] payload_mem [0:1023];

  // ------------------------------------------------------------------
  // reference models (same math as DUT, written independently)
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

  // ------------------------------------------------------------------
  // lane driving tasks (camera side)
  // ------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] d);
    begin
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        rx_valid <= 1'b1;
        rx_bit   <= d[i];
      end
    end
  endtask

  task automatic send_idle(input int n);
    begin
      @(negedge clk);
      rx_valid <= 1'b0;
      rx_bit   <= 1'b0;
      repeat (n) @(negedge clk);
    end
  endtask

  // short packet: DI={VC,DT}, 16-bit data field, ECC
  task automatic send_short(input logic [5:0] dt, input logic [1:0] vc,
                            input logic [15:0] data);
    logic [7:0] b0;
    begin
      b0 = {vc, dt};
      send_byte(8'hB8);
      send_byte(b0);
      send_byte(data[7:0]);
      send_byte(data[15:8]);
      send_byte({2'b00, ecc24({data, b0})});
      send_idle(6);
    end
  endtask

  // long packet from payload_mem[0..wc-1]; hdr_xor/ecc_xor corrupt the
  // header/ECC bytes on the wire; bad_crc flips the footer CRC
  task automatic send_long(input logic [5:0] dt, input logic [1:0] vc,
                           input logic [15:0] wc,
                           input logic [23:0] hdr_xor,
                           input logic [7:0]  ecc_xor,
                           input bit          bad_crc);
    logic [7:0]  b0;
    logic [15:0] c;
    begin
      b0 = {vc, dt};
      c  = 16'hFFFF;
      send_byte(8'hB8);
      send_byte(b0        ^ hdr_xor[7:0]);
      send_byte(wc[7:0]   ^ hdr_xor[15:8]);
      send_byte(wc[15:8]  ^ hdr_xor[23:16]);
      send_byte({2'b00, ecc24({wc, b0})} ^ ecc_xor);
      for (int i = 0; i < wc; i++) begin
        send_byte(payload_mem[i]);
        c = crc16_byte(c, payload_mem[i]);
      end
      if (bad_crc) c = c ^ 16'hA5A5;
      send_byte(c[7:0]);
      send_byte(c[15:8]);
      send_idle(6);
    end
  endtask

  // compare DUT line buffer against payload_mem[0..len-1]
  task automatic check_line(input int len, input string tag);
    begin
      if (lb_len !== 16'(len)) begin
        errors++;
        $display("ERROR: %s lb_len=%0d exp=%0d", tag, lb_len, len);
      end
      for (int i = 0; i < len; i++) begin
        lb_addr = 9'(i);
        #1;
        if (lb_rdata !== payload_mem[i]) begin
          errors++;
          $display("ERROR: %s lb[%0d] got=%02h exp=%02h",
                   tag, i, lb_rdata, payload_mem[i]);
        end
      end
    end
  endtask

  task automatic check(input bit cond, input string tag);
    begin
      if (!cond) begin
        errors++;
        $display("ERROR: %s", tag);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    // ---- reset ----
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // (1) reset state
    check(frame_cnt == 0 && line_cnt == 0 && irq == 1'b0 &&
          frame_active == 1'b0 && lb_len == 0, "reset state");

    // ---- frame 0: FS + 2 RAW8 lines + FE ----
    for (int i = 0; i < 16; i++) payload_mem[i] = 8'h10 + i[7:0];
    send_short(6'h00, 2'd0, 16'd0);                 // FS
    check(frame_cnt == 1 && frame_active == 1'b1 && line_cnt == 0,
          "FS: frame_cnt=1 active");
    send_long(6'h2B, 2'd0, 16'd16, 24'h0, 8'h0, 0); // RAW8 line 0
    check(line_cnt == 1 && irq == 1'b0, "line0 committed");
    check(last_dt == 8'h2B && last_wc == 16'd16, "line0 DT/WC status");
    check_line(16, "line0");

    for (int i = 0; i < 32; i++) payload_mem[i] = 8'hA0 + i[7:0];
    send_long(6'h2B, 2'd0, 16'd32, 24'h0, 8'h0, 0); // RAW8 line 1
    check(line_cnt == 2, "line1 committed");
    check_line(32, "line1");

    send_short(6'h01, 2'd0, 16'd0);                 // FE
    check(frame_active == 1'b0 && frame_cnt == 1, "FE: frame end");

    // ---- frame 1: ECC single-bit correction ----
    for (int i = 0; i < 8; i++) payload_mem[i] = 8'h40 + i[7:0];
    send_short(6'h00, 2'd0, 16'd1);                 // FS frame 1
    check(frame_cnt == 2 && line_cnt == 0, "FS frame1");
    // flip header bit 15 (WC[7]) on the wire: must be corrected
    send_long(6'h2B, 2'd0, 16'd8, 24'h008000, 8'h00, 0);
    check(line_cnt == 1 && irq == 1'b0 && err_flags[3] == 1'b1,
          "ECC single-bit (WC) corrected");
    check(last_wc == 16'd8, "corrected WC=8");
    check_line(8, "ecc-corr line");
    // flip one ECC-byte bit on the wire: data untouched, counted corrected
    send_long(6'h2B, 2'd0, 16'd8, 24'h000000, 8'h10, 0);
    check(line_cnt == 2 && irq == 1'b0, "ECC single-bit (ECC byte) accepted");
    check_line(8, "ecc-byte line");

    // ---- ECC double-bit error: uncorrectable, drop + irq ----
    send_long(6'h2B, 2'd0, 16'd8, 24'h000003, 8'h00, 0);
    check(irq == 1'b1 && err_flags[1] == 1'b1 && line_cnt == 2,
          "ECC double-bit dropped + irq");

    // ---- CRC-16 corruption: drop + irq, then recovery ----
    for (int i = 0; i < 8; i++) payload_mem[i] = 8'h70 + i[7:0];
    send_long(6'h2B, 2'd0, 16'd8, 24'h0, 8'h0, 1);  // bad CRC
    check(irq == 1'b1 && err_flags[0] == 1'b1 && line_cnt == 2,
          "CRC bad dropped + irq");
    check(lb_len == 16'd8, "bad CRC line not committed (lb_len kept)");
    send_long(6'h2B, 2'd0, 16'd8, 24'h0, 8'h0, 0);  // good again
    check(irq == 1'b0 && line_cnt == 3, "good packet clears irq");
    check_line(8, "recovery line");

    // ---- mid-packet abort (link idle before packet end) ----
    send_byte(8'hB8);
    send_byte(8'h2B);
    send_idle(6);                                   // abort in header
    check(err_flags[2] == 1'b1, "mid-packet abort flagged");
    check(line_cnt == 3, "abort does not commit");

    // ---- back-to-back traffic: 3 lines, no gap issues ----
    for (int i = 0; i < 12; i++) payload_mem[i] = 8'hC0 + i[7:0];
    send_long(6'h2B, 2'd0, 16'd12, 24'h0, 8'h0, 0);
    send_long(6'h2B, 2'd0, 16'd12, 24'h0, 8'h0, 0);
    send_long(6'h2B, 2'd0, 16'd12, 24'h0, 8'h0, 0);
    check(line_cnt == 6 && irq == 1'b0, "back-to-back lines");
    check_line(12, "b2b line");

    // ---- report ----
    if (errors == 0) $display("TEST PASSED: CSI_2");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #500000;
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
