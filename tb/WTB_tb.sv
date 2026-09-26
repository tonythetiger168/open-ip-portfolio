// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for WTB_top -- IEEE 802.4 style token-bus station.
// TB plays the predecessor and successor stations on the serial bus:
//   injects token/data/claim frames to rx_bit, decodes frames from tx_bit.
// Checks: reset / token pass-through (empty FIFO) / data frame TX from FIFO
//         with payload+CRC compare (2 token rounds, holding window) /
//         bad-CRC frame dropped + irq / token for other station ignored /
//         claim_token contention after bus idle timeout.
`timescale 1ns/1ps
module WTB_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [7:0] MY = 8'h11;   // DUT station address
  localparam logic [7:0] TB = 8'h00;   // TB predecessor address
  localparam logic [7:0] NS = 8'h22;   // next-station address (programmed)
  localparam logic [7:0] DA = 8'h33;   // data-frame destination (programmed)

  logic clk = 0, rst_n = 0;
  logic        rx_bit;
  logic        tx_bit, tx_en;
  logic [7:0]  my_addr;
  logic        cpu_we;
  logic [1:0]  cpu_addr;
  logic [31:0] cpu_wdata;
  logic [3:0]  fifo_count;
  logic        token_held;
  logic        irq;

  int errors = 0;
  reg [7:0] rxbuf [0:31];   // frame decode buffer (module scope: iverilog)

  WTB_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .tx_bit(tx_bit), .tx_en(tx_en),
    .my_addr(my_addr),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .fifo_count(fifo_count), .token_held(token_held), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSMs probed: RX engine (9) + TX engine (12) + station (5) = 26 states.
  // =====================================================================
  localparam int WTB_FSM_TOTAL = 26;
  logic [8:0]  rx_seen = '0;
  logic [11:0] tx_seen = '0;
  logic [4:0]  st_seen = '0;
  wire  [3:0] rx_st = dut.rstate;
  wire  [3:0] tx_st = dut.tstate;
  wire  [2:0] st_st = dut.sstate;

  int sva_total = 0, sva_fail = 0;
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors = errors + 1;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: dual-edge probe (scheduler failure mode #3 mitigation)
  always @(posedge clk or negedge clk) begin
    if (rx_st < 4'd9)  rx_seen[rx_st] <= 1'b1;
    if (tx_st < 4'd12) tx_seen[tx_st] <= 1'b1;
    if (st_st < 3'd5)  st_seen[st_st] <= 1'b1;
  end

  // sticky flags for CRV frame-less checks
  logic irq_seen_c = 1'b0, tx_seen_c = 1'b0;
  always @(posedge clk) begin
    if (irq)   irq_seen_c <= 1'b1;
    if (tx_en) tx_seen_c  <= 1'b1;
  end

  // output-invariant assertion suite (negedge-sampled, NBA settled)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      if (!rst_n_q)
        sva_check(tx_en === 1'b0 && irq === 1'b0 && token_held === 1'b0 &&
                  fifo_count === 4'd0, "A1 reset: outputs quiescent");
    end else begin
      // A2: irq output is exactly the OR of its three pulse sources
      sva_check(irq === (dut.rx_bad | dut.cfg_irq | dut.tok_irq),
                "A2 irq == rx_bad|cfg_irq|tok_irq");
      // A3: token_held reflects HOLD/PASS exactly
      sva_check(token_held === (st_st == 3'd1 || st_st == 3'd4),
                "A3 token_held == HOLD|PASS");
      // A4: TX FIFO occupancy bounded by its 8 entries
      sva_check(fifo_count <= 4'd8, "A4 fifo_count <= 8");
      // A5: a busy serializer always drives tx_en (tx_en may legally tail
      // one cycle into T_IDLE after the last bit, so the check is this way)
      sva_check((tx_st == 4'd0) || (tx_en === 1'b1), "A5 busy serializer -> tx_en");
      // A6: station state holds a legal encoding (5 of 8 used)
      sva_check(st_st <= 3'd4, "A6 station state legal");
    end
    rst_n_q <= rst_n;
  end
`endif

  // ------------------------------------------------------------------
  // CRC16 (poly 0x1021, init 0xFFFF), byte-wise -- same as DUT
  // ------------------------------------------------------------------
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
  // serial bus driver (predecessor/successor model)
  // ------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      @(negedge clk);
      rx_bit <= b[i];
    end
  endtask

  // pay: payload bytes, first byte in pay[127:120]
  task automatic send_frame(input logic [7:0] fc, da, sa,
                            input int plen, input logic [127:0] pay,
                            input logic bad_crc, input logic bad_ed);
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      c = crc16_byte(c, fc);
      c = crc16_byte(c, da);
      c = crc16_byte(c, sa);
      c = crc16_byte(c, plen[7:0]);
      for (int i = 0; i < plen; i++)
        c = crc16_byte(c, pay[127 - 8*i -: 8]);
      if (bad_crc) c = c ^ 16'h00FF;
      send_byte(8'h55);
      send_byte(8'h55);
      send_byte(8'hD5);
      send_byte(fc);
      send_byte(da);
      send_byte(sa);
      send_byte(plen[7:0]);
      for (int i = 0; i < plen; i++) send_byte(pay[127 - 8*i -: 8]);
      send_byte(c[15:8]);
      send_byte(c[7:0]);
      send_byte(bad_ed ? 8'h00 : 8'hD4);
      @(negedge clk); rx_bit <= 1'b1;   // idle bus
    end
  endtask

  // ------------------------------------------------------------------
  // frame decoder on tx_bit; status: 0=ok 1=timeout 2=framing 3=crc
  // ------------------------------------------------------------------
  task automatic recv_frame(output logic [7:0] fc, da, sa, len,
                            output logic [127:0] pay, output int status);
    logic [7:0] cur;
    int n, nb, to;
    logic [15:0] c;
    begin
      status = 0; n = 0; nb = 0; to = 0; cur = 0; pay = '0;
      fc = 'x; da = 'x; sa = 'x; len = 'x;
      // wait for tx_en rise; first data bit is valid in the detection cycle
      while (!tx_en && to < 5000) begin @(posedge clk); to++; end
      if (!tx_en) begin
        status = 1;
      end else begin
        cur = {7'b0, tx_bit};   // bit0 of preamble
        nb  = 1;
        // sample remaining bits at posedge while tx_en
        while (tx_en) begin
          @(posedge clk);
          if (tx_en) begin
            cur = {cur[6:0], tx_bit};
            nb++;
            if (nb == 8) begin
              rxbuf[n] = cur;
              n++;
              nb = 0;
              cur = 0;
            end
          end
        end
        // parse
        if (n < 10 || rxbuf[0] != 8'h55 || rxbuf[1] != 8'h55 ||
            rxbuf[2] != 8'hD5 || rxbuf[n-1] != 8'hD4 || n != 10 + rxbuf[6]) begin
          status = 2;
          $display("ERROR: WTB rx frame framing n=%0d b0=%h b1=%h b2=%h ed=%h",
                   n, rxbuf[0], rxbuf[1], rxbuf[2], rxbuf[n-1]);
        end else begin
          fc  = rxbuf[3];
          da  = rxbuf[4];
          sa  = rxbuf[5];
          len = rxbuf[6];
          for (int i = 0; i < len; i++) pay[127 - 8*i -: 8] = rxbuf[7+i];
          c = 16'hFFFF;
          for (int i = 3; i < 7 + len; i++) c = crc16_byte(c, rxbuf[i]);
          if (c != {rxbuf[7+len], rxbuf[8+len]}) begin
            status = 3;
            $display("ERROR: WTB rx frame CRC got=%h exp=%h",
                     {rxbuf[7+len], rxbuf[8+len]}, c);
          end
        end
      end
    end
  endtask

  task automatic cpu_wr(input logic [1:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      cpu_we <= 1'b1; cpu_addr <= a; cpu_wdata <= d;
      @(negedge clk);
      cpu_we <= 1'b0;
    end
  endtask

  // expect a specific frame; on mismatch count errors
  task automatic expect_frame(input logic [7:0] efc, eda, esa, elen,
                              input logic [127:0] epay, input string tag);
    logic [7:0] fc, da, sa, len;
    logic [127:0] pay;
    int status;
    begin
      recv_frame(fc, da, sa, len, pay, status);
      if (status != 0) begin
        errors++;
        $display("ERROR: WTB %s: no/bad frame status=%0d", tag, status);
      end else begin
        if (fc !== efc || da !== eda || sa !== esa || len !== elen) begin
          errors++;
          $display("ERROR: WTB %s: hdr fc=%h da=%h sa=%h len=%h exp fc=%h da=%h sa=%h len=%h",
                   tag, fc, da, sa, len, efc, eda, esa, elen);
        end
        if (elen > 0 && pay !== epay) begin
          errors++;
          $display("ERROR: WTB %s: payload=%h exp=%h", tag, pay, epay);
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [127:0] p;

  initial begin
    rx_bit = 1'b1; my_addr = MY;
    cpu_we = 0; cpu_addr = 0; cpu_wdata = 0;
    rst_n = 0; repeat (4) @(posedge clk);

    // CHECK 1: reset state
    if (tx_en !== 1'b0 || irq !== 1'b0 || token_held !== 1'b0 ||
        fifo_count !== 4'd0) begin
      errors++;
      $display("ERROR: WTB reset state tx_en=%b irq=%b held=%b cnt=%0d",
               tx_en, irq, token_held, fifo_count);
    end
    rst_n = 1; repeat (2) @(posedge clk);

    // configure NS + data DA
    cpu_wr(2'd1, 32'h22);
    cpu_wr(2'd2, 32'h33);

    // CHECK 2: empty FIFO - token in, token passed to NS
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    expect_frame(8'h01, NS, MY, 8'd0, '0, "empty token pass");

    // CHECK 3: queue 3 words -> 2 token rounds (holding window <=200 clk)
    cpu_wr(2'd0, 32'hAABB_CC01);
    cpu_wr(2'd0, 32'hAABB_CC02);
    cpu_wr(2'd0, 32'hAABB_CC03);
    if (fifo_count !== 4'd3) begin
      errors++;
      $display("ERROR: WTB fifo_count=%0d exp 3", fifo_count);
    end
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    p = {32'hAABB_CC01, 96'h0};
    expect_frame(8'h02, DA, MY, 8'd4, p, "data frame 1");
    p = {32'hAABB_CC02, 96'h0};
    expect_frame(8'h02, DA, MY, 8'd4, p, "data frame 2");
    expect_frame(8'h01, NS, MY, 8'd0, '0, "token after window");
    // second round delivers remaining word
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    p = {32'hAABB_CC03, 96'h0};
    expect_frame(8'h02, DA, MY, 8'd4, p, "data frame 3");
    expect_frame(8'h01, NS, MY, 8'd0, '0, "token after round 2");
    if (fifo_count !== 4'd0) begin
      errors++;
      $display("ERROR: WTB fifo not empty after rounds cnt=%0d", fifo_count);
    end

    // CHECK 4: error injection - corrupted CRC token must be dropped + irq
    begin
      logic irq_seen, tx_seen;
      irq_seen = 0; tx_seen = 0;
      fork
        begin
          repeat (500) begin
            @(posedge clk);
            if (irq)   irq_seen = 1;
            if (tx_en) tx_seen = 1;
          end
        end
        begin
          send_frame(8'h01, MY, TB, 0, '0, 1'b1, 1'b0);  // bad CRC
        end
      join
      if (!irq_seen) begin
        errors++;
        $display("ERROR: WTB bad-CRC frame: no irq pulse");
      end
      if (tx_seen) begin
        errors++;
        $display("ERROR: WTB bad-CRC frame: station responded to bad token");
      end
    end

    // CHECK 5: token for another station is ignored
    begin
      logic tx_seen;
      tx_seen = 0;
      fork
        begin
          repeat (300) begin
            @(posedge clk);
            if (tx_en) tx_seen = 1;
          end
        end
        begin
          send_frame(8'h01, 8'h55, TB, 0, '0, 1'b0, 1'b0);
        end
      join
      if (tx_seen) begin
        errors++;
        $display("ERROR: WTB token for other station was accepted");
      end
    end

    // recovery: valid token still works
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    expect_frame(8'h01, NS, MY, 8'd0, '0, "token pass after bad frames");

    // CHECK 6: claim_token contention after bus idle timeout
    cpu_wr(2'd3, 32'h1);   // claim_en
    expect_frame(8'h00, 8'hFF, MY, 8'd0, '0, "claim_token");
    // no contender replies -> self-elect -> empty FIFO -> pass token to NS
    expect_frame(8'h01, NS, MY, 8'd0, '0, "self-elect token pass");
    cpu_wr(2'd3, 32'h0);   // stop claiming

    repeat (10) @(posedge clk);
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // Random frames through the token-bus station, each self-checked:
    // data rounds (FIFO payload compare), token pass-through, bad-CRC/bad-ED/
    // overlong drops + irq, other-station tokens ignored, NS/DA reconfig,
    // random RX data frames (valid/corrupt), FIFO overflow, claim cycles.
    begin : crv_phase
      int n_data=0,n_pass=0,n_bad=0,n_ign=0,n_cfg=0,n_ovf=0,n_rx=0,n_claim=0;
      int nw, pl_v;
      logic [31:0] wq [0:1];
      logic [31:0] ovfw [0:7];
      logic [127:0] pp;
      logic [7:0]  ns_v, da_v, sa_v;

      // (a) random data rounds (1-2 words; hold window fits <=2 frames/token)
      for (int t=0; t<20; t++) begin
        nw = 1 + $urandom_range(1, 0);
        for (int i=0; i<nw; i++) begin wq[i]=$urandom; cpu_wr(2'd0, wq[i]); end
        send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
        pp={wq[0],96'h0}; expect_frame(8'h02,DA,MY,8'd4,pp,"crv d0"); n_data++;
        if (nw==2) begin pp={wq[1],96'h0}; expect_frame(8'h02,DA,MY,8'd4,pp,"crv d1"); n_data++; end
        expect_frame(8'h01,NS,MY,8'd0,'0,"crv pass"); n_pass++;
        if (fifo_count !== 4'd0) begin
          errors++; $display("ERROR: CRV fifo not drained t=%0d cnt=%0d", t, fifo_count);
        end
      end

      // (b) random bad frames -> irq (bad CRC / bad ED / overlong)
      for (int t=0; t<12; t++) begin
        sa_v = $urandom_range(255, 0);
        irq_seen_c = 1'b0;
        case (t % 3)
          0: send_frame(8'h01, MY, sa_v, 0, '0, 1'b1, 1'b0);   // bad CRC
          1: send_frame(8'h01, MY, sa_v, 0, '0, 1'b0, 1'b1);   // bad ED
          default: begin                                       // overlong (LEN>16)
            send_byte(8'h55); send_byte(8'h55); send_byte(8'hD5);
            send_byte(8'h02); send_byte(MY); send_byte(sa_v);
            send_byte(8'd17 + $urandom_range(238, 0));   // LEN 17..255 (overlong)
            repeat (4) send_byte($urandom_range(255, 0));
            @(negedge clk); rx_bit <= 1'b1;
          end
        endcase
        repeat (6) @(posedge clk);
        if (!irq_seen_c) begin
          errors++; $display("ERROR: CRV no irq on bad frame t=%0d", t);
        end
        n_bad++;
      end

      // (c) token for a random other station -> ignored (no tx)
      for (int t=0; t<8; t++) begin
        da_v = $urandom_range(255, 0);
        if (da_v == MY) da_v = MY ^ 8'hFF;
        tx_seen_c = 1'b0;
        send_frame(8'h01, da_v, TB, 0, '0, 1'b0, 1'b0);
        repeat (40) @(posedge clk);
        if (tx_seen_c) begin
          errors++; $display("ERROR: CRV token for %h accepted", da_v);
        end
        n_ign++;
      end

      // (d) random NS/DA reconfig -> token passed to the new NS (empty FIFO)
      for (int t=0; t<6; t++) begin
        ns_v = $urandom_range(255, 0);
        da_v = $urandom_range(255, 0);
        cpu_wr(2'd1, {24'h0, ns_v});
        cpu_wr(2'd2, {24'h0, da_v});
        send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
        expect_frame(8'h01, ns_v, MY, 8'd0, '0, "crv ns pass");
        n_cfg++;
      end
      cpu_wr(2'd1, 32'h22); cpu_wr(2'd2, 32'h33);          // restore NS/DA

      // (e) random data frames TO the DUT (random len/payload): valid -> no
      // irq, corrupted -> irq. Exercises the RX byte engine + CRC checker.
      for (int t=0; t<20; t++) begin
        pl_v = $urandom_range(16, 0);
        sa_v = $urandom_range(255, 0);
        for (int i=0; i<16; i++) pp[127-8*i -: 8] = $urandom_range(255, 0);
        irq_seen_c = 1'b0;
        if (t % 2 == 0) begin
          send_frame(8'h02, MY, sa_v, pl_v, pp, 1'b0, 1'b0);   // valid
          repeat (6) @(posedge clk);
          if (irq_seen_c) begin
            errors++; $display("ERROR: CRV valid data raised irq t=%0d", t);
          end
        end else begin
          send_frame(8'h02, MY, sa_v, pl_v, pp, 1'b1, 1'b0);   // bad CRC
          repeat (6) @(posedge clk);
          if (!irq_seen_c) begin
            errors++; $display("ERROR: CRV bad data no irq t=%0d", t);
          end
        end
        n_rx++;
      end

      // (f) FIFO overflow: 9th push into the full 8-entry FIFO -> cfg_irq,
      // then drain in FIFO order (2 frames per token round).
      for (int i=0; i<8; i++) begin ovfw[i]=$urandom; cpu_wr(2'd0, ovfw[i]); end
      if (fifo_count !== 4'd8) begin
        errors++; $display("ERROR: CRV fifo not full cnt=%0d", fifo_count);
      end
      irq_seen_c = 1'b0;
      cpu_wr(2'd0, $urandom);
      repeat (4) @(posedge clk);
      if (!irq_seen_c) begin
        errors++; $display("ERROR: CRV no irq on fifo overflow");
      end
      n_ovf++;
      for (int r=0; r<4; r++) begin
        send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
        pp={ovfw[2*r],96'h0};   expect_frame(8'h02,DA,MY,8'd4,pp,"ovf da");
        pp={ovfw[2*r+1],96'h0}; expect_frame(8'h02,DA,MY,8'd4,pp,"ovf db");
        expect_frame(8'h01,NS,MY,8'd0,'0,"ovf pass");
      end

      // (g) claim_token cycles (no contender -> self-elect -> pass to NS)
      for (int t=0; t<3; t++) begin
        // bus poke resets the idle timer so the station waits IDLE_TO before
        // claiming; recv_frame is then guaranteed to be waiting in time.
        send_frame(8'h01, 8'h77, TB, 0, '0, 1'b0, 1'b0);   // other station: ignored
        cpu_wr(2'd3, 32'h1);
        expect_frame(8'h00, 8'hFF, MY, 8'd0, '0, "crv claim");
        expect_frame(8'h01, NS, MY, 8'd0, '0, "crv claim pass");
        cpu_wr(2'd3, 32'h0);
        n_claim++;
      end
      // (h) claim contention: a lower-address claim during CLAIM_WAIT wins
      // and the station backs off to LISTEN (no self-elect token).
      send_frame(8'h01, 8'h77, TB, 0, '0, 1'b0, 1'b0);   // poke: reset idle timer
      cpu_wr(2'd3, 32'h1);
      expect_frame(8'h00, 8'hFF, MY, 8'd0, '0, "crv claim3");
      send_frame(8'h00, 8'hFF, 8'h05, 0, '0, 1'b0, 1'b0);  // contender sa=5 < MY
      cpu_wr(2'd3, 32'h0);
      tx_seen_c = 1'b0;
      repeat (200) @(posedge clk);
      if (tx_seen_c) begin
        errors++; $display("ERROR: CRV claim contention not backed off");
      end
      n_claim++;

      // (i) random frame-control bytes (FC 3..255): decoded but not acted on,
      // toggles the rfc/rx_fc field high bits. No response, no irq.
      for (int t=0; t<10; t++) begin
        logic [7:0] fcv;
        fcv = 8'd3 + $urandom_range(252, 0);
        if (fcv == 8'h01 || fcv == 8'h02) fcv = 8'hF0;
        irq_seen_c = 1'b0;
        send_frame(fcv, MY, TB, 0, '0, 1'b0, 1'b0);
        repeat (6) @(posedge clk);
        if (irq_seen_c) begin
          errors++; $display("ERROR: CRV random FC %h raised irq", fcv);
        end
      end

      // (j) idle soak: with claiming disabled, let the bus-idle counter run
      // up to saturation to toggle its upper bits.
      repeat (70000) @(posedge clk);

      // (k) FIFO bit-toggle exercise: fill+drain with complementary patterns
      // so every FIFO entry/bit toggles; plus a max-length overlong (rlen[7]).
      for (int cyc=0; cyc<2; cyc++) begin
        for (int i=0; i<8; i++)
          cpu_wr(2'd0, cyc ? 32'h5555_5555 : 32'hAAAA_AAAA);
        for (int r=0; r<4; r++) begin
          send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
          pp = {cyc ? 32'h5555_5555 : 32'hAAAA_AAAA, 96'h0};
          expect_frame(8'h02, DA, MY, 8'd4, pp, "fifo tgl a");
          expect_frame(8'h02, DA, MY, 8'd4, pp, "fifo tgl b");
          expect_frame(8'h01, NS, MY, 8'd0, '0, "fifo tgl pass");
        end
      end
      // max-length overlong frame -> rlen[7]
      irq_seen_c = 1'b0;
      send_byte(8'h55); send_byte(8'h55); send_byte(8'hD5);
      send_byte(8'h02); send_byte(MY); send_byte(8'h01); send_byte(8'hFF);
      repeat (4) send_byte($urandom_range(255, 0));
      @(negedge clk); rx_bit <= 1'b1;
      repeat (6) @(posedge clk);
      if (!irq_seen_c) begin errors++; $display("ERROR: CRV no irq on max overlong"); end
            $display("CRV: data=%0d pass=%0d bad=%0d ign=%0d cfg=%0d rx=%0d ovf=%0d claim=%0d",
               n_data, n_pass, n_bad, n_ign, n_cfg, n_rx, n_ovf, n_claim);
    end
`endif

    if (errors == 0) $display("TEST PASSED: WTB");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s=0; s<9;  s++) visited += rx_seen[s];
      for (int s=0; s<12; s++) visited += tx_seen[s];
      for (int s=0; s<5;  s++) visited += st_seen[s];
      $display("FSM_COV: %0d/%0d", visited, WTB_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard
  initial begin
    repeat (8000) #1000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #2_000_000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif
endmodule
