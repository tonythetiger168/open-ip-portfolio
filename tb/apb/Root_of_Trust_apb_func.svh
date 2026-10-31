// SPDX-License-Identifier: Apache-2.0
// Root_of_Trust-specific part of tb/Root_of_Trust_apb_tb.sv: an OTP model
// on the OTP pins (random latency, random read data between acknowledges);
// the device is taken from RAW through TEST to DEV entirely through the
// registers: refused reads and programs (ACCESS alert), a wrong token (TOKEN
// alert), a reserved command, the RAW unlock, programming the UDS, digest and
// token hash in TEST, the test exit, the anti-rollback word in DEV, then a
// verified boot through IMG0 / IMG1 (boot case 2 of tb/Root_of_Trust_vec.svh:
// the device key is compared) and an overflowing IMG write; finally the
// escalation input. Then every boot case of tb/Root_of_Trust_vec.svh through
// IMG0 / IMG1 (the OTP preloaded by the TB, the device key compared).
`include "Root_of_Trust_vec.svh"
logic [31:0] otp [0:63];
int          otp_lat;
initial begin
  esc = 1'b0;
  for (int i = 0; i < 64; i++) otp[i] = '0;
end
always @(posedge PCLK or negedge PRESETN) begin
  if (!PRESETN) begin otp_ack <= 1'b0; otp_lat <= 0; otp_rdata <= '0; end
  else begin
    otp_ack <= 1'b0;
    otp_rdata <= $urandom;
    if (otp_req && !otp_ack) begin
      if (otp_lat == 0) begin
        otp_ack <= 1'b1;
        if (otp_we) otp[otp_addr] <= otp[otp_addr] | otp_wdata;
        else otp_rdata <= otp[otp_addr];
        otp_lat <= $urandom_range(0, 3);
      end else otp_lat <= otp_lat - 1;
    end
  end
end

// UDS, digest and key of boot case 2 (DEV, anti-rollback 3 bits, version 5, 2 words)
localparam logic [255:0] RT_UDS = 256'hd717f14579b2aa100fbbb34fa593feaed27248b762e3ab5805f0765a2b9c1d7e;
localparam logic [255:0] RT_DIG = 256'hfd1cca99d920eff6c7d60cc553c8efe2c30c0a72072c740d1fc18305d8dca96b;
localparam logic [255:0] RT_KEY = 256'h8bad59d8fea2daeffac093d9c3b50bfcf193affca3ce622e45f7492c3567d124;

task automatic rt_status(input logic [2:0] s, input logic bok, input logic ce, input logic de, input logic kv);
  rd(A_STATUS);
  if (rdv[0] || !rdv[1] || rdv[4:2] != s || rdv[5] != bok || rdv[6] != ce || rdv[7] != de || rdv[8] != kv)
    fail($sformatf("STATUS %h: expected state %0d boot_ok %0d cpu_en %0d dbg_en %0d key_valid %0d", rdv, s, bok, ce, de, kv));
  if (lc_state != s || cpu_en != ce || dbg_en != de || key_valid != kv) fail("pins differ from STATUS");
endtask

// run a command; e: CMD_ERR expected, al: ALERT code expected (0: none)
task automatic rt_cmd(input logic [1:0] op, input logic [5:0] a, input logic [31:0] d, input logic e,
                      input logic [2:0] al);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD_DATA, d);
  wr(A_CTRL, {24'd0, a, op});
  wr(A_CMD, 32'h1);
  wr(A_CMD, 32'h1);                                   // ignored while busy (or a second command)
  poll(A_IRQ_STATUS, 32'h1 << IRQ_CMD_DONE, 32'h1 << IRQ_CMD_DONE, 3000);
  rd(A_STATUS);
  while (rdv[0]) rd(A_STATUS);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_CMD_ERR] != e) fail($sformatf("command %0d at %0d: CMD_ERR %0d", op, a, rdv[IRQ_CMD_ERR]));
  if (rdv[IRQ_ALERT] != (al != 0)) fail($sformatf("command %0d at %0d: ALERT %0d", op, a, rdv[IRQ_ALERT]));
  if (al != 0) begin
    rd(A_STATUS);
    if (rdv[11:9] != al) fail($sformatf("alert code %0d, expected %0d", rdv[11:9], al));
  end
endtask

task automatic rt_token(input logic [127:0] t);
  wr(A_TOKEN0, t[31:0]); wr(A_TOKEN1, t[63:32]); wr(A_TOKEN2, t[95:64]); wr(A_TOKEN3, t[127:96]);
endtask

task automatic rt_prog256(input logic [5:0] base, input logic [255:0] v);
  for (int i = 0; i < 8; i++) rt_cmd(2'd1, base + 6'(i), v[32 * (7 - i) +: 32], 0, 0);
endtask

task automatic rt_reset;
  cycles(2);
  PRESETN = 0;
  cycles(3);
  PRESETN = 1;
  cycles(2);
  poll(A_STATUS, 32'h2, 32'h2, 200);
  wr(A_IRQ_ENABLE, IRQ_ALL);                          // every interrupt drives the pin
endtask

task automatic rt_img(input logic [31:0] w, input logic last);
  rd(A_FLAGS);
  while (rdv[FLAG_IMG_FULL]) rd(A_FLAGS);
  wr(A_IMG0, w);
  wr(A_IMG1, {31'd0, last});
endtask

// a boot case of tb/Root_of_Trust_vec.svh, the OTP preloaded
task automatic boot_case(input logic [31:0] lcw, input logic [31:0] arb, input logic [255:0] uds,
                         input logic [255:0] dig, input logic [31:0] ver, input int n, input logic [31:0] seed,
                         input logic ok, input logic [255:0] key);
  logic [31:0] x;
  for (int i = 0; i < 64; i++) otp[i] = '0;
  otp[32] = lcw; otp[34] = arb;
  for (int i = 0; i < 8; i++) begin otp[i] = uds[32 * (7 - i) +: 32]; otp[8 + i] = dig[32 * (7 - i) +: 32]; end
  rt_reset();
  wr(A_IRQ_STATUS, IRQ_ALL);
  x = seed;
  for (int i = 0; i < n; i++) begin
    if (i > 0) begin x ^= x << 13; x ^= x >> 17; x ^= x << 5; end
    rt_img(i == 0 ? ver : x, i == n - 1);
  end
  poll(A_IRQ_STATUS, 32'h1 << IRQ_BOOT, 32'h1 << IRQ_BOOT, 3000);
  rt_status(lcw == 32'h0000_FFFF ? 3'd2 : 3'd3, ok, ok, lcw == 32'h0000_FFFF, ok);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ALERT] == ok) fail($sformatf("boot case: ALERT %0d", rdv[IRQ_ALERT]));
  if (ok && key_out != key) fail($sformatf("boot case: device key %h", key_out));
endtask

task automatic ip_func;
  logic [31:0] x;
  wr(A_IMG0, 32'hFFFF_FFFF); wr(A_IMG0, 32'h0);       // not committed without IMG1
  // RAW: no boot, no debug
  poll(A_STATUS, 32'h2, 32'h2, 200);
  rt_status(3'd0, 0, 0, 0, 0);
  rt_cmd(2'd0, 6'd40, '0, 0, 0);                      // read a spare word
  rd_exp(A_RDATA, 0);
  rt_cmd(2'd0, 6'd3, '0, 1, 3'd4);                    // the UDS cannot be read
  rt_cmd(2'd1, 6'd0, 32'h1, 1, 3'd4);                 // nor programmed in RAW
  rt_cmd(2'd3, 6'd0, '0, 1, 0);                       // reserved command
  rt_cmd(2'd2, 6'd0, 32'd2, 1, 0);                    // RAW -> DEV is not a transition
  rt_token(~TOK_RAW);
  rt_cmd(2'd2, 6'd0, 32'd1, 1, 3'd3);                 // wrong token
  rt_token(TOK_RAW);
  rt_cmd(2'd2, 6'd0, 32'd1, 0, 0);                    // RAW -> TEST
  rt_cmd(2'd1, 6'd40, 32'h1, 1, 0);                   // nothing more until reset
  rt_token('0);
  if (otp[32] != 32'h0000_00FF) fail($sformatf("lifecycle word %h after RAW -> TEST", otp[32]));
  rt_reset();
  // TEST: boots without verification, debug open; provision the secrets
  rt_status(3'd1, 1, 1, 1, 0);
  rt_prog256(6'd0, RT_UDS);
  rt_prog256(6'd8, RT_DIG);
  rt_prog256(6'd16, TOKH_TEST);
  for (int i = 0; i < 8; i++) begin                   // read the digest and token hash back
    rt_cmd(2'd0, 6'(8 + i), '0, 0, 0);
    rd_exp(A_RDATA, RT_DIG[32 * (7 - i) +: 32]);
    rt_cmd(2'd0, 6'(16 + i), '0, 0, 0);
    rd_exp(A_RDATA, TOKH_TEST[32 * (7 - i) +: 32]);
  end
  rt_cmd(2'd1, 6'd41, 32'hFFFF_FFFF, 0, 0);           // a spare word
  rt_cmd(2'd0, 6'd41, '0, 0, 0);
  rd_exp(A_RDATA, 32'hFFFF_FFFF);
  rt_cmd(2'd0, 6'd42, '0, 0, 0);
  rd_exp(A_RDATA, 32'h0);
  rt_cmd(2'd1, 6'd34, 32'h7, 1, 3'd4);                // anti-rollback is closed in TEST
  rt_token(TOK_TEST);
  rt_cmd(2'd2, 6'd0, 32'd2, 0, 0);                    // TEST -> DEV
  rt_token('0);
  rt_reset();
  // DEV: program the anti-rollback word, then a verified boot
  rt_status(3'd2, 0, 0, 1, 0);
  rt_cmd(2'd1, 6'd34, 32'h7, 0, 0);
  rt_cmd(2'd1, 6'd0, 32'h1, 1, 3'd4);                 // the UDS is closed in DEV
  rt_reset();
  rt_status(3'd2, 0, 0, 1, 0);
  wr(A_IRQ_ENABLE, 0);                                // this boot with the interrupts masked
  wr(A_IRQ_STATUS, IRQ_ALL);
  x = 32'h119a72d1;
  x ^= x << 13; x ^= x >> 17; x ^= x << 5;
  rt_img(32'd5, 0);
  rt_img(x, 1);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_BOOT, 32'h1 << IRQ_BOOT, 3000);
  rt_status(3'd2, 1, 1, 1, 1);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ALERT] || !rdv[IRQ_IMG_DONE]) fail($sformatf("IRQ_STATUS %h after the boot", rdv));
  if (key_out != RT_KEY) fail($sformatf("device key %h", key_out));
  // a second image is not taken: the beat stays, the next write overflows
  wr(A_IMG0, 32'h0); wr(A_IMG1, 32'h1);
  wr(A_IMG1, 32'h1);
  rd(A_FLAGS);
  if (!rdv[FLAG_IMG_FULL]) fail("second image taken");
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_IMG_OVF]) fail("IMG_OVF");
  // escalation: everything off until reset
  wr(A_IRQ_STATUS, IRQ_ALL);
  @(negedge PCLK) esc = 1'b1;
  @(negedge PCLK) esc = 1'b0;
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ALERT]) fail("ALERT on escalation");
  rd(A_STATUS);
  if (rdv[11:9] != 3'd6 || rdv[4:2] != 3'd7 || rdv[6] || rdv[7] || rdv[8]) fail($sformatf("STATUS %h after escalation", rdv));
  if (cpu_en || dbg_en || key_valid || key_out != '0) fail("pins after escalation");
  wr(A_IRQ_STATUS, IRQ_ALL);                          // commands are ignored
  wr(A_CTRL, {24'd0, 6'd40, 2'd0});
  wr(A_CMD, 32'h1);
  cycles(20);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_CMD_DONE]) fail("command after escalation");
  rt_reset();
  boot_cases();
  wr(A_IMG0, 32'h0); wr(A_IMG1, 32'h1); wr(A_IMG1, 32'h1);   // overflow, now with the pin enabled
  if (!irq) fail("irq pin on IMG_OVF");
  wr(A_IRQ_ENABLE, 0);
  esc = 1'b0;
endtask
