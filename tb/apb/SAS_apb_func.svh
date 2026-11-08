// SPDX-License-Identifier: Apache-2.0
// IP part of SAS_apb_tb: the serial line is looped back so the built-in
// initiator verifies its own traffic; bit flips and injected frames with
// errors raise ERR.
  localparam logic [31:0] ALIGN = 32'h7B4A4ABC, SOF = 32'hA5A50001, EOF = 32'hA5A50002;
  logic corrupt = 0, inj_en = 0, inj_bit = 0;
  assign rx_p = inj_en ? inj_bit : (tx_p ^ corrupt);
  assign rx_n = ~rx_p;
  initial refclk = 0;
  always #3 refclk = ~refclk;

  function automatic logic [31:0] crc32_dw(input logic [31:0] crc, input logic [31:0] dw);
    logic [31:0] c;
    c = crc;
    for (int b = 3; b >= 0; b--)
      for (int i = 0; i < 8; i++)
        c = (c[0] ^ dw[b * 8 + i]) ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
    return c;
  endfunction

  // a frame error pulse must come right after the dword that carries the
  // error: the CRC dword for a bad CRC, else the EOF dword (the interrupted
  // sequencer may also time out, at another time)
  time errs[$];
  time t_chk = 0;
  always @(posedge PCLK) if (dut.c_irq) errs.push_back($time);

  task automatic drive_dw(input logic [31:0] d);
    for (int i = 31; i >= 0; i--) begin @(negedge PCLK); inj_bit = d[i]; end
  endtask

  // one frame on the line; mode 1 bad CRC, 2 bad EOF
  task automatic inject(input logic [7:0] len, type_, dst, src, input int npay,
                        input logic [31:0] p0, input int mode);
    logic [31:0] h, c, p;
    @(negedge PCLK); inj_en = 1;
    for (int i = 0; i < 20; i++) drive_dw(ALIGN);
    h = {len, type_, dst, src};
    c = crc32_dw(32'hFFFF_FFFF, h);
    drive_dw(SOF); drive_dw(h);
    for (int i = 0; i < npay; i++) begin
      p = (i == 0) ? p0 : $urandom;
      c = crc32_dw(c, p); drive_dw(p);
    end
    drive_dw(mode == 1 ? c : ~c);
    if (mode == 1) t_chk = $time;
    drive_dw(mode == 2 ? SOF : EOF);
    if (mode != 1) t_chk = $time;
    drive_dw(ALIGN); drive_dw(ALIGN);
    @(negedge PCLK); inj_en = 0;
  endtask

  task automatic err_is(input bit v, input string m);
    cycles(3);
    if (v && t_chk != 0) begin
      bit hit;
      hit = 0;
      foreach (errs[i]) if (errs[i] >= t_chk && errs[i] <= t_chk + 50) hit = 1;
      if (!hit) fail({"ERR right after the bad dword: ", m});
    end
    t_chk = 0;
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_ERR] !== v) fail({"ERR: ", m});
    wr(A_IRQ_STATUS, IRQ_ALL);
  endtask

  task automatic wait_ok(input int n, input string m);
    int t;
    logic [7:0] o;
    o = dut.u_core.ok_cnt; t = 0;
    while (8'(dut.u_core.ok_cnt - o) < n && t < 3000 * n) begin @(posedge PCLK); t++; end
    if (8'(dut.u_core.ok_cnt - o) < n) fail({m, ": verified transactions"});
  endtask

  task automatic ip_func;
    logic [31:0] v;
    rd_exp(A_FLAGS, 0);
    while (!dut.u_core.phy_ready) @(posedge PCLK);     // OOB over the loopback
    err_is(0, "OOB");
    wait_ok(20, "clean");
    if (dut.u_core.mm_cnt != 0) fail("clean: mismatches");
    err_is(0, "clean traffic");
    // a bit flip: ERR (masked)
    while (dut.u_core.tx_state != 1) @(posedge PCLK);
    repeat (50) @(negedge PCLK);
    corrupt = 1; @(negedge PCLK); corrupt = 0;
    wait_ok(2, "after a bit flip");
    if (irq) fail("masked ERR drives the pin");
    err_is(1, "bit flip");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    // injected frames
    v = $urandom;
    inject(8'd1, 8'h01, 8'd9, 8'h77, 1, v, 0);
    cycles(5);
    if (dut.u_core.regs[9] !== v) fail("injected write");
    wr(A_IRQ_STATUS, IRQ_ALL);                          // the interrupted transaction may time out
    inject(8'd2, 8'h01, 8'd3, 8'h22, 2, $urandom, 1);
    cycles(2);
    if (!irq) fail("ERR drives the pin");
    err_is(1, "bad CRC");
    if (irq) fail("irq after clear");
    inject(8'd1, 8'h01, 8'd3, 8'h22, 1, $urandom, 2);  err_is(1, "bad EOF");
    inject(8'd1, 8'h7C, 8'd3, 8'h22, 1, $urandom, 0);  err_is(1, "unknown type");
    inject(8'd1, 8'h01, 8'd16, 8'h22, 1, $urandom, 0); err_is(1, "write register 16");
    wait_ok(3, "after injections");
    wr(A_IRQ_STATUS, IRQ_ALL);
    wait_ok(10, "clean again");
    err_is(0, "clean again");
    // a frame error left pending into reset
    inject(8'd0, 8'h01, 8'd3, 8'h22, 0, 0, 0);
    cycles(3);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_ERR]) fail("ERR pending");
  endtask
