// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for UniPro_top -- UniPro 1.x data link layer.
// TB plays the peer UniPro device: symbol-level serial rx/tx with ESC_DL
// escape + COF framing + CRC16, PACP get/set, ACK/NAC handshake.
// Checks: reset / data frame TX with hdr+payload+CRC compare / TC1 strict
// priority over TC0 / NAC retransmit <=3 then drop+irq / CPort0 uplink to
// message buffer (payload incl. escaped 7E/9D bytes) / duplicate seq ACK
// without re-accept / out-of-seq NAC / PACP set+get both directions /
// bad-CRC frame dropped + irq / recovery after error.
`timescale 1ns/1ps
module UniPro_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [7:0] COF    = 8'h7E;
  localparam logic [7:0] ESC_DL = 8'h9D;
  localparam logic [3:0] CPORT_CTL = 4'hF;
  localparam logic [7:0] CC_GET    = 8'd0;
  localparam logic [7:0] CC_SET    = 8'd1;
  localparam logic [7:0] CC_GETRSP = 8'd2;
  localparam logic [7:0] CC_SETCNF = 8'd3;
  localparam logic [7:0] CC_ACK    = 8'd4;
  localparam logic [7:0] CC_NAC    = 8'd5;

  logic clk = 0, rst_n = 0;
  logic        rx_bit;
  logic        tx_bit;
  logic        cpu_we, cpu_re;
  logic [2:0]  cpu_addr;
  logic [31:0] cpu_wdata;
  logic [31:0] cpu_rdata;
  logic        irq;

  int errors = 0;
  reg [7:0] txc [0:31];   // frame content build buffer
  reg [7:0] rxc [0:31];   // frame content receive buffer

  UniPro_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .tx_bit(tx_bit),
    .cpu_we(cpu_we), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .irq(irq)
  );

  always #5 clk = ~clk;

  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    begin
      c = crc ^ {data, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      return c;
    end
  endfunction

  // ------------------------------------------------------------------
  // symbol layer (peer model)
  // ------------------------------------------------------------------
  task automatic send_sym(input logic [7:0] b);
    begin
      @(negedge clk); rx_bit <= 1'b0;            // start
      for (int i = 0; i < 8; i++) begin
        @(negedge clk); rx_bit <= b[i];          // LSB first
      end
      @(negedge clk); rx_bit <= 1'b1;            // stop
    end
  endtask

  task automatic recv_sym(output logic [7:0] b, output int st);
    int to;
    begin
      st = 0; to = 0; b = '0;
      while (tx_bit == 1'b1 && to < 4000) begin @(posedge clk); to++; end
      if (tx_bit == 1'b1) begin
        st = 1;
      end else begin
        for (int i = 0; i < 8; i++) begin
          @(posedge clk); b[i] = tx_bit;
        end
        @(posedge clk);                          // stop bit
      end
    end
  endtask

  // ------------------------------------------------------------------
  // frame layer
  // ------------------------------------------------------------------
  // send L2 frame; payload bytes in pay[127:120].. big-endian
  task automatic send_frame(input logic tc, input logic [3:0] cport,
                            input logic [3:0] seq, input logic [127:0] pay,
                            input int plen, input logic bad_crc);
    logic [15:0] c;
    int n;
    logic [7:0] b;
    begin
      txc[0] = {tc, 3'b000, cport};
      txc[1] = {4'b0000, seq};
      txc[2] = plen[7:0];
      for (int i = 0; i < plen; i++) txc[3+i] = pay[127 - 8*i -: 8];
      c = 16'hFFFF;
      for (int i = 0; i < 3 + plen; i++) c = crc16_byte(c, txc[i]);
      if (bad_crc) c = c ^ 16'h00FF;
      txc[3+plen] = c[15:8];
      txc[4+plen] = c[7:0];
      n = 5 + plen;
      send_sym(COF);
      for (int i = 0; i < n; i++) begin
        b = txc[i];
        if (b == COF || b == ESC_DL) begin
          send_sym(ESC_DL);
          send_sym(b ^ 8'h20);
        end else begin
          send_sym(b);
        end
      end
      send_sym(COF);
    end
  endtask

  // receive L2 frame; status: 0=ok 1=timeout 2=bad CRC 3=bad len/framing
  task automatic recv_frame(output logic tc, output logic [3:0] cport,
                            output logic [3:0] seq, output logic [127:0] pay,
                            output int plen, output int status);
    logic [7:0] b;
    logic esc;
    int st, n, to;
    logic [15:0] c;
    begin
      status = 0; pay = '0; plen = 0; n = 0; esc = 0;
      tc = 'x; cport = 'x; seq = 'x;
      // wait for COF
      to = 0;
      b = '0;
      while (b != COF && to < 20) begin
        recv_sym(b, st);
        if (st != 0) to = 99;
        to++;
      end
      if (b != COF) begin
        status = 1;
      end else begin
        // collect until next COF
        st = 0;
        while (st == 0) begin
          recv_sym(b, st);
          if (st == 0) begin
            if (esc) begin
              rxc[n] = b ^ 8'h20; n++; esc = 0;
            end else if (b == ESC_DL) begin
              esc = 1;
            end else if (b == COF) begin
              st = 2;                        // frame complete
            end else begin
              rxc[n] = b; n++;
            end
          end
        end
        if (st == 1) begin
          status = 1;
        end else if (n < 5) begin
          status = 3;
          $display("DBG recv_frame: n=%0d b0=%h b1=%h b2=%h", n, rxc[0], rxc[1], rxc[2]);
        end else begin
          c = 16'hFFFF;
          for (int i = 0; i < n; i++) c = crc16_byte(c, rxc[i]);
          if (c != 16'h0000) begin
            status = 2;
          end else if (n != 5 + rxc[2]) begin
            status = 3;
            $display("DBG recv_frame: n=%0d len=%0d b0=%h b1=%h b2=%h b3=%h b4=%h",
                     n, rxc[2], rxc[0], rxc[1], rxc[2], rxc[3], rxc[4]);
          end else begin
            tc    = rxc[0][7];
            cport = rxc[0][3:0];
            seq   = rxc[1][3:0];
            plen  = rxc[2];
            for (int i = 0; i < rxc[2]; i++) pay[127 - 8*i -: 8] = rxc[3+i];
          end
        end
      end
    end
  endtask

  // expect a data frame with given header + payload
  task automatic expect_data(input logic etc, input logic [3:0] ecport,
                             input logic [3:0] eseq, input logic [127:0] epay,
                             input string tag);
    logic tc; logic [3:0] cport, seq; logic [127:0] pay; int plen, status;
    begin
      recv_frame(tc, cport, seq, pay, plen, status);
      if (status != 0) begin
        errors++;
        $display("ERROR: UniPro %s: recv status=%0d", tag, status);
      end else if (cport == CPORT_CTL) begin
        errors++;
        $display("ERROR: UniPro %s: got control frame cmd=%0d", tag, pay[127:120]);
      end else begin
        if (tc !== etc || cport !== ecport || seq !== eseq || plen != 4) begin
          errors++;
          $display("ERROR: UniPro %s: hdr tc=%b cport=%h seq=%h len=%0d exp tc=%b cport=%h seq=%h len=4",
                   tag, tc, cport, seq, plen, etc, ecport, eseq);
        end
        if (pay !== epay) begin
          errors++;
          $display("ERROR: UniPro %s: payload=%h exp=%h", tag, pay, epay);
        end
      end
    end
  endtask

  // expect a control frame {cmd, arg1, arg2}
  task automatic expect_ctl(input logic [7:0] ecmd, earg1, earg2,
                            input string tag);
    logic tc; logic [3:0] cport, seq; logic [127:0] pay; int plen, status;
    begin
      recv_frame(tc, cport, seq, pay, plen, status);
      if (status != 0) begin
        errors++;
        $display("ERROR: UniPro %s: recv status=%0d", tag, status);
      end else if (cport != CPORT_CTL || plen != 3 ||
                   pay[127:120] !== ecmd || pay[119:112] !== earg1 ||
                   pay[111:104] !== earg2) begin
        errors++;
        $display("ERROR: UniPro %s: ctl cport=%h len=%0d cmd=%h a1=%h a2=%h exp cmd=%h a1=%h a2=%h",
                 tag, cport, plen, pay[127:120], pay[119:112], pay[111:104],
                 ecmd, earg1, earg2);
      end
    end
  endtask

  task automatic send_ack(input logic [3:0] seq);
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_ACK, 4'b0000, seq, 8'h00, 104'h0}, 3, 1'b0);
  endtask

  task automatic send_nac(input logic [3:0] seq);
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_NAC, 4'b0000, seq, 8'h00, 104'h0}, 3, 1'b0);
  endtask

  // ------------------------------------------------------------------
  // cpu port model
  // ------------------------------------------------------------------
  task automatic cpu_wr(input logic [2:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      cpu_we <= 1'b1; cpu_addr <= a; cpu_wdata <= d;
      @(negedge clk);
      cpu_we <= 1'b0;
    end
  endtask

  task automatic cpu_rd(input logic [2:0] a, output logic [31:0] d);
    begin
      @(negedge clk);
      cpu_addr <= a; cpu_re <= 1'b1;
      #1 d = cpu_rdata;              // sample before the pop/clear posedge
      @(negedge clk);
      cpu_re <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [31:0] rd;
  logic [127:0] p;
  logic irq_seen, fr_seen;

  initial begin
    rx_bit = 1'b1; cpu_we = 0; cpu_re = 0; cpu_addr = 0; cpu_wdata = 0;
    rst_n = 0; repeat (4) @(posedge clk);

    // CHECK 1: reset state
    if (tx_bit !== 1'b1 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: UniPro reset state tx_bit=%b irq=%b", tx_bit, irq);
    end
    rst_n = 1; repeat (2) @(posedge clk);
    cpu_rd(3'd5, rd);
    if (rd[13:0] !== 14'h0) begin
      errors++;
      $display("ERROR: UniPro reset status=%h exp 0", rd);
    end

    // CHECK 2: single TC0 data frame + ACK
    cpu_wr(3'd0, 32'h1111_1111);
    p = {32'h1111_1111, 96'h0};
    expect_data(1'b0, 4'h0, 4'h0, p, "tc0 data frame seq0");
    send_ack(4'h0);
    repeat (20) @(posedge clk);
    cpu_rd(3'd5, rd);
    if (rd[3:0] !== 4'h0) begin
      errors++;
      $display("ERROR: UniPro q0 not drained after ACK status=%h", rd);
    end

    // CHECK 3: TC1 strict priority over TC0
    cpu_wr(3'd0, 32'hAAAA_0001);           // A -> TC0, sent first
    p = {32'hAAAA_0001, 96'h0};
    expect_data(1'b0, 4'h0, 4'h1, p, "tc0 frame A seq1");
    cpu_wr(3'd0, 32'hBBBB_0002);           // B -> TC0 (queued behind A)
    cpu_wr(3'd1, 32'hCCCC_0003);           // C -> TC1
    send_ack(4'h1);                        // release A; C must win next slot
    p = {32'hCCCC_0003, 96'h0};
    expect_data(1'b1, 4'h0, 4'h2, p, "tc1 frame C seq2 (priority)");
    send_ack(4'h2);
    p = {32'hBBBB_0002, 96'h0};
    expect_data(1'b0, 4'h0, 4'h3, p, "tc0 frame B seq3");
    send_ack(4'h3);
    repeat (20) @(posedge clk);

    // CHECK 4: NAC retransmit <=3 then drop + irq
    cpu_wr(3'd0, 32'hDDDD_0004);
    p = {32'hDDDD_0004, 96'h0};
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D seq4 orig");
    send_nac(4'h4);
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D retransmit 1");
    send_nac(4'h4);
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D retransmit 2");
    send_nac(4'h4);
    expect_data(1'b0, 4'h0, 4'h4, p, "frame D retransmit 3");
    // 4th NAC: budget exhausted -> drop + irq, no more retransmission
    irq_seen = 0; fr_seen = 0;
    fork
      begin
        repeat (1500) begin
          @(posedge clk);
          if (irq) irq_seen = 1;
          if (dut.ser_busy) fr_seen = 1;
        end
      end
      send_nac(4'h4);
    join
    if (!irq_seen) begin
      errors++;
      $display("ERROR: UniPro NAC exhausted: no irq pulse");
    end
    if (fr_seen) begin
      errors++;
      $display("ERROR: UniPro NAC exhausted: frame retransmitted >3 times");
    end
    cpu_rd(3'd5, rd);
    if (rd[3:0] !== 4'h0) begin
      errors++;
      $display("ERROR: UniPro dropped frame still queued status=%h", rd);
    end

    // CHECK 5: CPort0 uplink incl. escaped bytes (7E, 9D), duplicate, out-of-seq
    p = {8'h7E, 8'h9D, 8'h00, 8'hFF, 96'h0};
    send_frame(1'b0, 4'h0, 4'h0, p, 4, 1'b0);   // peer seq0 -> DUT exp_seq0
    expect_ctl(CC_ACK, 8'h00, 8'h00, "uplink ACK seq0");
    cpu_rd(3'd5, rd);
    if (rd[13:8] !== 6'd4) begin
      errors++;
      $display("ERROR: UniPro msg count=%0d exp 4", rd[13:8]);
    end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h7E) begin errors++; $display("ERROR: UniPro msg[0]=%h exp 7E", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h9D) begin errors++; $display("ERROR: UniPro msg[1]=%h exp 9D", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h00) begin errors++; $display("ERROR: UniPro msg[2]=%h exp 00", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'hFF) begin errors++; $display("ERROR: UniPro msg[3]=%h exp FF", rd[7:0]); end
    // duplicate seq0: ACK again, no re-accept
    send_frame(1'b0, 4'h0, 4'h0, p, 4, 1'b0);
    expect_ctl(CC_ACK, 8'h00, 8'h00, "duplicate ACK seq0");
    cpu_rd(3'd5, rd);
    if (rd[13:8] !== 6'd0) begin
      errors++;
      $display("ERROR: UniPro duplicate accepted msg_cnt=%0d", rd[13:8]);
    end
    // out-of-sequence: expect NAC with exp_seq=1
    p = {32'h5555_0005, 96'h0};
    send_frame(1'b0, 4'h0, 4'h5, p, 4, 1'b0);
    expect_ctl(CC_NAC, 8'h01, 8'h00, "out-of-seq NAC");

    // CHECK 6: PACP both directions
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_SET, 8'h03, 8'h5A, 104'h0}, 3, 1'b0);
    expect_ctl(CC_SETCNF, 8'h03, 8'h00, "PACP set cnf");
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_GET, 8'h03, 8'h00, 104'h0}, 3, 1'b0);
    expect_ctl(CC_GETRSP, 8'h03, 8'h5A, "PACP get rsp");
    // DUT-initiated: cpu PACP SET idx=5 val=A5
    cpu_wr(3'd2, {16'h0, 8'hA5, 4'h0, 4'h5});
    expect_ctl(CC_SET, 8'h05, 8'hA5, "PACP cpu set req");
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_SETCNF, 8'h05, 8'h00, 104'h0}, 3, 1'b0);
    repeat (30) @(posedge clk);
    cpu_rd(3'd6, rd);
    if (rd[9] !== 1'b1) begin
      errors++;
      $display("ERROR: UniPro pacp_cnf not set rd=%h", rd);
    end
    // DUT-initiated: cpu PACP GET idx=5
    cpu_wr(3'd3, {28'h0, 4'h5});
    expect_ctl(CC_GET, 8'h05, 8'h00, "PACP cpu get req");
    send_frame(1'b0, CPORT_CTL, 4'h0, {CC_GETRSP, 8'h05, 8'hA5, 104'h0}, 3, 1'b0);
    repeat (30) @(posedge clk);
    cpu_rd(3'd6, rd);
    if (rd[8] !== 1'b1 || rd[7:0] !== 8'hA5) begin
      errors++;
      $display("ERROR: UniPro pacp_rsp rd=%h exp valid+A5", rd);
    end

    // CHECK 7: error injection - bad CRC data frame dropped + irq
    irq_seen = 0; fr_seen = 0;
    fork
      begin
        repeat (1200) begin
          @(posedge clk);
          if (irq) irq_seen = 1;
          if (dut.ser_busy) fr_seen = 1;
        end
      end
      begin
        p = {32'hBAD0_0001, 96'h0};
        send_frame(1'b0, 4'h0, 4'h1, p, 4, 1'b1);   // corrupted CRC
      end
    join
    if (!irq_seen) begin
      errors++;
      $display("ERROR: UniPro bad-CRC frame: no irq pulse");
    end
    if (fr_seen) begin
      errors++;
      $display("ERROR: UniPro bad-CRC frame: DUT responded");
    end

    // recovery: valid seq1 frame still accepted
    p = {32'h600D_0001, 96'h0};
    send_frame(1'b0, 4'h0, 4'h1, p, 4, 1'b0);
    expect_ctl(CC_ACK, 8'h01, 8'h00, "recovery ACK seq1");
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h60) begin errors++; $display("ERROR: UniPro recovery msg[0]=%h exp 60", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h0D) begin errors++; $display("ERROR: UniPro recovery msg[1]=%h exp 0D", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h00) begin errors++; $display("ERROR: UniPro recovery msg[2]=%h exp 00", rd[7:0]); end
    cpu_rd(3'd4, rd); if (rd[7:0] !== 8'h01) begin errors++; $display("ERROR: UniPro recovery msg[3]=%h exp 01", rd[7:0]); end

    repeat (20) @(posedge clk);
    if (errors == 0) $display("TEST PASSED: UniPro");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
