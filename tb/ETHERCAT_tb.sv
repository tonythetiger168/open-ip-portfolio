// SPDX-License-Identifier: Apache-2.0
// ETHERCAT_tb: frames built from datagram lists go into rx; a frame-level
// golden model (its own memory image, kept in step through the host port
// and the frames' writes) gives the expected tx frame, FCS and fr_* result.
// Covers every command addressed and not, ADP / WKC carries, FMMUs (both,
// overlap, read-only / write-only, none), memory map edges, many datagrams
// (working counter saturation), long datagrams, non-EtherCAT and short
// frames, bad FCS, back-to-back frames, host collisions and reset.
`timescale 1ns/1ps
module ETHERCAT_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask
  task automatic cyc(input int n); repeat (n) @(negedge clk); endtask

  logic        rx_dv = 0;
  logic [7:0]  rx_d = 0;
  wire         tx_dv;
  wire  [7:0]  tx_d;
  logic        host_rd = 0, host_wr = 0;
  logic [15:0] host_addr = 0;
  logic [7:0]  host_wdata = 0;
  wire  [7:0]  host_rdata;
  wire         fr_done, fr_fcs_ok, fr_ecat;
  wire  [7:0]  fr_dgrams, fr_wkc;
  ETHERCAT_top dut (.*);

  // ---------------- golden memory image ----------------
  logic [7:0] g_ram [0:1023];
  logic [7:0] g_sta [0:1];
  logic [7:0] g_fm  [0:31];
  function automatic bit g_map(input logic [15:0] a);
    return a >= 16'h1000 && a < 16'h1400 || a == 16'h0010 || a == 16'h0011 || a >= 16'h0600 && a < 16'h0620;
  endfunction
  function automatic logic [7:0] g_rd(input logic [15:0] a);
    if (a >= 16'h1000 && a < 16'h1400) return g_ram[a - 16'h1000];
    if (a == 16'h0010 || a == 16'h0011) return g_sta[a - 16'h0010];
    if (a >= 16'h0600 && a < 16'h0620) return g_fm[a - 16'h0600];
    return 8'h00;
  endfunction
  task automatic g_wr(input logic [15:0] a, input logic [7:0] d);
    if (a >= 16'h1000 && a < 16'h1400) g_ram[a - 16'h1000] = d;
    else if (a == 16'h0010 || a == 16'h0011) g_sta[a - 16'h0010] = d;
    else if (a >= 16'h0600 && a < 16'h0620) g_fm[a - 16'h0600] = d;
  endtask
  // FMMU lookup of logical address la: hit, physical address, read / write
  task automatic g_fmmu(input logic [31:0] la, output bit hit, output logic [15:0] pa, output bit r, output bit w);
    hit = 0; pa = 0; r = 0; w = 0;
    for (int f = 0; f < 2 && !hit; f++) begin
      logic [31:0] st, ln;
      st = {g_fm[16 * f + 3], g_fm[16 * f + 2], g_fm[16 * f + 1], g_fm[16 * f]};
      ln = {16'd0, g_fm[16 * f + 5], g_fm[16 * f + 4]};
      if (g_fm[16 * f + 12][0] && la >= st && {1'b0, la} < {1'b0, st} + {1'b0, ln}) begin
        hit = 1; r = g_fm[16 * f + 11][0]; w = g_fm[16 * f + 11][1];
        pa = {g_fm[16 * f + 9], g_fm[16 * f + 8]} + 16'(la - st);
      end
    end
  endtask

  // ---------------- host port ----------------
  task automatic h_wr(input logic [15:0] a, input logic [7:0] d);
    @(negedge clk) host_wr = 1; host_addr = a; host_wdata = d;
    @(negedge clk) host_wr = 0;
    g_wr(a, d);
  endtask
  task automatic h_rd_exp(input logic [15:0] a);
    @(negedge clk) host_rd = 1; host_addr = a;
    @(negedge clk) host_rd = 0;
    if (host_rdata !== g_rd(a)) fail($sformatf("host read %h = %h, expected %h", a, host_rdata, g_rd(a)));
  endtask

  // ---------------- frames ----------------
  logic [7:0] fr [0:4095];            // frame being built (without FCS)
  int         fn;
  logic [7:0] ex [0:4095];            // golden output
  int         xn;
  task automatic fclr; fn = 0; endtask
  task automatic fp(input logic [7:0] b); fr[fn] = b; fn++; endtask
  function automatic logic [31:0] crc_upd(input logic [31:0] c, input logic [7:0] d);
    c ^= {24'd0, d};
    for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction
  function automatic logic [31:0] crc_fr(input int n);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int i = 0; i < n; i++) c = crc_upd(c, fr[i]);
    return ~c;
  endfunction
  function automatic logic [31:0] crc_ex(input int n);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int i = 0; i < n; i++) c = crc_upd(c, ex[i]);
    return ~c;
  endfunction
  task automatic eth(input logic [15:0] etype = 16'h88A4);
    fclr();
    for (int i = 0; i < 6; i++) fp(8'hFF);
    for (int i = 0; i < 6; i++) fp(8'h02 + 8'(i));
    fp(etype[15:8]); fp(etype[7:0]);
  endtask
  int ecat_at;
  task automatic ecat_hdr(input logic [3:0] ty = 1);
    ecat_at = fn;
    fp(8'h00); fp({ty, 4'h0});
  endtask
  task automatic ecat_len;                  // fill in the EtherCAT length
    int n;
    n = fn - ecat_at - 2;
    fr[ecat_at] = n[7:0]; fr[ecat_at + 1] = {fr[ecat_at + 1][7:4], 1'b0, n[10:8]};
  endtask
  // one datagram; data random unless given
  task automatic dg(input logic [7:0] cmd, input logic [15:0] adp, input logic [15:0] ado, input int len,
                    input bit more, input logic [15:0] wkc = 0, input int fill = -1);
    fp(cmd); fp(8'($urandom));
    fp(adp[7:0]); fp(adp[15:8]); fp(ado[7:0]); fp(ado[15:8]);
    fp(len[7:0]); fp({more, 4'b0000, len[10:8]});
    fp(8'($urandom)); fp(8'($urandom));
    for (int i = 0; i < len; i++) fp(fill >= 0 ? 8'(fill) : 8'($urandom));
    fp(wkc[7:0]); fp(wkc[15:8]);
  endtask

  // golden processing of the frame (no FCS) into ex; result fields
  bit         x_ecat;
  int         x_dg, x_wkc;
  task automatic golden;
    int p, len;
    bit go;
    for (int i = 0; i < fn; i++) ex[i] = fr[i];
    xn = fn; x_ecat = 0; x_dg = 0; x_wkc = 0;
    go = fn >= 16 && fr[12] == 8'h88 && fr[13] == 8'hA4 && fr[15][7:4] == 4'd1;
    x_ecat = go;
    p = 16;
    while (go) begin
      logic [7:0]  cmd;
      logic [15:0] adp, ado, w;
      bit          more, hitp, rd, wr, rw, any_r, any_w;
      int          inc;
      if (p + 10 > fn) begin
        // a cut header: the octets that do pass are still processed (ADP + 1)
        cmd = fr[p];
        if (p + 2 < fn && (cmd >= 1 && cmd <= 3 || cmd >= 7 && cmd <= 9 || cmd == 13)) begin
          w = {p + 3 < fn ? fr[p + 3] : 8'h00, fr[p + 2]} + 16'd1;
          ex[p + 2] = w[7:0];
          if (p + 3 < fn) ex[p + 3] = w[15:8];
        end
        go = 0;
      end else begin
        cmd = fr[p]; adp = {fr[p + 3], fr[p + 2]}; ado = {fr[p + 5], fr[p + 4]};
        len = {fr[p + 7][2:0], fr[p + 6]}; more = fr[p + 7][7];
        rd = cmd == 1 || cmd == 4 || cmd == 7 || cmd == 10;
        wr = cmd == 2 || cmd == 5 || cmd == 8 || cmd == 11;
        rw = cmd == 3 || cmd == 6 || cmd == 9 || cmd == 12;
        hitp = (cmd >= 1 && cmd <= 3 || cmd == 13) ? adp == 0 :
               (cmd >= 4 && cmd <= 6 || cmd == 14) ? adp == {g_sta[1], g_sta[0]} : (cmd >= 7 && cmd <= 9);
        if (cmd >= 1 && cmd <= 3 || cmd >= 7 && cmd <= 9 || cmd == 13) begin
          w = adp + 16'd1; ex[p + 2] = w[7:0]; ex[p + 3] = w[15:8];
        end
        inc = 0; any_r = 0; any_w = 0;
        for (int i = 0; i < len && go; i++) begin
          logic [7:0] d;
          if (p + 10 + i >= fn) go = 0;
          else begin
            d = fr[p + 10 + i];
            if (cmd >= 10 && cmd <= 12) begin
              bit h, fr_, fw;
              logic [15:0] pa;
              g_fmmu({ado, adp} + i, h, pa, fr_, fw);
              if (h && fr_ && (cmd == 10 || cmd == 12)) begin ex[p + 10 + i] = g_rd(pa); any_r = 1; end
              if (h && fw && (cmd == 11 || cmd == 12)) begin g_wr(pa, d); any_w = 1; end
            end else if (cmd == 13 || cmd == 14) begin
              if (hitp) ex[p + 10 + i] = g_rd(ado + 16'(i));
              else g_wr(ado + 16'(i), d);
            end else if (hitp && (rd || wr || rw)) begin
              if (rd || rw) ex[p + 10 + i] = (cmd == 7 || cmd == 9) ? d | g_rd(ado + 16'(i)) : g_rd(ado + 16'(i));
              if (wr || rw) g_wr(ado + 16'(i), d);
            end
          end
        end
        if (cmd >= 10 && cmd <= 12) inc = (any_r ? 1 : 0) + (any_w ? (cmd == 12 ? 2 : 1) : 0);
        else if (cmd == 13 || cmd == 14) inc = 1;
        else if (hitp) inc = rw ? 3 : (rd || wr) ? 1 : 0;
        if (!go || p + 10 + len + 1 >= fn) go = 0;
        else begin
          w = {fr[p + 11 + len], fr[p + 10 + len]} + 16'(inc);
          ex[p + 10 + len] = w[7:0]; ex[p + 11 + len] = w[15:8];
          x_dg++; x_wkc = x_wkc + inc > 255 ? 255 : x_wkc + inc;
          p = p + 12 + len;
          go = more;
        end
      end
    end
  endtask

  // prepared frames (+ FCS, optionally broken; none for raw): input octets and the golden output
  logic [7:0]  qi [0:7][0:4095], qe [0:7][0:4095];
  int          qin [0:7], qen [0:7], nq = 0;
  logic [17:0] q_res [0:7];           // {fcs_ok, ecat, dgrams, wkc} expected per frame
  string       q_name [0:7];
  task automatic prep(input string what, input bit bad_fcs = 0, input bit raw = 0);
    logic [31:0] f, fe;
    int n;
    golden();
    n = fn;
    for (int i = 0; i < fn; i++) begin qi[nq][i] = fr[i]; qe[nq][i] = ex[i]; end
    if (!raw) begin
      f = crc_fr(fn) ^ (bad_fcs ? 32'h0000_0100 : 32'h0);
      fe = crc_ex(xn) ^ (bad_fcs ? 32'hFFFF_FFFF : 32'h0);
      for (int i = 0; i < 4; i++) begin qi[nq][fn + i] = f[8 * i +: 8]; qe[nq][fn + i] = fe[8 * i +: 8]; end
      n = fn + 4;
    end
    if (n < 5) begin
      for (int i = 0; i < n; i++) qe[nq][i] = qi[nq][i];
      x_ecat = 0; x_dg = 0; x_wkc = 0;
    end
    qin[nq] = n; qen[nq] = n; q_name[nq] = what;
    q_res[nq] = {!bad_fcs && !raw && n >= 5, x_ecat, 8'(x_dg), 8'(x_wkc)};
    nq++;
  endtask
  // drive every prepared frame, idle clocks between them
  task automatic drive(input int idle = 12);
    for (int k = 0; k < nq; k++) begin
      for (int i = 0; i < qin[k]; i++) begin @(negedge clk) rx_dv = 1; rx_d = qi[k][i]; end
      @(negedge clk) rx_dv = 0; rx_d = 8'($urandom);
      repeat (idle - 1) @(negedge clk);
    end
  endtask
  // output frames and results, split by tx_dv / fr_done
  logic [7:0]  of_ [0:7][0:4095];
  int          ofn [0:7], nof = 0, ocn = 0, nres = 0;
  logic [17:0] o_res [0:7];
  always @(negedge clk) begin
    if (tx_dv) begin if (nof < 8 && ocn < 4096) of_[nof][ocn] = tx_d; ocn++; end
    else if (ocn != 0) begin if (nof < 8) ofn[nof] = ocn; nof++; ocn = 0; end
    if (fr_done) begin if (nres < 8) o_res[nres] = {fr_fcs_ok, fr_ecat, fr_dgrams, fr_wkc}; nres++; end
  end
  int n_fr = 0;
  task automatic check;
    cyc(10);
    if (nof != nq || nres != nq) fail($sformatf("%0d frames / %0d results out, %0d expected", nof, nres, nq));
    for (int k = 0; k < nq && k < nof && k < nres; k++) begin
      if (o_res[k] !== q_res[k]) fail($sformatf("%s: result %h, expected %h", q_name[k], o_res[k], q_res[k]));
      if (ofn[k] != qen[k]) fail($sformatf("%s: %0d octets out, expected %0d", q_name[k], ofn[k], qen[k]));
      else begin
        int bad;
        bad = -1;
        for (int i = 0; i < qen[k]; i++) if (bad < 0 && of_[k][i] !== qe[k][i]) bad = i;
        if (bad >= 0) fail($sformatf("%s: octet %0d = %h, expected %h", q_name[k], bad, of_[k][bad], qe[k][bad]));
      end
      n_fr++;
    end
    nq = 0; nof = 0; nres = 0;
  endtask
  task automatic send(input string what, input bit bad_fcs = 0);
    prep(what, bad_fcs); drive(); check();
  endtask

  // memory image check through the host port
  task automatic mem_check(input logic [15:0] a, input int n);
    for (int i = 0; i < n; i++) h_rd_exp(a + 16'(i));
  endtask
  // FMMU f through the host port
  task automatic fmmu(input int f, input logic [31:0] ls, input logic [15:0] ln, input logic [15:0] ps,
                      input bit r, input bit w, input bit act);
    logic [7:0] b [0:15];
    b[0] = ls[7:0]; b[1] = ls[15:8]; b[2] = ls[23:16]; b[3] = ls[31:24];
    b[4] = ln[7:0]; b[5] = ln[15:8]; b[6] = 0; b[7] = 8'h07; b[8] = ps[7:0]; b[9] = ps[15:8];
    b[10] = 0; b[11] = {6'd0, w, r}; b[12] = {7'd0, act}; b[13] = 0; b[14] = 0; b[15] = 0;
    for (int i = 0; i < 16; i++) h_wr(16'h0600 + 16'(16 * f + i), b[i]);
  endtask

  initial begin
    cyc(3); rst_n = 1; cyc(3);
    // the memory image: RAM through the host port, registers 0 after reset
    for (int i = 0; i < 1024; i++) h_wr(16'h1000 + 16'(i), 8'($urandom));
    for (int i = 0; i < 2; i++) g_sta[i] = 0;
    for (int i = 0; i < 32; i++) g_fm[i] = 0;
    mem_check(16'h0FFE, 3); mem_check(16'h13FF, 2); mem_check(16'h000F, 4); mem_check(16'h05FF, 2);
    mem_check(16'h061F, 2); mem_check(16'hFFFF, 1);

    // ---- 1. other frames pass unchanged
    $display("[%0t] 1. pass-through", $time);
    eth(16'h0800); repeat (46) fp(8'($urandom)); send("IPv4");
    eth(16'h88A5); repeat (46) fp(8'($urandom)); send("88A5");
    eth(16'h89A4); repeat (46) fp(8'($urandom)); send("89A4");
    eth(); ecat_hdr(4); dg(8'd1, 0, 16'h1000, 4, 0); ecat_len(); send("EtherCAT type 4");
    eth(16'h0800); repeat (46) fp(8'($urandom)); send("bad FCS", 1);
    fclr(); fp(8'h12); prep("1 octet", 0, 1); drive(); check();
    fclr(); repeat (4) fp(8'($urandom)); prep("4 octets", 0, 1); drive(); check();
    fclr(); send("FCS only");                                // 4 octets with a good FCS: too short
    fclr(); fp(8'h77); send("1 octet + FCS");

    // ---- 2. auto-increment addressing
    $display("[%0t] 2. auto-increment", $time);
    eth(); ecat_hdr();
    dg(8'd1, 16'h0000, 16'h1000, 8, 1, 16'h0005);                 // APRD, addressed
    dg(8'd2, 16'h0000, 16'h1100, 8, 1);                           // APWR
    dg(8'd3, 16'h0000, 16'h1200, 8, 1, 16'h00FE);                 // APRW, WKC carry
    dg(8'd1, 16'h0000, 16'h1000, 2, 1, 16'h00FE);                 // APRD: WKC 0x00FF, no carry
    dg(8'd1, 16'hFFFF, 16'h1000, 4, 1);                           // not addressed, ADP carry
    dg(8'd2, 16'h00FF, 16'h1100, 4, 1);
    dg(8'd3, 16'h0100, 16'h1200, 4, 0);
    ecat_len(); send("AP");
    mem_check(16'h1100, 8); mem_check(16'h1200, 8);
    // station address through APWR
    eth(); ecat_hdr();
    dg(8'd2, 16'h0000, 16'h0010, 2, 0); fr[16 + 10] = 8'h34; fr[16 + 11] = 8'h12;
    ecat_len(); send("APWR station address");
    h_rd_exp(16'h0010); h_rd_exp(16'h0011);

    // ---- 3. configured addressing
    $display("[%0t] 3. configured", $time);
    eth(); ecat_hdr();
    dg(8'd4, 16'h1234, 16'h1004, 16, 1);
    dg(8'd5, 16'h1234, 16'h1300, 16, 1, 16'hFFFF);                // WKC 0xFFFF + 1
    dg(8'd6, 16'h1234, 16'h13F8, 8, 1);                           // the last RAM octets
    dg(8'd4, 16'h1235, 16'h1004, 4, 1);                           // others
    dg(8'd5, 16'h0234, 16'h1300, 4, 1);
    dg(8'd6, 16'h1034, 16'h1300, 4, 0);
    ecat_len(); send("FP");
    mem_check(16'h1300, 16); mem_check(16'h13F8, 8);
    h_wr(16'h0010, 8'hCB); h_wr(16'h0011, 8'hED);
    eth(); ecat_hdr();
    dg(8'd6, 16'hEDCB, 16'h13FC, 8, 1);                           // runs past the RAM
    dg(8'd4, 16'hEDCB, 16'h0FFC, 8, 1);                           // starts below it
    dg(8'd5, 16'hEDCB, 16'h0000, 4, 1);                           // unmapped
    dg(8'd4, 16'hEDCB, 16'h000E, 4, 0);
    ecat_len(); send("FP edges");
    mem_check(16'h13FC, 4);

    // ---- 4. broadcast
    $display("[%0t] 4. broadcast", $time);
    eth(); ecat_hdr();
    dg(8'd7, 16'h0003, 16'h1010, 8, 1, 0, 8'h81);                 // BRD: data OR memory
    dg(8'd8, 16'hFFFF, 16'h1020, 8, 1);                           // BWR
    dg(8'd9, 16'h0000, 16'h1030, 8, 0, 0, 8'h00);                 // BRW
    ecat_len(); send("B");
    mem_check(16'h1020, 8); mem_check(16'h1030, 8);

    // ---- 5. read-multiple-write
    $display("[%0t] 5. ARMW / FRMW", $time);
    eth(); ecat_hdr();
    dg(8'd13, 16'h0000, 16'h1040, 4, 1);                          // reads
    dg(8'd13, 16'h0002, 16'h1048, 4, 1);                          // writes
    dg(8'd14, 16'hEDCB, 16'h1050, 4, 1);                          // reads
    dg(8'd14, 16'h0001, 16'h1058, 4, 0);                          // writes
    ecat_len(); send("RMW");
    mem_check(16'h1040, 32);

    // ---- 6. NOP, unknown commands, empty datagrams
    $display("[%0t] 6. NOP", $time);
    eth(); ecat_hdr();
    dg(8'd0, 16'h0000, 16'h1000, 4, 1);
    dg(8'd15, 16'h0000, 16'h1000, 4, 1);
    dg(8'd255, 16'hEDCB, 16'h1000, 4, 1);
    dg(8'd2, 16'h0000, 16'h1000, 0, 1);                           // no data: still counted
    dg(8'd3, 16'hEDCB, 16'h1000, 0, 0);
    ecat_len(); send("NOP");

    // ---- 7. logical addressing
    $display("[%0t] 7. FMMUs", $time);
    fmmu(0, 32'h0001_0000, 16'd16, 16'h1100, 1, 0, 1);           // inputs, read only
    fmmu(1, 32'h0001_0008, 16'd16, 16'h1180, 0, 1, 1);           // outputs, write only (overlaps 0)
    eth(); ecat_hdr();
    dg(8'd10, 16'h0000, 16'h0001, 32, 1);                         // LRD 0x10000..0x1001F
    dg(8'd11, 16'hFFF8, 16'h0000, 32, 1);                         // LWR from 0xFFF8
    dg(8'd12, 16'h0004, 16'h0001, 24, 1);                         // LRW
    dg(8'd10, 16'h0000, 16'h0002, 8, 1);                          // nothing mapped
    dg(8'd11, 16'h0000, 16'h0001, 8, 1);                          // read-only FMMU: no write
    dg(8'd12, 16'h0018, 16'h0001, 8, 0);                          // write-only part
    ecat_len(); send("L");
    mem_check(16'h1100, 16); mem_check(16'h1180, 16);
    fmmu(0, 32'hFFFF_FFF0, 16'hFFFF, 16'h1200, 1, 1, 1);          // to the top of the space
    fmmu(1, 32'h0000_0000, 16'd8, 16'h1300, 1, 1, 0);             // not active
    eth(); ecat_hdr();
    dg(8'd12, 16'hFFF8, 16'hFFFF, 16, 1);                         // wraps to 0
    dg(8'd12, 16'h0000, 16'h0000, 8, 0);
    ecat_len(); send("L top");
    mem_check(16'h1200, 16);
    fmmu(1, 32'h0000_0000, 16'd0, 16'h1300, 1, 1, 1);             // length 0
    fmmu(0, 32'h8000_0000, 16'd4, 16'h1300, 0, 0, 1);             // neither read nres write
    eth(); ecat_hdr();
    dg(8'd12, 16'h0000, 16'h8000, 8, 0);
    ecat_len(); send("L none");

    // ---- 8. many datagrams: the working counter sum saturates
    $display("[%0t] 8. many datagrams", $time);
    eth(); ecat_hdr();
    for (int i = 0; i < 90; i++) dg(8'd3, 16'h0000, 16'h1000 + 16'(i), 1, i != 89);
    ecat_len(); send("90 APRW");
    // a long datagram (2000 octets) and a truncated one
    eth(); ecat_hdr(); dg(8'd4, 16'hEDCB, 16'h1000, 2000, 0); ecat_len(); send("2000 octets");
    eth(); ecat_hdr(); dg(8'd1, 16'h0000, 16'h1000, 40, 0);
    fn = fn - 36;
    send("truncated datagram");
    eth(); ecat_hdr(); repeat (5) fp(8'h01); send("truncated header");

    // ---- 9. back to back (5 idle clocks), bad FCS on an EtherCAT frame
    $display("[%0t] 9. back to back", $time);
    for (int i = 0; i < 4; i++) begin
      eth(); ecat_hdr(); dg(8'd3, 16'h0000, 16'h1060 + 16'(4 * i), 4, 0); ecat_len(); prep("b2b", i == 2);
    end
    drive(5); check();
    mem_check(16'h1060, 16);

    // ---- 10. host write collides with a frame write
    $display("[%0t] 10. host collision", $time);
    eth(); ecat_hdr(); dg(8'd2, 16'h0000, 16'h1070, 4, 0); ecat_len();
    fork
      send("collision");
      begin
        @(negedge clk); while (!(dut.m_we && dut.m_wa == 16'h1072)) @(negedge clk);
        host_wr = 1; host_addr = 16'h1072; host_wdata = ~fr[16 + 12];
        @(negedge clk) host_wr = 0;
      end
    join
    mem_check(16'h1070, 4);
    fork
      begin eth(); ecat_hdr(); dg(8'd5, 16'hEDCB, 16'h0010, 2, 0, 0, 8'h55); ecat_len(); send("station collision"); end
      begin
        @(negedge clk); while (!(dut.m_we && dut.m_wa == 16'h0011)) @(negedge clk);
        host_wr = 1; host_addr = 16'h0011; host_wdata = 8'hAA;
        @(negedge clk) host_wr = 0;
      end
    join
    mem_check(16'h0010, 2);
    h_wr(16'h0010, 8'hCB); h_wr(16'h0011, 8'hED);
    // a host read of the octet the frame writes in that clock: the old value
    begin
      logic [7:0] old;
      old = g_rd(16'h1075);
      fork
        begin eth(); ecat_hdr(); dg(8'd2, 16'h0000, 16'h1074, 4, 0, 0, 8'h3C); ecat_len(); send("read collision"); end
        begin
          @(negedge clk); while (!(dut.m_we && dut.m_wa == 16'h1075)) @(negedge clk);
          host_rd = 1; host_addr = 16'h1075;
          @(negedge clk) host_rd = 0;
          if (host_rdata !== old) fail($sformatf("host read in a frame write: %h, expected %h", host_rdata, old));
        end
      join
      mem_check(16'h1074, 4);
    end

    // ---- 10b. FMMU 0 off, FMMU 1 read / write at 0x0002_0000: logical datagrams that miss it
    h_wr(16'h060C, 8'h00);
    h_wr(16'h0610, 8'h00); h_wr(16'h0611, 8'h00); h_wr(16'h0612, 8'h02); h_wr(16'h0613, 8'h00);
    h_wr(16'h0614, 8'h04); h_wr(16'h0615, 8'h00); h_wr(16'h061B, 8'h03); h_wr(16'h061C, 8'h01);
    eth(); ecat_hdr(); dg(8'd10, 16'h0000, 16'h0000, 1, 1); dg(8'd11, 16'h0010, 16'h0000, 2, 1);
    dg(8'd12, 16'h0020, 16'h0000, 3, 0); ecat_len(); send("logical miss");   // not 4: winc is 2 bits
    // FMMU registers through frames, top of the address space, 160 datagrams
    eth(); ecat_hdr(); dg(8'd2, 16'h0000, 16'h0600, 32, 0, 0, 8'hFF); ecat_len(); send("FMMU registers ones");
    mem_check(16'h0600, 32);
    eth(); ecat_hdr(); dg(8'd1, 16'h0000, 16'h0600, 32, 0); ecat_len(); send("FMMU registers read");
    eth(); ecat_hdr(); dg(8'd2, 16'h0000, 16'h0600, 32, 0, 0, 8'h00); ecat_len(); send("FMMU registers zeros");
    mem_check(16'h0600, 32);
    eth(); ecat_hdr(); dg(8'd3, 16'h0000, 16'hFFF0, 16, 0); ecat_len(); send("unmapped top");
    eth(); ecat_hdr();
    for (int i = 0; i < 160; i++) dg(8'd1, 16'h0000, 16'h1000 + 16'(i), 1, i != 159);
    ecat_len(); send("160 APRD");

    // ---- 11. reset in a frame
    $display("[%0t] 11. reset", $time);
    eth(); ecat_hdr(); dg(8'd1, 16'h0000, 16'h1000, 40, 0); ecat_len();
    for (int i = 0; i < 30; i++) begin @(negedge clk) rx_dv = 1; rx_d = fr[i]; end
    rst_n = 0;
    cyc(2);
    if (tx_dv || fr_done || fr_fcs_ok || fr_ecat || fr_dgrams || fr_wkc || host_rdata !== 0) fail("outputs in reset");
    rx_dv = 0; cyc(2); rst_n = 1; cyc(10);
    if (nres != 0) fail("frame result for the frame cut by reset");
    nof = 0; ocn = 0; nres = 0;                 // drop the octets sent before the reset
    for (int i = 0; i < 2; i++) g_sta[i] = 0;
    for (int i = 0; i < 32; i++) g_fm[i] = 0;
    mem_check(16'h0010, 2); mem_check(16'h0600, 32);
    eth(); ecat_hdr(); dg(8'd3, 16'h0000, 16'h1000, 8, 0); ecat_len(); send("after reset");

    $display("ETHERCAT: %0d frames", n_fr);
    if (errors == 0) $display("TEST PASSED: ETHERCAT");
    else $display("TEST FAILED: ETHERCAT (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50ms;
    $display("TEST FAILED: ETHERCAT (timeout)");
    $finish;
  end
endmodule
