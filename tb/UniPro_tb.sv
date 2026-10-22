// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Peer-device testbench for UniPro_top (v2.0).
// The TB is the far UniPro device on the symbol line plus the host CPU:
//  - peer TX: a symbol queue (start + 8 bits LSB first + stop) fed by a
//    frame builder (COF / ESC_DL framing, CRC16) with faults: bad CRC, bad
//    len, len > 16, control len != 3, over-long frame, missing stop bit;
//  - peer RX: an independent decoder of the DUT's line that checks every
//    frame (escaping, CRC, header, payload against the CPU push model) and
//    answers it: ACK / NAC / no answer / wrong-seq ACK for data frames,
//    GET response / SET confirm for PACP requests;
//  - CPU: TC0/TC1 pushes with queue overflow, PACP SET/GET, message buffer
//    reads and status reads checked against a model.
// The bound checker (tb/cov/UniPro_sva.sv) predicts tx_bit, cpu_rdata and
// irq on every clock.
// ============================================================================
`timescale 1ns/1ps
module UniPro_tb;

  localparam logic [7:0] COF = 8'h7E, ESC = 8'h9D;
  localparam logic [7:0] CC_GET = 8'd0, CC_SET = 8'd1, CC_GETRSP = 8'd2, CC_SETCNF = 8'd3,
                         CC_ACK = 8'd4, CC_NAC = 8'd5;
  localparam int ACK_WAIT = 600;

  logic        clk = 0, rst_n = 0;
  logic        rx_bit = 1'b1;
  logic        tx_bit;
  logic        cpu_we = 0, cpu_re = 0;
  logic [2:0]  cpu_addr = 3'd5;
  logic [31:0] cpu_wdata = 0;
  logic [31:0] cpu_rdata;
  logic        irq;
  int          errors = 0;

  UniPro_top #(.ACK_WAIT(ACK_WAIT)) dut (
    .clk(clk), .rst_n(rst_n), .rx_bit(rx_bit), .tx_bit(tx_bit),
    .cpu_we(cpu_we), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .irq(irq)
  );

  always #5 clk = ~clk;

  function automatic void fail(input string m);
    errors++;
    $display("ERROR @%0t: %s", $time, m);
  endfunction

  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    c = c ^ {d, 8'h00};
    for (int i = 0; i < 8; i++) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction

  int irq_n = 0;
  always @(posedge clk) if (rst_n && irq) irq_n++;

  // ------------------------------------------------------------ peer TX
  logic [7:0] sq [$];         // symbols to send
  bit         sq_bad [$];     // send this symbol with a bad stop bit
  int         sym_gap = 0;    // idle bits between symbols
  always begin : peer_tx
    logic [7:0] b;
    bit bad;
    @(negedge clk);
    if (!rst_n) begin rx_bit = 1; sq.delete(); sq_bad.delete(); end
    else if (sq.size() > 0) begin : one_sym
      b = sq.pop_front(); bad = sq_bad.pop_front();
      rx_bit = 0;
      for (int i = 0; i <= 8 + sym_gap; i++) begin
        @(negedge clk);
        if (!rst_n) begin rx_bit = 1; disable one_sym; end
        rx_bit = (i < 8) ? b[i] : (i == 8) ? !bad : 1'b1;
      end
    end else rx_bit = 1;
  end

  function automatic void sym(input logic [7:0] b, input bit bad = 0);
    sq.push_back(b); sq_bad.push_back(bad);
  endfunction

  // escaped content byte
  function automatic void esym(input logic [7:0] b);
    if (b == COF || b == ESC) begin sym(ESC); sym(b ^ 8'h20); end
    else sym(b);
  endfunction

  // frame from content bytes; crc_bad flips the CRC, extra adds bytes
  // frame from the content bytes in cb (iverilog cannot pass queues to functions)
  logic [7:0] cb [$];
  function automatic void frame_c(input bit crc_bad = 0);
    logic [15:0] crc;
    crc = 16'hFFFF;
    for (int i = 0; i < cb.size(); i++) crc = crc16(crc, cb[i]);
    if (crc_bad) crc = crc ^ (16'($urandom) | 16'h0001);
    sym(COF);
    for (int i = 0; i < cb.size(); i++) esym(cb[i]);
    esym(crc[15:8]); esym(crc[7:0]);
    sym(COF);
  endfunction

  function automatic void data_frame(input logic [3:0] cport, input logic [3:0] seq,
                                     input int n, input bit crc_bad = 0, input int len = -1);
    cb.delete();
    cb.push_back({1'($urandom), 3'($urandom), cport});
    cb.push_back({4'($urandom), seq});
    cb.push_back(len < 0 ? 8'(n) : 8'(len));
    for (int i = 0; i < n; i++) cb.push_back(8'($urandom));
    frame_c(crc_bad);
  endfunction

  function automatic void ctl_frame(input logic [7:0] cmd, input logic [7:0] a1,
                                    input logic [7:0] a2, input int len = 3);
    cb.delete();
    cb.push_back({4'($urandom), 4'hF});
    cb.push_back(8'($urandom));
    cb.push_back(8'(len));
    cb.push_back(cmd); cb.push_back(a1); cb.push_back(a2);
    for (int i = 3; i < len; i++) cb.push_back(8'($urandom));
    frame_c();
  endfunction

  // ------------------------------------------------------------ peer RX
  logic [7:0] peer_attr [0:15];
  int  nac_n = 0, mute_n = 0, badack_n = 0, pacp_mute = 0;
  int  n_data = 0, n_ack = 0, n_nac = 0, n_getrsp = 0, n_setcnf = 0, n_resend = 0;
  logic [3:0] last_ack_seq;
  // CPU push model: {tc, cport, payload}
  logic [35:0] q0m [$], q1m [$];
  bit          outst = 0;      // a DUT data frame is outstanding
  bit          acked = 0;
  logic [3:0]  o_seq;
  logic [36:0] o_frm;          // {tc, cport, payload}
  int          o_tx = 0;       // transmissions of it
  logic [3:0]  d_seq = 0;      // DUT tx seq model

  function automatic void retire;   // a new frame: the previous one was ACKed or dropped
    if (!outst || acked) return;
    if (o_tx != 4) fail($sformatf("frame seq %0d dropped after %0d sends", o_seq, o_tx));
    if (o_frm[36]) void'(q1m.pop_front()); else void'(q0m.pop_front());
    acked = 1;
  endfunction

  logic [7:0] rxf [$];        // DUT frame content just received
  function automatic void dut_frame;
    logic [15:0] crc;
    logic [7:0] f [0:15];
    int n;
    n = rxf.size();
    crc = 16'hFFFF;
    for (int i = 0; i < n; i++) begin crc = crc16(crc, rxf[i]); if (i < 16) f[i] = rxf[i]; end
    if (crc != 0) begin fail("DUT frame CRC"); return; end
    if (f[0][3:0] == 4'hF) begin                       // control frame
      if (n != 8 || f[0] != 8'h0F || f[1] != 0 || f[2] != 3) begin
        fail($sformatf("DUT control frame header: %0d bytes %h %h %h", n, f[0], f[1], f[2])); return;
      end
      case (f[3])
        CC_GET, CC_SET: begin
          if (f[4][7:4] != 0 || (f[3] == CC_GET && f[5] != 0)) fail("DUT PACP request fields");
          if (f[3] == CC_SET) peer_attr[f[4][3:0]] = f[5];
          if (pacp_mute > 0) pacp_mute--;
          else if (f[3] == CC_GET) ctl_frame(CC_GETRSP, f[4], peer_attr[f[4][3:0]]);
          else ctl_frame(CC_SETCNF, f[4], 8'($urandom));
        end
        CC_ACK: begin n_ack++; last_ack_seq = f[4][3:0]; end
        CC_NAC: begin n_nac++; last_ack_seq = f[4][3:0]; end
        CC_GETRSP: n_getrsp++;
        CC_SETCNF: n_setcnf++;
        default: fail($sformatf("DUT control command %0d", f[3]));
      endcase
      return;
    end
    // data frame
    n_data++;
    if (n != 9 || f[0][6:4] != 0 || f[1][7:4] != 0 || f[2] != 4) begin
      fail("DUT data frame header"); return;
    end
    if (outst && f[1][3:0] == o_seq) begin              // resend
      n_resend++; o_tx++;
      if ({f[0][7], f[0][3:0], f[3], f[4], f[5], f[6]} != o_frm) fail("resend content");
    end else begin
      retire();
      if (f[1][3:0] != d_seq) fail($sformatf("DUT seq %0d exp %0d", f[1][3:0], d_seq));
      d_seq = f[1][3:0] + 4'd1;
      o_frm = {f[0][7], f[0][3:0], f[3], f[4], f[5], f[6]};
      if (o_frm[36]) begin
        if (q1m.size() == 0 || o_frm != {1'b1, q1m[0]}) fail($sformatf("TC1 frame %h", o_frm));
      end else if (q0m.size() == 0 || o_frm != {1'b0, q0m[0]}) fail($sformatf("TC0 frame %h", o_frm));
      outst = 1; acked = 0; o_seq = f[1][3:0]; o_tx = 1;
    end
    if (mute_n > 0) mute_n--;
    else if (nac_n > 0) begin nac_n--; ctl_frame(CC_NAC, {4'($urandom), o_seq}, 8'($urandom)); end
    else if (badack_n > 0) begin badack_n--; ctl_frame(CC_ACK, {4'h0, o_seq + 4'd3}, 0); end
    else begin
      if (!acked) begin
        if (o_frm[36]) void'(q1m.pop_front()); else void'(q0m.pop_front());
      end
      acked = 1; ctl_frame(CC_ACK, {4'($urandom), o_seq}, 8'($urandom));
    end
  endfunction

  always begin : peer_rx
    logic [7:0] b;
    bit esc, inf, ok;
    esc = 0; inf = 0;
    forever begin
      @(negedge clk);
      if (rst_n && tx_bit == 0) begin
        ok = 1;
        for (int i = 0; i < 9 && ok; i++) begin
          @(negedge clk);
          ok = rst_n;
          if (i < 8) b[i] = tx_bit;
          else if (ok && tx_bit !== 1) fail("DUT stop bit");
        end
        if (!ok) ;
        else if (b == COF) begin
          if (inf && rxf.size() > 0) begin
            if (esc) fail("escape before COF");
            dut_frame();
            rxf.delete(); inf = 0;
          end else inf = 1;
          esc = 0;
        end else if (!inf) fail("DUT byte outside a frame");
        else if (b == ESC && !esc) esc = 1;
        else begin
          if (esc && !((b ^ 8'h20) == COF || (b ^ 8'h20) == ESC)) fail("needless escape");
          rxf.push_back(esc ? b ^ 8'h20 : b); esc = 0;
        end
      end
      if (!rst_n) begin rxf.delete(); inf = 0; esc = 0; end
    end
  end

  // ------------------------------------------------------------------ CPU
  task automatic wr(input logic [2:0] a, input logic [31:0] d);
    @(negedge clk); cpu_we = 1; cpu_addr = a; cpu_wdata = d;
    @(negedge clk); cpu_we = 0; cpu_wdata = $urandom; cpu_addr = 3'd5;
  endtask

  task automatic rd(input logic [2:0] a, output logic [31:0] d);
    @(negedge clk); cpu_re = 1; cpu_addr = a; #1 d = cpu_rdata;
    @(negedge clk); cpu_re = 0; cpu_addr = 3'd5;          // idle: status visible
  endtask

  logic [3:0] cport_m = 0;
  task automatic push(input bit tc, input logic [31:0] d);
    wr(tc ? 3'd1 : 3'd0, d);
  endtask
  // model: the push lands if the queue had room
  task automatic push_m(input bit tc, input logic [31:0] d);
    if (tc) begin if (q1m.size() < 8) q1m.push_back({cport_m, d}); end
    else    begin if (q0m.size() < 8) q0m.push_back({cport_m, d}); end
    push(tc, d);
  endtask

  task automatic set_cport(input logic [3:0] p);
    cport_m = p; wr(3'd4, {28'($urandom), p});
  endtask

  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask

  // queues drained (a frame dropped after four unanswered sends included)
  task automatic quiet(input int lim = 200000);
    int t;
    t = 0;
    while (t < lim && (sq.size() > 0 ||
           (q0m.size() + q1m.size() > 0 && !(outst && !acked && o_tx == 4)))) begin
      @(negedge clk); t++;
    end
    cycles(2 * ACK_WAIT + 200);
    if (outst && !acked) begin
      if (o_tx != 4) fail("outstanding frame neither ACKed nor dropped");
      if (o_frm[36]) void'(q1m.pop_front()); else void'(q0m.pop_front());
      acked = 1;
    end
    if (q0m.size() > 0 || q1m.size() > 0) fail("queues did not drain");
  endtask

  task automatic expect_irq(input string m, input int win = 400);
    int n0;
    n0 = irq_n;
    while (sq.size() > 0) @(negedge clk);
    cycles(win);
    if (irq_n == n0) fail({"no irq: ", m});
  endtask

  // message buffer model
  logic [7:0] mm [$];
  logic [3:0] p_seq = 0;      // peer tx seq (= DUT expected seq)
  // send a data frame to the DUT and wait for its ACK / NAC
  task automatic send_data(input logic [3:0] cport, input int n, input bit exp_nac = 0,
                           input logic [3:0] seq_off = 0, input int fill = -1);
    int a0, n0, t;
    logic [7:0] pay [0:15];
    a0 = n_ack; n0 = n_nac;
    if (seq_off == 0 && cport == 0 && mm.size() + n > 32) exp_nac = 1;
    cb.delete();
    cb.push_back({1'($urandom), 3'($urandom), cport});
    cb.push_back({4'($urandom), p_seq + seq_off});
    cb.push_back(8'(n));
    for (int i = 0; i < n; i++) begin
      pay[i] = fill < 0 ? 8'($urandom) : 8'(fill);
      cb.push_back(pay[i]);
    end
    frame_c();
    t = 0;
    while (n_ack == a0 && n_nac == n0 && t < 5000) begin @(negedge clk); t++; end
    if (seq_off == 0 && !exp_nac) begin
      if (n_ack != a0 + 1 || last_ack_seq != p_seq) fail("data frame not ACKed");
      if (cport == 0) for (int i = 0; i < n; i++) mm.push_back(pay[i]);
      p_seq++;
    end else if (seq_off == 4'hF) begin
      if (n_ack != a0 + 1 || last_ack_seq != p_seq - 1) fail("duplicate not re-ACKed");
    end else if (n_nac != n0 + 1 || last_ack_seq != p_seq) fail("data frame not NACed");
  endtask

  task automatic read_mbuf(input int n);
    logic [31:0] d;
    for (int i = 0; i < n; i++) begin
      rd(3'd4, d);
      if (mm.size() == 0) begin if (d[31:8] != 0) fail("mbuf read empty"); end
      else if (d !== {24'd0, mm.pop_front()}) fail($sformatf("mbuf byte %h", d));
    end
  endtask

  task automatic check_status;
    logic [31:0] d;
    rd(3'd5, d);
    if (d[13:8] != mm.size()) fail($sformatf("status msg count %0d exp %0d", d[13:8], mm.size()));
    if (d[21:18] != p_seq) fail($sformatf("status rx seq %0d exp %0d", d[21:18], p_seq));
  endtask

  task automatic hard_reset;
    @(negedge clk); rst_n = 0;
    cycles(3);
    if (tx_bit !== 1 || irq !== 0) fail("reset state");
    q0m.delete(); q1m.delete(); mm.delete(); outst = 0; d_seq = 0; p_seq = 0; cport_m = 0;
    rst_n = 1;
    cycles(2);
  endtask

  // ------------------------------------------------------------------ test
  initial begin
    logic [31:0] d;
    for (int i = 0; i < 16; i++) peer_attr[i] = 8'($urandom);
    cycles(3);
    if (tx_bit !== 1 || irq !== 0 || cpu_rdata !== 0) fail("reset state");
    rst_n = 1;
    cycles(5);

    // ---- data frames both queues, TC1 first, escapes in payloads
    set_cport(4'h3);
    push_m(0, 32'h7E9D_1234); push_m(0, $urandom); push_m(1, 32'hA5_9D_7E_00);
    set_cport(4'hC);
    push_m(1, $urandom); push_m(0, $urandom);
    quiet();
    for (int k = 0; k < 24; k++) begin
      bit tc;
      tc = 1'($urandom);
      while ((tc ? q1m.size() : q0m.size()) >= 6) @(negedge clk);
      set_cport(4'($urandom % 15));
      push_m(tc, k == 0 ? 32'hFFFF_FFFF : k == 1 ? 32'h0 : $urandom);
    end
    quiet();
    if (irq_n != 0) fail("irq during clean traffic");

    // ---- queue overflow (8 each, ninth dropped with irq)
    set_cport(4'h5);
    mute_n = 1;                                   // hold the first frame outstanding
    for (int k = 0; k < 9; k++) push_m(0, $urandom);
    expect_irq("TC0 overflow", 20);
    for (int k = 0; k < 9; k++) push_m(1, $urandom);
    expect_irq("TC1 overflow", 20);
    rd(3'd5, d);
    if (d[7:0] != 8'h88) fail($sformatf("queue counts %h", d[7:0]));
    begin                                         // push attempts every clock across the
      int r0;                                     // ACK of the held frame: only the one on
      logic [31:0] v;                             // the pop clock of the full queue lands
      r0 = n_resend;
      v = $urandom;
      while (n_resend == r0) @(negedge clk);
      while (sq.size() > 0) @(negedge clk);
      @(negedge clk); cpu_we = 1; cpu_addr = 3'd0; cpu_wdata = v;
      cycles(40);
      cpu_we = 0; cpu_addr = 3'd5;
      q0m.push_back({cport_m, v});
    end
    quiet(400000);

    // ---- NAC resend, timeout resend, wrong-seq ACK, resend budget exhausted
    nac_n = 2; push_m(0, $urandom); quiet();
    mute_n = 1; push_m(1, $urandom); quiet();
    badack_n = 1; push_m(0, $urandom); quiet();
    begin
      int n0;
      n0 = irq_n;
      mute_n = 2; nac_n = 2; push_m(0, $urandom); quiet();        // 4 sends, none ACKed
      if (irq_n != n0 + 1) fail("resend budget: no irq");
    end
    nac_n = 1; push_m(1, $urandom); push_m(0, $urandom); quiet();
    mute_n = 4; push_m(1, $urandom); quiet();                      // TC1 frame dropped
    wr(3'd5, $urandom); wr(3'd6, $urandom); wr(3'd7, $urandom);   // no such registers

    // PACP request written on the clock the ACK timer expires: it must wait
    // behind the resend, not be lost (offset found by a sweep)
    mute_n = 1; push_m(0, $urandom);
    while (!(cpu_rdata[27] && !cpu_rdata[29])) @(negedge clk);   // out && !busy
    cycles(ACK_WAIT - 2);
    wr(3'd2, 32'h0000_1101);
    quiet();
    if (peer_attr[1] != 8'h11) fail("PACP request behind a resend lost");

    // ---- PACP from the CPU
    for (int i = 0; i < 16; i++) begin
      wr(3'd2, {$urandom, 8'($urandom), 4'($urandom), 4'(i)});
      cycles(300);
      rd(3'd6, d);
      if (d[9:8] != 2'b10) fail($sformatf("SET confirm flags %b", d[9:8]));
      wr(3'd3, {$urandom, 4'(i)} );
      cycles(300);
      rd(3'd6, d);
      if (d[9:8] != 2'b01 || d[7:0] != peer_attr[i]) fail($sformatf("GET %0d: %h", i, d));
    end
    pacp_mute = 1; wr(3'd3, 32'h5); cycles(400); rd(3'd6, d);
    if (d[9:8] != 0) fail("PACP flags without a response");
    wr(3'd2, 32'h0000_9D0A); cycles(300); rd(3'd6, d);   // escaped SET value
    if (peer_attr[10] != 8'h9D) fail("SET 0x9D");
    push_m(0, $urandom); cycles(20);                     // transmitter busy:
    wr(3'd2, 32'h0000_7E0A); wr(3'd3, 32'h0000_000A);   // second request replaces the first
    cycles(400); rd(3'd6, d);
    if (d[9:8] != 2'b01) fail("replaced PACP request");

    // ---- PACP from the peer: SET / GET every attribute (two values each)
    for (int pass = 0; pass < 3; pass++)
      for (int i = 0; i < 16; i++) begin
        logic [7:0] v;
        v = pass == 0 ? 8'hFF : pass == 1 ? 8'h00 : 8'($urandom);
        ctl_frame(CC_SET, {4'($urandom), 4'(i)}, v);
        ctl_frame(CC_GET, {4'($urandom), 4'(i)}, 8'($urandom));
        while (sq.size() > 0) @(negedge clk);
        cycles(250);
      end
    if (n_setcnf < 48 || n_getrsp < 48) fail("peer PACP responses missing");
    ctl_frame(CC_GET, 8'h7E, 0); ctl_frame(CC_GET, 8'h9D, 0);   // escaped arguments
    ctl_frame(8'd9, 0, 0);                                     // unknown command: ignored
    ctl_frame(CC_GETRSP, 0, 8'h33); ctl_frame(CC_SETCNF, 0, 0); // unsolicited
    ctl_frame(CC_ACK, 8'h0C, 0); ctl_frame(CC_NAC, 0, 0);       // nothing outstanding
    cycles(2000);
    rd(3'd6, d);
    if (d[9:0] != {2'b11, 8'h33}) fail($sformatf("unsolicited PACP flags %h", d));

    // ---- data frames to the DUT: CPort0 uplink, other CPorts, dup, out of seq
    send_data(4'h0, 16); send_data(4'h0, 5);
    send_data(4'h7, 16); send_data(4'h0, 0);
    send_data(4'h0, 3, 0, 4'hF);                   // duplicate
    send_data(4'h0, 3, 1, 4'h5);                   // out of sequence
    check_status();
    read_mbuf(21);
    sym_gap = 2;
    for (int k = 0; k < 6; k++) send_data(4'h0, 1 + $urandom % 16);
    read_mbuf(mm.size());
    sym_gap = 0;
    for (int v = 0; v < 2; v++) begin            // every buffer bit both ways
      send_data(4'h0, 16, 0, 0, 255); send_data(4'h0, 16, 0, 0, 255); read_mbuf(32);
      send_data(4'h0, 16, 0, 0, 0); send_data(4'h0, 16, 0, 0, 0); read_mbuf(32);
    end
    send_data(4'h0, 16); send_data(4'h0, 16);      // buffer full
    begin
      int n0;
      n0 = irq_n;
      send_data(4'h0, 1, 1);                       // no room: NAC + irq
      cycles(5);
      if (irq_n != n0 + 1) fail("buffer overflow: no irq");
    end
    send_data(4'h9, 4);                            // other CPorts still accepted
    check_status();
    read_mbuf(33);                                 // one read past empty
    for (int k = 0; k < 40; k++) begin
      send_data(($urandom % 3) ? 4'h0 : 4'($urandom % 15), $urandom % 17);
      if (mm.size() > 20) read_mbuf(mm.size() - 4);
    end
    read_mbuf(mm.size());

    // ---- received-frame faults
    for (int k = 0; k < 8; k++) begin data_frame(0, p_seq, 4, 1); expect_irq("bad CRC"); end
    data_frame(0, p_seq, 27);                      expect_irq("32-byte frame, len > 16");
    data_frame(0, p_seq, 3, 0, 8'hE3);             expect_irq("len byte with high bits");
    data_frame(0, p_seq, 3, 0, 8'h1C);             expect_irq("len byte 28");
    data_frame(0, p_seq, 4, 0, 5);                 expect_irq("len mismatch");
    data_frame(0, p_seq, 17);                      expect_irq("len > 16");
    cb.delete(); cb.push_back(8'h01); cb.push_back(8'h02); frame_c();   expect_irq("frame < 5 bytes");
    ctl_frame(CC_GET, 1, 0, 4);                    expect_irq("control len 4");
    sym(COF); for (int i = 0; i < 40; i++) sym(8'($urandom % 100)); sym(COF);   // over-long: dropped
    sym(COF); sym(COF);                                                    // empty frame
    sym(8'h55, 1);                                 expect_irq("missing stop bit");
    sym(ESC); sym(ESC); sym(COF);                  // ESC ESC: one escaped data byte
    expect_irq("one-byte frame");
    send_data(4'h0, 2);
    read_mbuf(mm.size());

    // ---- control FIFO overflow: back-to-back GETs outpace the responses
    begin
      int n0;
      n0 = irq_n;
      for (int k = 0; k < 60; k++) ctl_frame(CC_GET, 8'($urandom), 0);
      while (sq.size() > 0) @(negedge clk);
      cycles(3000);
      if (irq_n == n0) fail("control FIFO overflow: no irq");
    end
    // data traffic both ways at once (ACKs go out while a frame is outstanding)
    mute_n = 1;
    set_cport(4'h2);
    push_m(0, $urandom); cycles(30);
    send_data(4'h0, 8);
    quiet();
    read_mbuf(mm.size());

    // ---- reset with traffic in flight
    push_m(1, $urandom); data_frame(0, p_seq, 6);
    cycles(40);
    hard_reset();
    push_m(0, 32'h1357_9BDF); send_data(4'h0, 4); quiet(); read_mbuf(4);
    cycles(200);

    if (errors == 0) $display("TEST PASSED: UniPro");
    else $display("TEST FAILED: UniPro (%0d errors)", errors);
    $finish;
  end

  initial begin
    #30ms;
    $display("TEST FAILED: UniPro (timeout)");
    $finish;
  end

endmodule
