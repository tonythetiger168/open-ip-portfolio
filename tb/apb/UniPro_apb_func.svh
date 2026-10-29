// SPDX-License-Identifier: Apache-2.0
// IP part of UniPro_apb_tb: the far UniPro device of the core TB (a symbol
// queue fed by a frame builder with faults; an independent decoder of tx_bit
// checking every DUT frame and answering ACK / NAC / nothing / GET response /
// SET confirm) with the CPU port driven through the APB words: TC0 / TC1
// pushes, CPORT, PACP SET / GET, MSG pops, STATUS and PACP reads against a
// model. Every error class sets IRQ_STATUS.ERR (masked and on the irq pin);
// PRESETN with traffic in flight.
  localparam logic [7:0] COF = 8'h7E, ESC = 8'h9D;
  localparam logic [7:0] CC_GET = 8'd0, CC_SET = 8'd1, CC_GETRSP = 8'd2, CC_SETCNF = 8'd3,
                         CC_ACK = 8'd4, CC_NAC = 8'd5;
  localparam int ACK_WAIT = 600;
  initial rx_bit = 1'b1;
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    c = c ^ {d, 8'h00};
    for (int i = 0; i < 8; i++) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction

  int irq_n = 0;
  always @(posedge PCLK) if (PRESETN && dut.c_irq) irq_n++;

  // ------------------------------------------------------------ peer TX
  logic [7:0] sq [$];         // symbols to send
  bit         sq_bad [$];     // send this symbol with a bad stop bit
  int         sym_gap = 0;    // idle bits between symbols
  always begin : peer_tx
    logic [7:0] b;
    bit bad;
    @(negedge PCLK);
    if (!PRESETN) begin rx_bit = 1; sq.delete(); sq_bad.delete(); end
    else if (sq.size() > 0) begin : one_sym
      b = sq.pop_front(); bad = sq_bad.pop_front();
      rx_bit = 0;
      for (int i = 0; i <= 8 + sym_gap; i++) begin
        @(negedge PCLK);
        if (!PRESETN) begin rx_bit = 1; disable one_sym; end
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
      @(negedge PCLK);
      if (PRESETN && tx_bit == 0) begin
        ok = 1;
        for (int i = 0; i < 9 && ok; i++) begin
          @(negedge PCLK);
          ok = PRESETN;
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
      if (!PRESETN) begin rxf.delete(); inf = 0; esc = 0; end
    end
  end

  logic [3:0] cport_m = 0;
  task automatic push(input bit tc, input logic [31:0] d);
    wr(tc ? A_TC1 : A_TC0, d);
  endtask
  // model: the push lands if the queue had room
  task automatic push_m(input bit tc, input logic [31:0] d);
    if (tc) begin if (q1m.size() < 8) q1m.push_back({cport_m, d}); end
    else    begin if (q0m.size() < 8) q0m.push_back({cport_m, d}); end
    push(tc, d);
  endtask

  task automatic set_cport(input logic [3:0] p);
    cport_m = p; wr(A_CPORT, {28'($urandom), p});
  endtask

  // queues drained (a frame dropped after four unanswered sends included)
  task automatic quiet(input int lim = 200000);
    int t;
    t = 0;
    while (t < lim && (sq.size() > 0 ||
           (q0m.size() + q1m.size() > 0 && !(outst && !acked && o_tx == 4)))) begin
      @(negedge PCLK); t++;
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
    while (sq.size() > 0) @(negedge PCLK);
    cycles(win);
    if (irq_n == n0) fail({"no dut.c_irq: ", m});
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
    while (n_ack == a0 && n_nac == n0 && t < 5000) begin @(negedge PCLK); t++; end
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
      rd(A_MSG); d = rdv;
      if (mm.size() == 0) begin if (d[31:8] != 0) fail("mbuf read empty"); end
      else if (d !== {24'd0, mm.pop_front()}) fail($sformatf("mbuf byte %h", d));
    end
  endtask

  task automatic check_status;
    logic [31:0] d;
    rd(A_STATUS); d = rdv;
    if (d[13:8] != mm.size()) fail($sformatf("status msg count %0d exp %0d", d[13:8], mm.size()));
    if (d[21:18] != p_seq) fail($sformatf("status rx seq %0d exp %0d", d[21:18], p_seq));
  endtask

  task automatic hard_reset;
    @(negedge PCLK); PRESETN = 0;
    cycles(3);
    if (tx_bit !== 1 || irq !== 0) fail("reset state");
    q0m.delete(); q1m.delete(); mm.delete(); outst = 0; d_seq = 0; p_seq = 0; cport_m = 0;
    PRESETN = 1;
    cycles(2);
    check_reset_values();
  endtask


  // ERR: one pulse latched; the w1c clears it; the pin follows the enable
  task automatic err_seen(input bit en, input string m);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
    if (irq !== en) fail({m, ": irq pin vs enable"});
    wr(A_IRQ_STATUS, 1 << IRQ_ERR);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq !== 1'b0) fail({m, ": irq pin after clear"});
  endtask
  // back-to-back STATUS reads while the link works (sees every status field move)
  task automatic spoll(input int n);
    for (int i = 0; i < n; i++) rd(A_STATUS);
  endtask
  task automatic pacp_rd(output logic [31:0] d);
    rd(A_PACP); d = rdv;
  endtask

  task automatic ip_func;
    logic [31:0] d;
    for (int i = 0; i < 16; i++) peer_attr[i] = 8'($urandom);
    rd_exp(A_FLAGS, 0);
    rd_exp(A_STATUS, 0);
    rd_exp(A_PACP, 0);
    rd_exp(A_TC0, 0);                                   // write-only words read 0
    rd_exp(A_TC1, 0); rd_exp(A_PACP_SET, 0); rd_exp(A_PACP_GET, 0); rd_exp(A_CPORT, 0);
    wr(A_STATUS, $urandom); wr(A_MSG, $urandom); wr(A_PACP, $urandom);   // ignored
    apb(1, A_TC0, $urandom, 4'h7);                      // partial: refused
    if (!rerr) fail("no PSLVERR on a partial core write");
    rd_exp(A_STATUS, 0);

    // ---- data frames both queues, TC1 first, escapes in payloads
    set_cport(4'h3);
    push_m(0, 32'h7E9D_1234); push_m(0, $urandom); push_m(1, 32'hA5_9D_7E_00);
    set_cport(4'hC);
    push_m(1, $urandom); push_m(0, $urandom);
    quiet();
    for (int k = 0; k < 8; k++) begin
      set_cport(4'($urandom % 15));
      push_m(1'($urandom), k == 0 ? 32'hFFFF_FFFF : k == 1 ? 32'h0 : $urandom);
    end
    quiet();
    if (irq_n != 0) fail("irq during clean traffic");
    rd_exp(A_IRQ_STATUS, 0);

    // ---- queue overflow: ninth push dropped with ERR (masked)
    set_cport(4'h5);
    mute_n = 1;                                   // hold the first frame outstanding
    for (int k = 0; k < 9; k++) push_m(0, $urandom);
    err_seen(0, "TC0 overflow");
    rd(A_STATUS); if (rdv[3:0] != 4'h8) fail($sformatf("TC0 count %h", rdv[7:0]));
    quiet(400000);

    // ---- NAC resend, timeout resend, resend budget exhausted (on the pin)
    wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
    nac_n = 2; push_m(0, $urandom); spoll(300); quiet();
    mute_n = 1; push_m(1, $urandom); spoll(500); quiet();
    rd_exp(A_IRQ_STATUS, 0);
    mute_n = 2; nac_n = 2; push_m(0, $urandom); spoll(900); quiet();   // 4 sends, none ACKed
    err_seen(1, "resend budget");

    // ---- PACP from the CPU
    for (int i = 0; i < 4; i++) begin
      wr(A_PACP_SET, {$urandom, 8'($urandom), 4'($urandom), 4'(i * 5)});
      spoll(100);
      pacp_rd(d);
      if (d[9:8] != 2'b10) fail($sformatf("SET confirm flags %b", d[9:8]));
      wr(A_PACP_GET, {$urandom, 4'(i * 5)});
      spoll(100);
      pacp_rd(d);
      if (d[9:8] != 2'b01 || d[7:0] != peer_attr[i * 5]) fail($sformatf("GET %0d: %h", i, d));
      pacp_rd(d);
      if (d[9:8] != 2'b00) fail("PACP read did not clear the flags");
    end
    wr(A_PACP_SET, 32'h0000_9D0A); cycles(300); pacp_rd(d);
    if (peer_attr[10] != 8'h9D) fail("SET 0x9D");
    push_m(0, $urandom); cycles(20);                     // transmitter busy: the
    wr(A_PACP_SET, 32'h0000_7E0A);                       // request waits (pending)
    rd(A_STATUS);
    if (!rdv[28]) fail("PACP request not pending behind a busy transmitter");
    wr(A_PACP_GET, 32'h0000_000A);                       // and is replaced
    cycles(400); pacp_rd(d);
    if (d[9:8] != 2'b01 || d[7:0] != 8'h9D) fail($sformatf("replaced PACP request %h", d));
    quiet();

    // ---- PACP from the peer
    for (int i = 0; i < 4; i++) begin
      ctl_frame(CC_SET, {4'($urandom), 4'(i)}, 8'($urandom));
      ctl_frame(CC_GET, {4'($urandom), 4'(i)}, 8'($urandom));
      while (sq.size() > 0) @(negedge PCLK);
      cycles(250);
    end
    if (n_setcnf < 4 || n_getrsp < 4) fail("peer PACP responses missing");

    // ---- data frames to the DUT: CPort0 uplink, other CPorts, dup, out of seq
    for (int k = 0; k < 16; k++) begin send_data(4'h0, 1); check_status(); end
    read_mbuf(16);
    for (int k = 0; k < 8; k++) begin set_cport(4'(k)); push_m(k % 2, $urandom); spoll(150); end
    quiet();
    send_data(4'h0, 16); send_data(4'h0, 5);
    send_data(4'h7, 16); send_data(4'h0, 0);
    send_data(4'h0, 3, 0, 4'hF);                   // duplicate
    send_data(4'h0, 3, 1, 4'h5);                   // out of sequence
    check_status();
    read_mbuf(21);
    for (int v = 0; v < 2; v++) begin            // every MSG data bit both ways
      send_data(4'h0, 16, 0, 0, 255); read_mbuf(16);
      send_data(4'h0, 16, 0, 0, 0); read_mbuf(16);
    end
    send_data(4'h0, 16); send_data(4'h0, 16);      // buffer full
    send_data(4'h0, 1, 1);                         // no room: NAC + ERR
    cycles(5);
    err_seen(1, "buffer overflow");
    check_status();
    read_mbuf(33);                                 // one read past empty
    wr(A_IRQ_ENABLE, 0);

    // ---- received-frame faults
    data_frame(0, p_seq, 4, 1); expect_irq("bad CRC");
    err_seen(0, "bad CRC");
    sym(8'h55, 1);              expect_irq("missing stop bit");
    err_seen(0, "missing stop bit");
    // control FIFO overflow: back-to-back GETs outpace the responses
    for (int k = 0; k < 60; k++) ctl_frame(CC_GET, 8'($urandom), 0);
    while (sq.size() > 0) rd(A_STATUS);
    spoll(1000);
    err_seen(0, "control FIFO overflow");
    send_data(4'h0, 2);
    read_mbuf(mm.size());

    // ---- PRESETN with traffic in flight
    push_m(1, $urandom); data_frame(0, p_seq, 6);
    cycles(40);
    hard_reset();
    push_m(0, 32'h1357_9BDF); send_data(4'h0, 4); quiet(); read_mbuf(4);
    cycles(200);
    // leave ERR pending (masked) for the final reset
    data_frame(0, p_seq, 4, 1); expect_irq("final bad CRC");
    rd_exp(A_IRQ_STATUS, 1 << IRQ_ERR);
  endtask
