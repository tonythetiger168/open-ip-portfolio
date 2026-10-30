// SPDX-License-Identifier: Apache-2.0
// Root_of_Trust_tb: self-checking testbench. An OTP model (64 words, a
// program only sets bits, a random number of clocks to each acknowledge,
// random read data between acknowledges, an optional stuck bit) sits on the
// OTP port. Boot cases from scripts/rot/gen_vec.py (digests and keys computed
// with Python's hashlib / hmac) are streamed in with random gaps; then the
// command port, the lifecycle transitions, the tamper input and resets in
// the middle of a boot or a command.
`timescale 1ns/1ps
module Root_of_Trust_tb;
  logic         clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic         otp_req, otp_we, otp_ack;
  logic [5:0]   otp_addr;
  logic [31:0]  otp_wdata, otp_rdata;
  logic         cmd_start, cmd_busy, cmd_done, cmd_err;
  logic [1:0]   cmd_op;
  logic [5:0]   cmd_addr;
  logic [31:0]  cmd_data, cmd_rdata;
  logic [127:0] token;
  logic         img_valid, img_last, img_ready;
  logic [31:0]  img_data;
  logic         init_done, boot_done, boot_ok, cpu_en, dbg_en, key_valid, alert, esc;
  logic [2:0]   lc_state, alert_code;
  logic [255:0] key_out;

  Root_of_Trust_top u_dut (.*);

  `include "Root_of_Trust_vec.svh"
  localparam logic [31:0] W_DEV = 32'h0000_FFFF, W_PROD = 32'h00FF_00FF, W_TEST = 32'h0000_00FF, W_RMA = 32'hFFFF_FFFF;
  localparam logic [2:0] S_RAW = 0, S_TEST = 1, S_DEV = 2, S_PROD = 3, S_RMA = 4, S_SCRAP = 5, S_INVALID = 6, S_ESC = 7;

  // ---------------- OTP model ----------------
  logic [31:0] otp [0:63];
  logic [31:0] stuck;                   // bits that cannot be programmed in word stuck_a
  logic [5:0]  stuck_a;
  int          lat;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin otp_ack <= 1'b0; lat <= 0; otp_rdata <= '0; end
    else begin
      otp_ack <= 1'b0;
      otp_rdata <= $urandom;
      if (otp_req && !otp_ack) begin
        if (lat == 0) begin
          otp_ack <= 1'b1;
          if (otp_we) otp[otp_addr] <= otp[otp_addr] | (otp_wdata & ~(otp_addr == stuck_a ? stuck : 32'h0));
          else otp_rdata <= otp[otp_addr];
          lat <= $urandom_range(0, 3);
        end else lat <= lat - 1;
      end
    end
  end

  // ---------------- helpers ----------------
  int errors = 0, nalert = 0;
  logic [2:0] last_alert;
  always @(posedge clk) if (alert) begin nalert++; last_alert = alert_code; end
  task automatic fail(input string m);
    $display("FAIL @%0t: %s", $time, m); errors++;
  endtask
  task automatic otp_clear();
    for (int i = 0; i < 64; i++) otp[i] = '0;
    stuck = '0; stuck_a = '0;
  endtask
  task automatic otp_set256(input int base, input logic [255:0] v);
    for (int i = 0; i < 8; i++) otp[base + i] = v[32 * (7 - i) +: 32];
  endtask
  task automatic otp_tokens();
    otp_set256(16, TOKH_TEST); otp_set256(24, TOKH_RMA);
  endtask
  // reset; hold rst_n low for a few clocks and wait for the lifecycle
  task automatic do_reset();
    repeat (2) @(negedge clk);                             // let the checker see the last clock's events
    rst_n = 1'b0; cmd_start = 1'b0; img_valid = 1'b0; img_last = 1'b0; esc = 1'b0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;
    nalert = 0;
    for (int t = 0; t < 200 && !init_done; t++) @(posedge clk);
    #1;
    if (!init_done) fail("init_done");
  endtask
  logic [2:0] cmd_al;                   // the alert raised with the last cmd_done (0: none)
  task automatic cmd(input logic [1:0] op, input logic [5:0] a, input logic [31:0] d, input logic [127:0] tk,
                     output logic e, output logic [31:0] rd);
    int t;
    @(negedge clk);
    cmd_op = op; cmd_addr = a; cmd_data = d; token = tk; cmd_start = 1'b1;
    @(negedge clk);
    cmd_start = 1'b0;
    t = 0;
    while (!cmd_done && t < 2000) begin @(posedge clk); #1; t++; end
    if (!cmd_done) fail("cmd timeout");
    e = cmd_err; rd = cmd_rdata; cmd_al = alert ? alert_code : 3'd0;
    @(negedge clk);
    if (cmd_busy) fail("busy after done");
  endtask
  task automatic cmd_ok(input logic [1:0] op, input logic [5:0] a, input logic [31:0] d, input logic [127:0] tk);
    logic e;
    logic [31:0] rd;
    cmd(op, a, d, tk, e, rd);
    if (e) fail($sformatf("command %0d at %0d refused", op, a));
  endtask
  task automatic cmd_bad(input logic [1:0] op, input logic [5:0] a, input logic [31:0] d, input logic [127:0] tk,
                         input logic [2:0] acode);
    logic e;
    logic [31:0] rd;
    cmd(op, a, d, tk, e, rd);
    if (!e) fail($sformatf("command %0d at %0d accepted", op, a));
    if (cmd_al != acode) fail($sformatf("command %0d at %0d: alert %0d, expected %0d", op, a, cmd_al, acode));
  endtask
  function automatic logic [31:0] xs32(input logic [31:0] x);
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return x;
  endfunction
  // stream an image; gaps: percentage of clocks without a word
  task automatic send_image(input logic [31:0] ver, input int n, input logic [31:0] seed, input int gaps);
    logic [31:0] x;
    x = seed;
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      while ($urandom_range(0, 99) < gaps) begin img_valid = 1'b0; @(negedge clk); end
      if (i > 0) x = xs32(x);
      img_valid = 1'b1; img_data = i == 0 ? ver : x; img_last = i == n - 1;
      @(posedge clk);
      while (!img_ready) @(posedge clk);
    end
    @(negedge clk);
    img_valid = 1'b0; img_last = 1'b0;
  endtask
  task automatic wait_boot();
    for (int t = 0; t < 400000 && !boot_done; t++) @(posedge clk);
    #1;
    if (!boot_done) fail("boot timeout");
  endtask
  function automatic logic dbg_exp(input logic [2:0] s);
    return s == S_TEST || s == S_DEV || s == S_RMA;
  endfunction

  int ncase = 0;
  task automatic boot_case(input logic [31:0] lcw, input logic [31:0] arb, input logic [255:0] uds,
                           input logic [255:0] dig, input logic [31:0] ver, input int n, input logic [31:0] seed,
                           input logic ok, input logic [255:0] key);
    logic [2:0] s;
    otp_clear(); otp_tokens();
    otp[32] = lcw; otp[34] = arb; otp_set256(0, uds); otp_set256(8, dig);
    do_reset();
    s = lcw == W_DEV ? S_DEV : S_PROD;
    if (lc_state != s) fail($sformatf("case %0d: lifecycle %0d", ncase, lc_state));
    if (dbg_en != dbg_exp(s)) fail("dbg_en");
    if (boot_done || cpu_en) fail("booted before the image");
    send_image(ver, n, seed, ncase % 3 == 0 ? 0 : 30);
    wait_boot();
    if (boot_ok != ok || cpu_en != ok || key_valid != ok) fail($sformatf("case %0d: boot_ok %0d", ncase, boot_ok));
    if (ok && key_out != key) fail($sformatf("case %0d: key %h", ncase, key_out));
    if (!ok && (nalert != 1 || last_alert != 3'd2)) fail($sformatf("case %0d: alert", ncase));
    if (ok && nalert != 0) fail($sformatf("case %0d: unexpected alert", ncase));
    if (u_dut.blk != '0) fail("block register not cleared");
    // a second image is not taken
    @(negedge clk); img_valid = 1'b1; img_data = '0; img_last = 1'b1;
    repeat (3) @(posedge clk);
    #1;
    if (img_ready) fail("second image");
    img_valid = 1'b0;
    ncase++;
  endtask

  // a state without verified boot: boots at once or never
  task automatic state_case(input logic [31:0] lcw, input logic [31:0] scr, input logic [2:0] s, input logic boots);
    otp_clear(); otp_tokens();
    otp[32] = lcw; otp[33] = scr;
    do_reset();
    if (lc_state != s) fail($sformatf("lifecycle %0d, expected %0d", lc_state, s));
    if (!boot_done || boot_ok != boots || cpu_en != boots || key_valid) fail("boot state");
    if (dbg_en != dbg_exp(s)) fail("dbg_en");
    if (s == S_INVALID ? (nalert != 1 || last_alert != 3'd1) : nalert != 0) fail("init alert");
    @(negedge clk); img_valid = 1'b1; img_data = '0; img_last = 1'b1;
    repeat (3) @(posedge clk);
    #1;
    if (img_ready) fail("image taken");
    img_valid = 1'b0;
  endtask

  // a lifecycle transition, then the reset that makes it take effect
  task automatic transition(input logic [2:0] to, input logic [127:0] tk, input logic [31:0] lcw_exp,
                            input logic [5:0] wa);
    cmd_ok(2'd2, '0, 32'(to), tk);
    if (otp[wa] != lcw_exp) fail($sformatf("lifecycle word %h", otp[wa]));
    cmd_bad(2'd1, 6'd40, 32'h1, '0, 3'd0);                 // nothing more until reset
    cmd_bad(2'd2, '0, 32'(S_SCRAP), '0, 3'd0);
    cmd_ok(2'd0, 6'd32, '0, '0);                           // reads still work
    do_reset();
    if (lc_state != to) fail($sformatf("after the transition: %0d", lc_state));
  endtask

  logic        e;
  logic [31:0] rd;
  initial begin
    cmd_start = 1'b0; img_valid = 1'b0; img_last = 1'b0; img_data = '0; esc = 1'b0;
    cmd_op = '0; cmd_addr = '0; cmd_data = '0; token = '0;
    otp_clear();
    // ---- secure boot vectors
    boot_cases();
    $display("boot cases: %0d", ncase);

    // ---- lifecycle states without verified boot
    state_case(32'h0, 32'h0, S_RAW, 1'b0);
    state_case(W_TEST, 32'h0, S_TEST, 1'b1);
    state_case(W_RMA, 32'h0, S_RMA, 1'b1);
    state_case(W_PROD, 32'hFFFF_FFFF, S_SCRAP, 1'b0);
    state_case(32'h0000_00F0, 32'h0, S_INVALID, 1'b0);     // a group partly set
    state_case(32'h00FF_0000, 32'h0, S_INVALID, 1'b0);     // a group out of order
    state_case(32'h0000_FFFF, 32'h0000_0100, S_INVALID, 1'b0);   // scrap partly set
    state_case(32'hFF00_FFFF, 32'h0, S_INVALID, 1'b0);

    // ---- command port in TEST: provisioning
    otp_clear(); otp[32] = W_TEST;
    do_reset();
    cmd_bad(2'd0, 6'd3, '0, '0, 3'd4);                     // the UDS is never read
    for (int i = 0; i < 8; i++) cmd_ok(2'd1, 6'(i), 32'h1111_0000 + 32'(i), '0);
    for (int i = 0; i < 8; i++) cmd_ok(2'd1, 6'(16 + i), TOKH_TEST[32 * (7 - i) +: 32], '0);
    for (int i = 0; i < 8; i++) cmd_ok(2'd1, 6'(24 + i), TOKH_RMA[32 * (7 - i) +: 32], '0);
    cmd_ok(2'd1, 6'd8, 32'hABCD_0001, '0);
    cmd_ok(2'd1, 6'd50, 32'h5A5A_0000, '0);
    cmd_ok(2'd1, 6'd50, 32'h0000_A5A5, '0);                 // bits add up
    cmd(2'd0, 6'd50, '0, '0, e, rd);
    if (e || rd != 32'h5A5A_A5A5) fail($sformatf("spare word %h", rd));
    cmd(2'd0, 6'd16, '0, '0, e, rd);
    if (e || rd != TOKH_TEST[255:224]) fail("token hash read");
    cmd_bad(2'd1, 6'd32, 32'hFFFF, '0, 3'd4);               // lifecycle only by transition
    cmd_bad(2'd1, 6'd33, 32'h1, '0, 3'd4);
    cmd_bad(2'd1, 6'd34, 32'h1, '0, 3'd4);                  // anti-rollback: DEV / PROD
    cmd_bad(2'd3, 6'd0, 32'h0, '0, 3'd0);                   // reserved command
    cmd_bad(2'd2, '0, 32'(S_RMA), TOK_RMA, 3'd0);           // TEST -> RMA is not a transition
    cmd_bad(2'd2, '0, 32'(S_TEST), TOK_TEST, 3'd0);
    cmd_bad(2'd2, '0, 32'd0, '0, 3'd0);
    cmd_bad(2'd2, '0, 32'(S_INVALID), '0, 3'd0);
    // a program that does not read back
    stuck_a = 6'd40; stuck = 32'h0000_0010;
    cmd_bad(2'd1, 6'd40, 32'h0000_0011, '0, 3'd5);
    cmd(2'd0, 6'd40, '0, '0, e, rd);
    if (e || rd != 32'h1) fail("stuck word");
    stuck = '0;
    // a start while busy is ignored
    @(negedge clk); cmd_op = 2'd0; cmd_addr = 6'd50; cmd_start = 1'b1;
    @(negedge clk); cmd_start = 1'b1; cmd_addr = 6'd3;
    @(negedge clk); cmd_start = 1'b0;
    while (!cmd_done) @(posedge clk);
    #1 if (cmd_err || cmd_rdata != 32'h5A5A_A5A5) fail("start while busy");
    // wrong tokens: three lock the port
    cmd_bad(2'd2, '0, 32'(S_PROD), TOK_RMA, 3'd3);
    cmd_bad(2'd2, '0, 32'(S_DEV), '0, 3'd3);
    cmd_bad(2'd2, '0, 32'(S_DEV), TOK_TEST ^ 128'h1, 3'd3);
    cmd_bad(2'd2, '0, 32'(S_DEV), TOK_TEST, 3'd0);          // locked, even with the right one
    cmd_bad(2'd0, 6'd50, '0, '0, 3'd0);
    do_reset();
    transition(S_DEV, TOK_TEST, W_DEV, 6'd32);
    // DEV: the digest and anti-rollback may be programmed, not the secrets
    cmd_bad(2'd1, 6'd0, 32'h1, '0, 3'd4);
    cmd_bad(2'd1, 6'd20, 32'h1, '0, 3'd4);
    cmd_ok(2'd1, 6'd9, 32'h1, '0);
    cmd_ok(2'd1, 6'd34, 32'h1, '0);
    cmd_ok(2'd1, 6'd63, 32'h8000_0000, '0);
    cmd_bad(2'd2, '0, 32'(S_RMA), TOK_TEST, 3'd3);
    transition(S_RMA, TOK_RMA, W_RMA, 6'd32);
    cmd_bad(2'd1, 6'd9, 32'h1, '0, 3'd4);                   // RMA: everything closed
    cmd_bad(2'd1, 6'd40, 32'h1, '0, 3'd4);
    cmd_bad(2'd1, 6'd34, 32'h1, '0, 3'd4);
    transition(S_SCRAP, '0, 32'hFFFF_FFFF, 6'd33);
    cmd_bad(2'd2, '0, 32'(S_SCRAP), '0, 3'd0);              // already scrapped
    cmd_bad(2'd1, 6'd50, 32'h1, '0, 3'd4);
    cmd_ok(2'd0, 6'd33, '0, '0);

    // ---- RAW -> TEST with the netlist token, TEST -> PROD, PROD -> RMA
    otp_clear(); otp_tokens();
    do_reset();
    cmd_bad(2'd1, 6'd40, 32'h1, '0, 3'd4);                  // RAW: nothing open
    cmd_bad(2'd2, '0, 32'(S_TEST), TOK_TEST, 3'd3);
    transition(S_TEST, TOK_RAW, W_TEST, 6'd32);
    transition(S_PROD, TOK_TEST, W_PROD, 6'd32);
    cmd_bad(2'd1, 6'd9, 32'h1, '0, 3'd4);                   // PROD: the digest is fixed
    cmd_ok(2'd1, 6'd34, 32'h3, '0);
    cmd_ok(2'd1, 6'd45, 32'h3, '0);
    transition(S_RMA, TOK_RMA, W_RMA, 6'd32);
    // a lifecycle program that does not read back
    otp_clear(); otp_tokens(); otp[32] = W_TEST;
    do_reset();
    stuck_a = 6'd32; stuck = 32'h0000_0100;
    cmd_bad(2'd2, '0, 32'(S_DEV), TOK_TEST, 3'd5);
    stuck = '0;
    do_reset();
    if (lc_state != S_INVALID) fail("half-programmed lifecycle word");
    // scrap from RAW and from PROD
    otp_clear();
    do_reset();
    transition(S_SCRAP, '0, 32'hFFFF_FFFF, 6'd33);
    otp_clear(); otp[32] = W_PROD;
    do_reset();
    transition(S_SCRAP, '0, 32'hFFFF_FFFF, 6'd33);

    // ---- escalation: in every phase
    otp_clear(); otp_tokens(); otp[32] = W_DEV;
    do_reset();
    @(negedge clk) esc = 1'b1;
    @(negedge clk) esc = 1'b0;
    #1 if (lc_state != S_ESC || dbg_en || cpu_en || alert_code != 3'd6) fail("escalation in idle");
    @(negedge clk); cmd_op = 2'd0; cmd_addr = 6'd40; cmd_start = 1'b1;
    @(negedge clk); cmd_start = 1'b0;
    repeat (20) @(posedge clk);
    #1 if (cmd_done || otp_req) fail("commands after escalation");
    for (int ph = 0; ph < 6; ph++) begin
      otp_clear(); otp_tokens(); otp[32] = W_TEST;
      do_reset();
      if (ph < 3) begin                                     // during a command: read, program, token hash
        @(negedge clk);
        cmd_op = ph == 0 ? 2'd0 : ph == 1 ? 2'd1 : 2'd2; cmd_addr = 6'd50; cmd_data = ph == 2 ? 32'(S_DEV) : 32'h7;
        token = TOK_TEST; cmd_start = 1'b1;
        @(negedge clk); cmd_start = 1'b0;
        repeat (ph == 2 ? 30 : 1) @(posedge clk);
      end
      if (ph >= 3) begin                                    // during boot: the image, the digest check, the key
        otp[32] = W_PROD; otp_set256(8, IMG_E_DIG);
        do_reset();
        if (ph == 3) begin                                  // the image: the stream stops at the escalation
          fork
            send_image(32'd0, 40, 32'h1234_5679, 0);
            begin repeat (25) @(posedge clk); #1 esc = 1'b1; end
          join_any
          disable fork;
        end else begin
          send_image(32'd0, 40, 32'h1234_5679, 0);
          if (ph == 4) wait (u_dut.otp_req && u_dut.otp_addr == 6'd8);    // reading the digest
          else begin wait (u_dut.inner != '0); repeat (60) @(posedge clk); end  // deriving the key
          #1 esc = 1'b1;
        end
      end
      @(negedge clk) esc = 1'b1;
      @(negedge clk) esc = 1'b0;
      img_valid = 1'b0;
      repeat (5) @(posedge clk);
      #1 if (lc_state != S_ESC || cpu_en || key_valid || key_out != '0 || otp_req || dbg_en || u_dut.blk != '0)
        fail($sformatf("escalation in phase %0d", ph));
    end
    // a verified boot, then escalation: the key goes
    otp_clear(); otp[32] = W_PROD; otp_set256(8, IMG_E_DIG);
    do_reset();
    send_image(32'd0, 40, 32'h1234_5679, 20);
    wait_boot();
    if (!boot_ok || !key_valid) fail("image E");
    @(negedge clk) esc = 1'b1;
    @(negedge clk) esc = 1'b0;
    #1 if (key_valid || key_out != '0 || cpu_en) fail("escalation after boot");

    // ---- resets in the middle of a boot and of a command
    otp_clear(); otp[32] = W_DEV;
    do_reset();
    fork
      send_image(32'd0, 60, 32'h0BAD_F00D, 10);
      begin repeat (150) @(posedge clk); #1 rst_n = 1'b0; end
    join_any
    disable fork;
    img_valid = 1'b0;
    do_reset();
    if (boot_done || cpu_en || key_valid) fail("state after a reset during boot");
    otp[32] = W_TEST;
    do_reset();
    @(negedge clk); cmd_op = 2'd1; cmd_addr = 6'd50; cmd_data = 32'h3; cmd_start = 1'b1;
    @(negedge clk); cmd_start = 1'b0;
    @(posedge clk); #1 rst_n = 1'b0;
    do_reset();
    cmd_ok(2'd0, 6'd50, '0, '0);
    // an image of 2^14 words is too long: refused even with the digest a wrapped word count
    // (length field 0) gives in the OTP
    otp_clear(); otp[32] = W_DEV; otp_set256(8, IMG_WRAP_DIG);
    do_reset();
    send_image(32'd0, 1 << 14, 32'h1, 0);
    wait_boot();
    if (boot_ok || alert_code != 3'd2) fail("oversized image");
    do_reset();
    if (boot_done || u_dut.nw_ovf) fail("after reset");

    if (errors == 0) $display("TEST PASSED: Root_of_Trust");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin
    #500ms;
    $display("TEST FAILED: watchdog");
    $finish;
  end
endmodule
