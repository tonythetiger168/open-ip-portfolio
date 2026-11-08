// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for xSPI_top (JESD251 8D-8D-8D NOR target).
// The TB is the xSPI host: it drives CS#, CK and DQ one byte per CK edge,
// releases DQ after the header of a read, and captures read data on each
// DQS transition. A frame-level model of the device (array, page buffer,
// WEL / WIP, dummy setting, RESET ENABLE, error codes) predicts every read
// byte, irq pulse and error code. Every clock: no DQ contention, DQ only
// moves with DQS, DQS starts low, drivers off with CS# high, and each
// program / erase keeps WIP high for exactly one clock per array byte.
`timescale 1ns/1ps
module xSPI_tb;
  localparam int MEM_AW = 9, PAGE_AW = 5, SECT_AW = 7;
  localparam int MEM = 1 << MEM_AW, PAGE = 1 << PAGE_AW, SECT = 1 << SECT_AW;
  logic clk = 0, rst_n = 0;
  logic ck = 0, csn = 1;
  logic [7:0] h_dq = 0;
  logic       h_oe = 0;
  wire  [7:0] dq_o;
  wire  [1:0] sr;
  wire        dq_oe, dqs_o, dqs_oe, irq_cmd, irq_done, irq_err;
  wire  [4:0] dummy;
  wire  [2:0] err_code;
  wire  [7:0] dq_i = dq_oe ? dq_o : h_oe ? h_dq : 8'hFF;   // pulled up when idle
  int errors = 0;

  xSPI_top #(.MEM_AW(MEM_AW), .PAGE_AW(PAGE_AW), .SECT_AW(SECT_AW)) dut (.*);
  always #5 clk = ~clk;

  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask
  task automatic clocks(input int n); repeat (n) @(posedge clk); endtask

  // ------------------------------ model ------------------------------
  logic [7:0] m_mem [0:MEM-1];
  initial for (int i = 0; i < MEM; i++) m_mem[i] = 0;
  bit         m_wel = 0, m_wip = 0, m_rsten = 0;
  logic [4:0] m_dummy = 5'd8;
  logic [2:0] m_err = 0;
  int         exp_blen = 0, n_cmd_exp = 0, n_err_exp = 0, n_done_exp = 0;
  int         n_by_err [0:7], n_by_cmd [0:255];
  initial begin for (int i = 0; i < 8; i++) n_by_err[i] = 0; for (int i = 0; i < 256; i++) n_by_cmd[i] = 0; end

  function automatic int dec(input logic [7:0] c);   // -1 unknown, else {addr, read, wel}
    case (c)
      8'h06, 8'h04, 8'h66, 8'h99: return 0;
      8'h05, 8'h9F, 8'hEE, 8'h85: return 6;
      8'h12, 8'h21, 8'h81: return 5;
      8'h60: return 1;
      default: return -1;
    endcase
  endfunction
  function automatic logic [7:0] id_byte(input int i);
    case (i % 4) 0: return 8'h4F; 1: return 8'h58; 2: return 8'(MEM_AW); default: return 8'h00; endcase
  endfunction

  // ------------------------------ host BFM ------------------------------
  int Q = 2;                              // clocks per CK half period, after the DQ setup clock
  logic [7:0] tx [0:1023];                // bytes the host drives, one per edge
  logic [7:0] rx [0:1023];                // bytes captured on DQS transitions
  int         nrx = 0;
  bit         capt = 0;
  int         n_icmd = 0, n_ierr = 0, n_idone = 0;

  task automatic edge_c(input bit drive, input logic [7:0] b);
    h_oe = drive; if (drive) h_dq = b;
    @(posedge clk); #1;
    ck = !ck;
    repeat (Q) @(posedge clk); #1;
  endtask
  // one frame: nd driven edges from tx[], then nr edges with DQ released
  task automatic frame(input int nd, input int nr);
    nrx = 0; capt = 1;
    csn = 0; clocks(2); #1;
    for (int i = 0; i < nd; i++) edge_c(1, tx[i]);
    for (int i = 0; i < nr; i++) edge_c(0, 0);
    h_oe = 0;
    clocks(2); #1;
    csn = 1;
    clocks(3); #1;
    capt = 0;
  endtask
  task automatic hdr(input logic [7:0] c, input logic [31:0] a = 0);
    tx[0] = c; tx[1] = ~c;
    tx[2] = a[31:24]; tx[3] = a[23:16]; tx[4] = a[15:8]; tx[5] = a[7:0];
  endtask

  // run a frame and check it against the model: nd + nr edges in all, the
  // byte the device sees at edge k is tx[k] while driven, else 0xFF
  task automatic run(input int nd, input int nr);
    int n, f, e, ex, rd, nb, d0;
    logic [7:0] c, x, b;
    logic [MEM_AW-1:0] a, col;
    logic [7:0] pbuf [0:PAGE-1];
    bit pval [0:PAGE-1];
    bit busy_rdsr, hok;
    logic [7:0] v6;
    int c0, e0, i0;
    n = nd + nr;
    c0 = n_icmd; e0 = n_ierr; i0 = n_idone;
    frame(nd, nr);
    // what the device saw
    e = 0; ex = 0; rd = 0; busy_rdsr = 0;
    c = nd > 0 ? tx[0] : 8'hFF; x = n > 1 ? (nd > 1 ? tx[1] : 8'hFF) : 0;
    f = dec(c);
    if (n == 0) ;
    else if (n == 1) e = 5;
    else if (x != ~c) e = 1;
    else if (f < 0) e = 2;
    else if (m_wip && c != 8'h05) e = 3;
    else if (f[0] && !m_wel) e = 4;
    else if (c == 8'h99 && !m_rsten) e = 7;
    else if (!f[2] && n > 2) e = 5;                       // a command without address ran on
    else if (f[2] && n < 6) e = 5;                        // cut in the address
    else if (c == 8'h21 && n > 6) e = 5;
    hok = e == 0 && n >= 2;                               // the header was accepted
    if (e != 0) ;
    else if (n % 2) e = 5;                                // ends with CK high
    else if ((c == 8'h12 || c == 8'h81) && n == 6) e = 5;
    if (n >= 6) begin
      a = MEM_AW'({(nd > 4 ? tx[4] : 8'hFF), (nd > 5 ? tx[5] : 8'hFF)});
      a[0] = 0;
    end
    v6 = nd > 6 ? tx[6] : 8'hFF;
    if (e == 0 && c == 8'h81 && v6[4:0] < 4) e = 6;
    // read data: sent once the header was accepted, even if the frame then ends badly
    if (hok && f[1]) begin
      nb = n - 6 - 2 * m_dummy;
      if (nb < 0) nb = 0;
      if (nrx != nb) fail($sformatf("read %h: %0d bytes on DQS, expected %0d", c, nrx, nb));
      if (c == 8'h05 && m_wip) busy_rdsr = 1;
      for (int k = 0; k < nb && k < nrx; k++) begin
        case (c)
          8'h05: b = {6'b0, m_wel, m_wip};
          8'h85: b = {3'b000, m_dummy};
          8'h9F: b = id_byte(k);
          default: b = m_mem[MEM_AW'(a + k)];
        endcase
        if (busy_rdsr) begin
          // busy: 03 until the program / erase ends, then 00
          if (!(rx[k] == 8'h03 || rx[k] == 8'h00) || (k > 0 && rx[k - 1] == 8'h00 && rx[k] != 8'h00))
            fail($sformatf("RDSR byte %0d = %h while busy", k, rx[k]));
        end else if (rx[k] !== b)
          fail($sformatf("read %h a=%h byte %0d = %h, expected %h", c, a, k, rx[k], b));
      end
    end else if (nrx != 0) fail($sformatf("frame %h: %0d DQS edges, expected none", c, nrx));
    // effects
    if (n >= 2 && e == 0) begin
      n_cmd_exp++;
      m_rsten = c == 8'h66;
      case (c)
        8'h06: m_wel = 1;
        8'h04: m_wel = 0;
        8'h81: begin m_dummy = v6[4:0]; m_wel = 0; end
        8'h99: begin m_dummy = 8; m_wel = 0; end
        8'h12: begin
          for (int k = 0; k < PAGE; k++) pval[k] = 0;
          col = a;
          for (int k = 6; k < n; k++) begin
            pbuf[col[PAGE_AW-1:0]] = k < nd ? tx[k] : 8'hFF; pval[col[PAGE_AW-1:0]] = 1;
            col[PAGE_AW-1:0] = col[PAGE_AW-1:0] + 1;
          end
          for (int k = 0; k < PAGE; k++) if (pval[k]) begin
            col = a; col[PAGE_AW-1:0] = k;
            m_mem[col] = m_mem[col] & pbuf[k];
          end
          m_wip = 1; exp_blen = PAGE; n_done_exp++;
        end
        8'h21: begin
          for (int k = 0; k < SECT; k++) m_mem[{a[MEM_AW-1:SECT_AW], SECT_AW'(k)}] = 8'hFF;
          m_wip = 1; exp_blen = SECT; n_done_exp++;
        end
        8'h60: begin
          for (int k = 0; k < MEM; k++) m_mem[k] = 8'hFF;
          m_wip = 1; exp_blen = MEM; n_done_exp++;
        end
        default: ;
      endcase
    end
    if (e != 0) begin m_err = e; n_err_exp++; n_by_err[e]++; end
    if (n >= 2 && e == 0) n_by_cmd[c]++;
    // a program / erase that ended during (or just after) an RDSR
    if (busy_rdsr && sr === 2'b00) begin m_wip = 0; m_wel = 0; end
    // the frame's own pulses and the device state after it
    if (n_icmd - c0 != (n >= 2 && e == 0)) fail($sformatf("frame %h: %0d irq_cmd", c, n_icmd - c0));
    if (n_ierr - e0 != (e != 0)) fail($sformatf("frame %h: %0d irq_err, expected error %0d", c, n_ierr - e0, e));
    if (err_code !== m_err) fail($sformatf("frame %h: err_code %0d, expected %0d", c, err_code, m_err));
    if (dummy !== m_dummy || sr[1] !== m_wel || (!m_wip && sr[0] !== 1'b0))
      fail($sformatf("frame %h: sr %h dummy %0d, expected WEL %b WIP %b dummy %0d", c, sr, dummy, m_wel, m_wip, m_dummy));
  endtask

  // ------------------------------ commands ------------------------------
  task automatic cmd(input logic [7:0] c); hdr(c); run(2, 0); endtask
  task automatic rd(input logic [7:0] c, input logic [31:0] a, input int n);
    hdr(c, a); run(6, 2 * m_dummy + n);
  endtask
  task automatic wait_ready();
    int k;
    k = 0;
    while (m_wip && k < 200) begin rd(8'h05, 0, 2); k++; end
    if (m_wip) fail("WIP never cleared");
  endtask
  task automatic pp(input logic [31:0] a, input int n, input bit rnd = 1, input logic [7:0] v = 0);
    cmd(8'h06);
    hdr(8'h12, a);
    for (int k = 0; k < n; k++) tx[6 + k] = rnd ? 8'($urandom) : v;
    run(6 + n, 0);
    wait_ready();
  endtask
  task automatic se(input logic [31:0] a); cmd(8'h06); hdr(8'h21, a); run(6, 0); wait_ready(); endtask
  task automatic ce(); cmd(8'h06); cmd(8'h60); wait_ready(); endtask
  task automatic wrcr(input logic [7:0] v);
    cmd(8'h06); hdr(8'h81); tx[6] = v; tx[7] = 8'($urandom); run(8, 0);
  endtask
  task automatic foreach_dummy();
    for (int k = 0; k < 6; k++) begin
      wrcr(k == 0 ? 8'h04 : k == 1 ? 8'hE6 : k == 2 ? 8'h0D : k == 3 ? 8'h14 : k == 4 ? 8'h1E : 8'h08);
      rd(8'hEE, $urandom, 6);
    end
  endtask
  task automatic check_array();
    int bad;
    bad = -1;
    for (int i = MEM - 1; i >= 0; i--) if (dut.mem[i] !== m_mem[i]) bad = i;
    if (bad >= 0) fail($sformatf("array[%0d] = %h, expected %h", bad, dut.mem[bad], m_mem[bad]));
  endtask

  // ------------------------------ monitors ------------------------------
  logic dqs_q = 0, oe_q = 0, wip_q = 0, csn_q = 1;
  logic [7:0] dq_q = 0;
  int cyc = 0, t_wip = 0, n_busy = 0;
  always @(posedge clk) begin
    cyc++;
    if (rst_n) begin
      if (dq_oe && h_oe) fail("DQ driven by host and device");
      if (dqs_oe && !oe_q && dqs_o) fail("DQS preamble not low");
      if (dq_oe && dq_o !== dq_q && dqs_o === dqs_q && oe_q) fail("DQ changed without a DQS edge");
      if (dqs_oe && dqs_o !== dqs_q && oe_q) begin
        if (!dq_oe) fail("DQS toggled with DQ not driven");
        if (capt) begin rx[nrx] = dq_o; nrx++; end
      end
      if (csn && csn_q && (dq_oe || dqs_oe)) fail("drivers on with CS# high");
      if (sr[0] && !wip_q) t_wip = cyc;
      if (!sr[0] && wip_q) begin
        n_busy++;
        if (cyc - t_wip != exp_blen) fail($sformatf("WIP high %0d clocks, expected %0d", cyc - t_wip, exp_blen));
      end
      n_icmd += irq_cmd; n_ierr += irq_err; n_idone += irq_done;
    end
    csn_q = csn; dqs_q = dqs_o; oe_q = dqs_oe; dq_q = dq_o; wip_q = sr[0];
  end

  // ------------------------------ test ------------------------------
  initial begin
    logic [31:0] a;
    clocks(3); rst_n = 1; clocks(3);
    // ---- reset values ----
    cmd(8'h99);                                   // RESET ENABLE is clear after reset
    rd(8'h05, 0, 4); rd(8'h85, 0, 2); rd(8'h9F, 0, 8);
    // ---- erase, then every array bit through 0 and back to 1 ----
    cmd(8'h60);                                   // no WEL
    ce();
    rd(8'hEE, 0, MEM);
    for (int p = 0; p < MEM / PAGE; p++) pp(p * PAGE, PAGE, 0, 8'h00);
    rd(8'hEE, 0, MEM);
    check_array();
    ce();
    // ---- program: NOR AND, page wrap, partial pages, odd addresses ----
    pp(32'h10, 8, 0, 8'hF0); pp(32'h10, 8, 0, 8'h3C); rd(8'hEE, 32'h10, 8);
    pp(32'h3C, 12);                               // wraps inside page 1
    rd(8'hEE, 32'h20, 32);
    pp(32'h41, 4);                                // A0 ignored
    rd(8'hEE, 32'h41, 6);
    pp(32'h60, 2 * PAGE + 2);                     // more than a page: last bytes win
    rd(8'hEE, 32'h60, PAGE);
    pp(32'hFFFF_FFF0, 6);                         // upper address bits ignored
    rd(8'hEE, 32'h1F0, 16);
    rd(8'hEE, MEM - 4, 12);                       // read wraps past the end
    for (int k = 0; k < 12; k++) begin
      a = $urandom; pp(a, 2 * $urandom_range(1, PAGE / 2));
      rd(8'hEE, a, $urandom_range(1, 40));
    end
    check_array();
    // ---- sector erase ----
    se(32'h0); se(32'h1AB); rd(8'hEE, 32'h80, 8); rd(8'hEE, 32'h7E, 4);
    check_array();
    // ---- dummy cycles ----
    wrcr(8'h04); rd(8'h85, 0, 2); rd(8'hEE, 32'h22, 8);
    wrcr(8'hFF); rd(8'h85, 0, 2); rd(8'hEE, 32'h22, 4);
    wrcr(8'h03);                                  // below 4: rejected
    wrcr(8'h00);
    wrcr(8'h0C); rd(8'h9F, 0, 6);
    foreach_dummy();
    // every read kind with no, one, a few, many and very many bytes
    for (int k = 0; k < 4; k++) for (int l = 0; l < 5; l++)
      rd(k == 0 ? 8'h05 : k == 1 ? 8'h9F : k == 2 ? 8'hEE : 8'h85, $urandom, l == 0 ? 0 : l == 1 ? 2 : l == 2 ? 6 : l == 3 ? 30 : 70);
    // ---- RESET ENABLE / RESET ----
    cmd(8'h99);                                   // no RESET ENABLE
    cmd(8'h66); cmd(8'h06); cmd(8'h99);           // broken by WREN
    cmd(8'h66); cmd(8'h99); rd(8'h85, 0, 2);
    cmd(8'h06); cmd(8'h66); cmd(8'h99); rd(8'h05, 0, 2);
    // ---- errors ----
    hdr(8'h06); tx[1] = 8'h00; run(2, 0);         // bad extension
    hdr(8'h01); run(2, 0);                        // unknown command
    run(1, 0);                                    // one edge
    run(0, 0);                                    // CS# pulse only
    hdr(8'h06); run(3, 0);                        // WREN runs on
    hdr(8'h06); run(4, 0);
    hdr(8'hEE, 32'h40); run(4, 0);                // cut in the address
    hdr(8'hEE, 32'h40); run(6, 7);                // ends with CK high
    hdr(8'hEE, 32'h40); run(6, 4);                // ends in the latency
    cmd(8'h06); hdr(8'h21, 32'h80); run(8, 0);    // SE with data
    hdr(8'h12, 32'h80); run(6, 0);                // PP without data
    hdr(8'h12, 32'h80); tx[6] = 0; run(7, 0);     // PP with half a cycle
    hdr(8'h12, 32'h80); tx[6] = 0; tx[7] = 0; run(8, 0);
    wait_ready();
    cmd(8'h06); hdr(8'h21, 32'h0); run(6, 0);     // busy: only RDSR
    cmd(8'h06); hdr(8'hEE); run(6, 4); cmd(8'h04); rd(8'h05, 0, 2);
    wait_ready();
    cmd(8'h06); cmd(8'h60);
    rd(8'h05, 0, 2 * MEM);                        // RDSR across the end of the erase
    wait_ready();
    check_array();
    // ---- random frames ----
    for (int t = 0; t < 600; t++) begin
      logic [7:0] c;
      int nd, nr;
      case ($urandom_range(15))
        0: c = 8'h06; 1: c = 8'h04; 2: c = 8'h05; 3: c = 8'h9F; 4, 5: c = 8'hEE; 6, 7: c = 8'h12;
        8: c = 8'h21; 9: c = ($urandom_range(7) == 0) ? 8'h60 : 8'h06; 10: c = 8'h81; 11: c = 8'h85;
        12: c = 8'h66; 13: c = 8'h99; default: c = $urandom;
      endcase
      Q = $urandom_range(1, 4);
      hdr(c, $urandom);
      if ($urandom_range(15) == 0) tx[1] = $urandom;
      if (c == 8'h81) tx[6] = $urandom_range(31);
      for (int k = 6; k < 70; k++) if (c != 8'h81 || k > 6) tx[k] = $urandom;
      if ($urandom_range(3) != 0 && (c == 8'h12 || c == 8'h21 || c == 8'h60 || c == 8'h81)) cmd(8'h06);
      if ($urandom_range(1) && c == 8'h99) cmd(8'h66);
      case ($urandom_range(9))
        0: begin nd = $urandom_range(0, 6); nr = 0; end                    // short
        1: begin nd = 6; nr = $urandom_range(0, 9); end
        default:
          if (dec(c) >= 0 && dec(c) & 2) begin nd = 6; nr = 2 * m_dummy + $urandom_range(0, 24); end
          else if (c == 8'h12 || c == 8'h81) begin nd = 6 + 2 * $urandom_range(1, 20); nr = 0; end
          else if (dec(c) >= 0 && dec(c) & 4) begin nd = 6; nr = 0; end
          else begin nd = 2; nr = 0; end
      endcase
      run(nd, nr);
      if (m_wip && $urandom_range(3) == 0) begin cmd(8'h06); end           // rejected while busy
      wait_ready();
    end
    Q = 2;
    check_array();
    // ---- reset mid-frame and mid-erase: the array keeps what was done ----
    cmd(8'h06); csn = 0; clocks(2); edge_c(1, 8'h60); edge_c(1, 8'h9F);
    rst_n = 0; clocks(2);
    if (dq_oe || dqs_oe || irq_cmd || irq_err || irq_done || sr !== 2'b00 || dummy !== 8 || err_code !== 0)
      fail("reset values");
    csn = 1; ck = 0; h_oe = 0; clocks(2); rst_n = 1; clocks(2);
    m_wel = 0; m_dummy = 8; m_err = 0; m_rsten = 0;
    rd(8'hEE, 0, 8);
    ce(); pp(0, PAGE, 0, 8'h00); cmd(8'h06); hdr(8'h21, 0); run(6, 0);
    clocks(15); rst_n = 0; clocks(2); rst_n = 1; clocks(2);
    m_wip = 0; m_wel = 0;
    // an erase cut short: the first bytes are erased, the end of the page is not
    for (int i = 0; i < 15; i++) m_mem[i] = 8'hFF;
    if (dut.mem[PAGE - 1] !== 8'h00) fail("an erase cut by reset ran to the end of the page");
    for (int i = 15; i < SECT; i++) m_mem[i] = i < PAGE ? dut.mem[i] : 8'hFF;
    rd(8'hEE, 0, PAGE);
    check_array();

    if (n_idone != n_done_exp - 1) fail($sformatf("%0d irq_done, expected %0d", n_idone, n_done_exp - 1));
    $display("errors by code 1..7: %0d %0d %0d %0d %0d %0d %0d", n_by_err[1], n_by_err[2], n_by_err[3],
             n_by_err[4], n_by_err[5], n_by_err[6], n_by_err[7]);
    $display("accepted: WREN %0d WRDI %0d RDSR %0d RDID %0d READ %0d PP %0d SE %0d CE %0d WRCR %0d RDCR %0d RSTEN %0d RST %0d",
             n_by_cmd[8'h06], n_by_cmd[8'h04], n_by_cmd[8'h05], n_by_cmd[8'h9F], n_by_cmd[8'hEE], n_by_cmd[8'h12],
             n_by_cmd[8'h21], n_by_cmd[8'h60], n_by_cmd[8'h81], n_by_cmd[8'h85], n_by_cmd[8'h66], n_by_cmd[8'h99]);
    $display("xSPI: %0d commands, %0d errors, %0d program / erase", n_cmd_exp, n_err_exp, n_busy);
    if (errors == 0) $display("TEST PASSED: xSPI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200ms;
    $display("TIMEOUT"); $finish;
  end
endmodule
