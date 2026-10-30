// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for OBI_top (OBI 1.6 subordinate memory).
// The TB is the OBI manager: a pipelined A-channel driver that holds each
// request until gnt, random idle gaps and rready back-pressure, and a
// scoreboard that predicts every response (byte-enable merges, decode /
// protection / atop errors, AMOs, LR / SC reservation) from its own copy
// of the memory. Bus rules are checked every clock: gnt only with req,
// at most NOUT responses outstanding, a response held stable while
// rready is low, the parity outputs, and the irq pulses.
`timescale 1ns/1ps
module OBI_tb;
  localparam int NOUT = 4, IDW = 4;
  logic clk = 0, rst_n = 0;
  logic req = 0, we = 0, rready = 1, reqpar = 1, rreadypar = 0;
  logic [31:0] addr = 0, wdata = 0;
  logic [3:0] be = 0;
  logic [IDW-1:0] aid = 0;
  logic [2:0] prot = 3'b111;
  logic [5:0] atop = 0;
  wire gnt, gntpar, rvalid, rvalidpar, err, irq_dec, irq_prot, irq_atop, irq_par;
  wire [31:0] rdata;
  wire [IDW-1:0] rid;
  int errors = 0;

  OBI_top #(.NOUT(NOUT), .IDW(IDW)) dut (.*);
  always #5 clk = ~clk;

  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask

  // ------------------------------ reference ------------------------------
  logic [31:0] ref_mem [0:255];
  initial for (int i = 0; i < 256; i++) ref_mem[i] = 0;
  bit          ref_rv = 0;
  logic [7:0]  ref_ra = 0;
  logic [31:0] q_d [$];
  bit          q_e [$];
  logic [IDW-1:0] q_i [$];
  int n_acc = 0, n_rsp = 0, n_err = 0, n_amo = 0, n_sc_ok = 0, n_sc_fail = 0;
  int exp_dec = 0, exp_prot = 0, exp_atop = 0, exp_par = 0;
  int got_dec = 0, got_prot = 0, got_atop = 0, got_par = 0;

  function automatic bit is_amo(input logic [4:0] op);
    return op == 5'b00001 || op == 5'b00000 || op == 5'b00100 || op == 5'b01100 ||
           op == 5'b01000 || op == 5'b10000 || op == 5'b10100 || op == 5'b11000 ||
           op == 5'b11100;
  endfunction
  function automatic logic [31:0] amo_f(input logic [4:0] op, input logic [31:0] o, input logic [31:0] w);
    case (op)
      5'b00001: return w;
      5'b00000: return o + w;
      5'b00100: return o ^ w;
      5'b01100: return o & w;
      5'b01000: return o | w;
      5'b10000: return ($signed(o) < $signed(w)) ? o : w;
      5'b10100: return ($signed(o) < $signed(w)) ? w : o;
      5'b11000: return (o < w) ? o : w;
      default:  return (o < w) ? w : o;
    endcase
  endfunction

  // the accepting edge: predict the response and update the reference
  always @(posedge clk) if (rst_n && req && gnt) begin
    logic [7:0] i;
    logic [31:0] o, d;
    bit dec, prv, atp, bad, isa;
    i = addr[9:2]; o = ref_mem[i]; isa = atop[5];
    dec = addr[31:10] != 0;
    prv = !dec && addr[9:0] >= 10'h300 && prot[2:1] != 2'b11;
    atp = isa ? !((atop[4:0] == 5'b00010 && !we) ||
                  ((atop[4:0] == 5'b00011 || is_amo(atop[4:0])) && we))
              : atop[4:0] != 0;
    bad = dec || prv || atp;
    n_acc++;
    if (dec) exp_dec++; else if (prv) exp_prot++; else if (atp) exp_atop++;
    if (bad) begin d = 0; n_err++; end
    else if (isa && atop[4:0] == 5'b00010) begin d = o; ref_rv = 1; ref_ra = i; end
    else if (isa && atop[4:0] == 5'b00011) begin
      d = {31'h0, !(ref_rv && ref_ra == i)};
      if (ref_rv && ref_ra == i) begin ref_mem[i] = wdata; n_sc_ok++; end else n_sc_fail++;
      ref_rv = 0;
    end else if (isa) begin d = o; ref_mem[i] = amo_f(atop[4:0], o, wdata); n_amo++;
      if (ref_ra == i) ref_rv = 0;
    end else if (we) begin
      d = 0;
      for (int b = 0; b < 4; b++) if (be[b]) ref_mem[i][8*b +: 8] = wdata[8*b +: 8];
      if (ref_ra == i) ref_rv = 0;
    end else d = o;
    q_d.push_back(d); q_e.push_back(bad); q_i.push_back(aid);
  end

  // the response edge: compare with the oldest prediction
  always @(posedge clk) if (rst_n && rvalid && rready) begin
    n_rsp++;
    if (q_d.size() == 0) fail("response without a granted request");
    else begin
      if (rdata !== q_d[0] || err !== q_e[0] || rid !== q_i[0])
        fail($sformatf("response rdata=%h err=%b rid=%h, expected %h %b %h",
                       rdata, err, rid, q_d[0], q_e[0], q_i[0]));
      void'(q_d.pop_front()); void'(q_e.pop_front()); void'(q_i.pop_front());
    end
  end

  // ------------------------------ bus rules ------------------------------
  logic        p_hold = 0;
  logic [31:0] p_d; logic p_e; logic [IDW-1:0] p_i;
  bit          rr_free = 1;            // rready driven randomly
  bit          par_inj = 0;
  // a response not taken at this edge must be the same one after it
  always @(posedge clk) begin p_hold = rst_n && rvalid && !rready; p_d = rdata; p_e = err; p_i = rid; end            // parity inputs forced by the test
  always @(req or rready or par_inj) if (!par_inj) begin reqpar = ~req; rreadypar = ~rready; end
  int          rr_pct = 100;
  always @(negedge clk) if (rr_free) rready = ($urandom_range(99) < rr_pct);
  // checked 1 ns after the negedge, once the manager's inputs have settled
  always @(negedge clk) #1 begin
    if (rst_n) begin
      if (gnt && !req) fail("gnt without req");
      if (gntpar !== ~gnt || rvalidpar !== ~rvalid) fail("gntpar / rvalidpar");
      if (q_d.size() > NOUT) fail("more than NOUT responses outstanding");
      if (rvalid !== (q_d.size() != 0)) fail("rvalid does not match the outstanding count");
      if (gnt !== (req && q_d.size() < NOUT)) fail("gnt with free FIFO space");
      if (p_hold && (!rvalid || rdata !== p_d || err !== p_e || rid !== p_i))
        fail("response changed while rready was low");
      if ((^{gnt, rvalid}) === 1'bx || (rvalid && (^{rdata, err, rid}) === 1'bx))
        fail("X on a subordinate output");
    end
  end
  always @(posedge clk) if (rst_n) begin
    got_dec += irq_dec; got_prot += irq_prot; got_atop += irq_atop; got_par += irq_par;
  end
  // irq pulses one clock after the accepting edge of a failing request
  logic [2:0] irq_exp = 0;
  always @(posedge clk) begin
    if (rst_n && {irq_dec, irq_prot, irq_atop} !== irq_exp) fail($sformatf("irq_dec/prot/atop %b, expected %b", {irq_dec, irq_prot, irq_atop}, irq_exp));
    irq_exp = 0;
    if (rst_n && req && gnt) begin
      if (addr[31:10] != 0) irq_exp = 3'b100;
      else if (addr[9:0] >= 10'h300 && prot[2:1] != 2'b11) irq_exp = 3'b010;
      else if (atop[5] ? !((atop[4:0] == 5'b00010 && !we) ||
                           ((atop[4:0] == 5'b00011 || is_amo(atop[4:0])) && we))
                       : atop[4:0] != 0) irq_exp = 3'b001;
    end
  end

  // ------------------------------ manager ------------------------------
  int gap_max = 2;                     // idle clocks between requests: 0..gap_max
  task automatic a_req(input logic w, input logic [31:0] a, input logic [3:0] b,
                       input logic [31:0] d, input logic [5:0] at = 0, input logic [2:0] pr = 3'b111);
    int g;
    g = $urandom_range(gap_max);
    if (g > 0) begin
      req = 0; we = $urandom; addr = $urandom; wdata = $urandom; be = $urandom; atop = $urandom;
      repeat (g) @(negedge clk);
    end
    req = 1; we = w; addr = a; be = b; wdata = d; aid = $urandom; atop = at; prot = pr;
    @(posedge clk);
    while (!gnt) @(posedge clk);
    @(negedge clk);
    req = 0;
  endtask
  task automatic wait_idle();
    int n;
    n = 0;
    while ((q_d.size() != 0 || req) && n < 2000) begin @(negedge clk); n++; end
    if (n >= 2000) fail("responses never drained");
    @(negedge clk);
  endtask
  // single access with all responses drained, returning the response
  logic [31:0] r_d; bit r_e;
  always @(posedge clk) if (rst_n && rvalid && rready) begin r_d = rdata; r_e = err; end
  task automatic xfer(input logic w, input logic [31:0] a, input logic [3:0] b, input logic [31:0] d,
                      input logic [5:0] at = 0, input logic [2:0] pr = 3'b111);
    @(negedge clk);
    a_req(w, a, b, d, at, pr);
    wait_idle();
  endtask
  task automatic expect_rsp(input logic [31:0] d, input bit e, input string m);
    if (r_d !== d || r_e !== e) fail($sformatf("%s: rdata=%h err=%b, expected %h %b", m, r_d, r_e, d, e));
  endtask

  localparam logic [5:0] SWAP = 6'h21, ADD = 6'h20, XOR = 6'h24, AND = 6'h2C, OR = 6'h28,
                         MIN = 6'h30, MAX = 6'h34, MINU = 6'h38, MAXU = 6'h3C, LR = 6'h22, SC = 6'h23;

  task automatic random_traffic(input int n);
    for (int t = 0; t < n; t++) begin
      int r;
      logic [31:0] a;
      logic [5:0] at;
      logic w;
      r = $urandom_range(99);
      a = {22'h0, 8'($urandom_range(15)) ^ 8'hC0, 2'($urandom)};
      if (r < 8) a = $urandom;                       // mostly out of range
      if ($urandom_range(3) == 0) a[9:2] = $urandom;  // anywhere in the memory
      w = $urandom; at = 0;
      if (r >= 8 && r < 30) begin
        case ($urandom_range(10))
          0: at = SWAP; 1: at = ADD; 2: at = XOR; 3: at = AND; 4: at = OR; 5: at = MIN;
          6: at = MAX; 7: at = MINU; 8: at = MAXU; 9: at = LR; default: at = SC;
        endcase
        w = (at != LR);
        if ($urandom_range(19) == 0) at = $urandom;   // undefined codes
      end
      a_req(w, a, $urandom, $urandom, at, ($urandom_range(3) == 0) ? 3'($urandom) : 3'b111);
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    if (gnt !== 1'b0 || rvalid !== 1'b0 || irq_par !== 1'b0) fail("idle in reset");
    rst_n = 1;
    repeat (2) @(negedge clk);

    // ---- the VIP's directed checks ----
    gap_max = 0;
    xfer(0, 32'h0, 4'hF, 0);               expect_rsp(0, 0, "word 0 after reset");
    xfer(0, 32'h3FC, 4'hF, 0);             expect_rsp(0, 0, "last word");
    xfer(0, 32'h400, 4'hF, 0);             expect_rsp(0, 1, "0x400 out of range");
    xfer(1, 32'h20, 4'hF, 32'hCAFE_F00D);  expect_rsp(0, 0, "write");
    xfer(0, 32'h20, 4'hF, 0);              expect_rsp(32'hCAFE_F00D, 0, "read back");
    xfer(1, 32'h20, 4'h2, 32'h0000_AB00);
    xfer(0, 32'h20, 4'hF, 0);              expect_rsp(32'hCAFE_AB0D, 0, "byte lane 1");
    for (int b = 0; b < 16; b++) begin
      xfer(1, 32'h24, 4'(b), 32'h1111_1111 * (b + 1));
      xfer(0, 32'h24, 4'hF, 0);
    end
    xfer(1, 32'h28, 4'hF, 32'h5555_5555);  xfer(0, 32'h28, 4'hF, 0); expect_rsp(32'h5555_5555, 0, "0x55 pattern");
    xfer(1, 32'h28, 4'hF, 32'hAAAA_AAAA);  xfer(0, 32'h28, 4'hF, 0); expect_rsp(32'hAAAA_AAAA, 0, "0xAA pattern");
    xfer(1, 32'h28, 4'hF, 32'hFFFF_FFFF);  xfer(0, 32'h28, 4'hF, 0); expect_rsp(32'hFFFF_FFFF, 0, "all ones");
    xfer(1, 32'h800, 4'hF, 32'h1);         expect_rsp(0, 1, "write above 0x3FF");
    xfer(1, 32'h8000_0000, 4'hF, 32'h1);   expect_rsp(0, 1, "write at 2 GB");
    xfer(0, 32'h20, 4'hF, 0);              expect_rsp(32'hCAFE_AB0D, 0, "out-of-range write dropped");

    // ---- back-pressure: rready low, NOUT requests then no gnt ----
    begin
      int granted;
      rr_free = 0; rready = 0; granted = 0;
      @(negedge clk);
      req = 1; we = 0; addr = 32'h20; be = 4'hF; atop = 0; prot = 3'b111;
      repeat (12) begin @(posedge clk); if (gnt) granted++; @(negedge clk); end
      if (granted != NOUT) fail($sformatf("%0d grants with rready low", granted));
      rready = 1;
      repeat (3) @(negedge clk);
      req = 0;
      wait_idle();
      rr_free = 1;
    end
    // ---- full throughput: one transfer per clock with rready high ----
    begin
      int t0;
      rr_pct = 100;
      @(negedge clk);
      t0 = n_acc;
      req = 1; we = 1; be = 4'hF; atop = 0;
      for (int i = 0; i < 64; i++) begin addr = i * 4; wdata = ~(i * 32'h0404_0404); @(negedge clk); end
      req = 0;
      if (n_acc - t0 != 64) fail($sformatf("%0d of 64 back-to-back writes taken", n_acc - t0));
      wait_idle();
      req = 1; we = 0;
      for (int i = 0; i < 64; i++) begin addr = i * 4; @(negedge clk); end
      req = 0;
      wait_idle();
    end

    // ---- protection window ----
    xfer(1, 32'h300, 4'hF, 32'h5A5A_5A5A, 0, 3'b001);  expect_rsp(0, 1, "user write to 0x300");
    xfer(1, 32'h300, 4'hF, 32'h5A5A_5A5A, 0, 3'b111);  expect_rsp(0, 0, "machine write to 0x300");
    xfer(0, 32'h300, 4'hF, 0, 0, 3'b011);              expect_rsp(0, 1, "user-level 01 read of 0x300");
    xfer(0, 32'h300, 4'hF, 0, 0, 3'b101);              expect_rsp(0, 1, "level 10 read of 0x300");
    xfer(0, 32'h2FC, 4'hF, 0, 0, 3'b000);              expect_rsp(32'h0, 0, "user read below the window");
    xfer(0, 32'h300, 4'hF, 0, 0, 3'b110);              expect_rsp(32'h5A5A_5A5A, 0, "machine read of 0x300");

    // ---- atomics ----
    xfer(1, 32'h40, 4'hF, 32'h7FFF_FFFF);
    xfer(1, 32'h40, 4'hF, 32'h0000_0001, ADD);  expect_rsp(32'h7FFF_FFFF, 0, "AMOADD old");
    xfer(0, 32'h40, 4'hF, 0);                   expect_rsp(32'h8000_0000, 0, "AMOADD result");
    xfer(1, 32'h40, 4'hF, 32'h0000_0005, MIN);  expect_rsp(32'h8000_0000, 0, "AMOMIN old");
    xfer(0, 32'h40, 4'hF, 0);                   expect_rsp(32'h8000_0000, 0, "AMOMIN signed");
    xfer(1, 32'h40, 4'hF, 32'h0000_0005, MINU); xfer(0, 32'h40, 4'hF, 0); expect_rsp(5, 0, "AMOMINU");
    xfer(1, 32'h40, 4'hF, 32'hFFFF_FFFF, MAX);  xfer(0, 32'h40, 4'hF, 0); expect_rsp(5, 0, "AMOMAX signed");
    xfer(1, 32'h40, 4'hF, 32'hFFFF_FFFF, MAXU); xfer(0, 32'h40, 4'hF, 0); expect_rsp(32'hFFFF_FFFF, 0, "AMOMAXU");
    xfer(1, 32'h40, 4'hF, 32'h0F0F_0F0F, AND);  xfer(0, 32'h40, 4'hF, 0); expect_rsp(32'h0F0F_0F0F, 0, "AMOAND");
    xfer(1, 32'h40, 4'hF, 32'hF000_0000, OR);   xfer(0, 32'h40, 4'hF, 0); expect_rsp(32'hFF0F_0F0F, 0, "AMOOR");
    xfer(1, 32'h40, 4'hF, 32'hFFFF_FFFF, XOR);  xfer(0, 32'h40, 4'hF, 0); expect_rsp(32'h00F0_F0F0, 0, "AMOXOR");
    xfer(1, 32'h40, 4'hF, 32'h1234_5678, SWAP); expect_rsp(32'h00F0_F0F0, 0, "AMOSWAP old");
    xfer(0, 32'h40, 4'hF, 0);                   expect_rsp(32'h1234_5678, 0, "AMOSWAP new");
    // LR / SC
    xfer(1, 32'h44, 4'hF, 0);
    xfer(0, 32'h44, 4'hF, 0, LR);               expect_rsp(32'h0, 0, "LR");
    xfer(1, 32'h44, 4'hF, 32'hAAAA_0001, SC);   expect_rsp(32'h0, 0, "SC succeeds");
    xfer(1, 32'h44, 4'hF, 32'hAAAA_0002, SC);   expect_rsp(32'h1, 0, "second SC fails");
    xfer(0, 32'h44, 4'hF, 0);                   expect_rsp(32'hAAAA_0001, 0, "SC data");
    xfer(0, 32'h44, 4'hF, 0, LR);
    xfer(1, 32'h44, 4'h1, 32'h0000_00FF);       // a plain write breaks the reservation
    xfer(1, 32'h44, 4'hF, 32'hAAAA_0003, SC);   expect_rsp(32'h1, 0, "SC after a write fails");
    xfer(0, 32'h44, 4'hF, 0, LR);
    xfer(1, 32'h48, 4'hF, 32'h1, SC);           expect_rsp(32'h1, 0, "SC to another word fails");
    xfer(1, 32'h44, 4'hF, 32'h1, SC);           expect_rsp(32'h1, 0, "SC after an SC fails");
    xfer(0, 32'h44, 4'hF, 0, LR);
    xfer(1, 32'h44, 4'hF, 32'h1, ADD);          // an AMO breaks it too
    xfer(1, 32'h44, 4'hF, 32'h2, SC);           expect_rsp(32'h1, 0, "SC after an AMO fails");
    xfer(0, 32'h44, 4'hF, 0, LR);
    xfer(1, 32'h50, 4'hF, 32'h3);               // a write elsewhere keeps it
    xfer(1, 32'h44, 4'hF, 32'h4, SC);           expect_rsp(32'h0, 0, "SC after another word's write");
    xfer(0, 32'h44, 4'hF, 0, LR);
    xfer(1, 32'h50, 4'hF, 32'h1, ADD);          // an AMO elsewhere keeps it
    xfer(1, 32'h44, 4'hF, 32'h6, SC);           expect_rsp(32'h0, 0, "SC after another word's AMO");
    xfer(0, 32'h44, 4'hF, 0, LR);
    xfer(1, 32'h444, 4'hF, 32'h3);              // a failing write keeps it
    xfer(1, 32'h44, 4'hF, 32'h5, SC);           expect_rsp(32'h0, 0, "SC after an error");
    // unsupported atop codes
    xfer(1, 32'h40, 4'hF, 1, 6'h02);            expect_rsp(0, 1, "atop[5] = 0 with atop != 0");
    xfer(1, 32'h40, 4'hF, 1, LR);               expect_rsp(0, 1, "LR with we = 1");
    xfer(0, 32'h40, 4'hF, 0, SC);               expect_rsp(0, 1, "SC with we = 0");
    xfer(0, 32'h40, 4'hF, 0, ADD);              expect_rsp(0, 1, "AMO with we = 0");
    xfer(1, 32'h40, 4'hF, 1, 6'h3F);            expect_rsp(0, 1, "undefined AMO 0x3F");
    xfer(1, 32'h340, 4'hF, 1, ADD, 3'b001);     expect_rsp(0, 1, "user AMO in the window");
    xfer(0, 32'h40, 4'hF, 0);                   expect_rsp(32'h1234_5678, 0, "failed atomics write nothing");

    // ---- integrity: reqpar / rreadypar mismatches ----
    begin
      int p0;
      p0 = got_par;
      @(negedge clk); par_inj = 1; reqpar = req;       // reqpar == req
      @(negedge clk); reqpar = ~req; rreadypar = rready; // rreadypar == rready
      @(negedge clk); par_inj = 0;
      repeat (3) @(negedge clk);
      if (got_par - p0 != 2) fail($sformatf("irq_par pulsed %0d times for 2 parity faults", got_par - p0));
    end

    // ---- random traffic with back-pressure ----
    gap_max = 2;
    for (int r = 0; r < 4; r++) begin
      rr_pct = (r == 0) ? 100 : (r == 1) ? 60 : (r == 2) ? 25 : 90;
      random_traffic(600);
    end
    wait_idle();

    // ---- reset with responses outstanding ----
    rr_free = 0; rready = 0;
    @(negedge clk); req = 1; we = 0; addr = 32'h40; atop = 0; prot = 3'b111;
    repeat (3) @(negedge clk);
    rst_n = 0; req = 0;
    q_d.delete(); q_e.delete(); q_i.delete(); ref_rv = 0;
    repeat (2) @(negedge clk);
    if (rvalid !== 1'b0 || gnt !== 1'b0) fail("reset clears the response FIFO");
    rst_n = 1; rready = 1; rr_free = 1;
    xfer(0, 32'h40, 4'hF, 0);   expect_rsp(32'h1234_5678, 0, "memory kept through reset");
    xfer(1, 32'h44, 4'hF, 32'h1, SC);   expect_rsp(32'h1, 0, "reset clears the reservation");
    random_traffic(300);
    wait_idle();

    if (got_dec != exp_dec || got_prot != exp_prot || got_atop != exp_atop)
      fail($sformatf("irq counts dec %0d/%0d prot %0d/%0d atop %0d/%0d",
                     got_dec, exp_dec, got_prot, exp_prot, got_atop, exp_atop));
    if (n_sc_ok < 3 || n_sc_fail < 10 || n_amo < 50 || n_err < 50)
      fail($sformatf("thin traffic: sc ok %0d fail %0d amo %0d err %0d", n_sc_ok, n_sc_fail, n_amo, n_err));
    $display("OBI: %0d requests, %0d responses, %0d errors, %0d AMOs, SC %0d ok / %0d failed",
             n_acc, n_rsp, n_err, n_amo, n_sc_ok, n_sc_fail);
    if (errors == 0) $display("TEST PASSED: OBI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("TIMEOUT"); $finish;
  end
endmodule
