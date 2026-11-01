// SPDX-License-Identifier: Apache-2.0
// SPDM_tb: self-checking testbench for SPDM_top. Runs the records of
// tb/SPDM_vec.hex (scripts/spdm/gen_vec.py, from the SPDM 1.2 reference
// model scripts/spdm/spdm_ref.py with the FIPS 204 ML-DSA model): store
// writes, KeyGen and public-key readout, and SPDM requests whose responses
// are compared byte for byte (signatures included: the random words are
// given). Requests are sent with random gaps, responses read with random
// back-pressure, random words given with random gaps. clr is pulsed while
// a request is received, while a signature is computed, while a response
// is sent and while KeyGen runs. Then directed cases: key commands while
// busy, a request held off by a command, reset in the middle of a request.
`timescale 1ns/1ps
module SPDM_tb;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  localparam int NM = 4;
  localparam int CC_AW = 14;

  logic [7:0]       ct_exp = '0;
  logic [31:0]      asym_id = '0;
  logic [1:0]       pset = '0;
  logic [CC_AW:0]   cc_len = '0;
  logic [NM-1:0]    m_en = '0, m_tcb = '0;
  logic [NM*8-1:0]  m_type = '0;
  logic             st_we = 1'b0, st_sel = 1'b0;
  logic [CC_AW-3:0] st_addr = '0;
  logic [31:0]      st_data = '0;
  logic             kg_start = 1'b0, kg_sel = 1'b0, sl_valid = 1'b0, pk_open = 1'b0, clr = 1'b0;
  logic [255:0]     seed = '0, sl_seed = '0;
  logic             pk_valid, pk_last, pk_ready = 1'b0;
  logic [31:0]      pk_data;
  logic             rn_valid = 1'b0, rn_ready;
  logic [31:0]      rn_data = '0;
  logic             rq_valid = 1'b0, rq_last = 1'b0, rq_ready;
  logic [7:0]       rq_data = '0;
  logic             rs_valid, rs_last, rs_ready = 1'b0;
  logic [7:0]       rs_data;
  logic             busy, key_ok, rsp_done, rsp_err, kg_done, cmd_err;
  logic [1:0]       conn, key_pset;
  logic [7:0]       err_code;

  SPDM_top #(.NM(NM), .CC_AW(CC_AW)) u_dut (.*);

  int errors = 0, ncase = 0;
  task automatic fail(input string s);
    errors++;
    if (errors < 20) $display("ERROR: %s @%0t", s, $time);
  endtask

  // pulse counters, sampled half a clock after the pulses rise
  int n_done = 0, n_err = 0, n_kg = 0, n_cmderr = 0;
  always @(negedge clk) begin
    if (rsp_done) n_done++;
    if (rsp_done && rsp_err) n_err++;
    if (kg_done) n_kg++;
    if (cmd_err) n_cmderr++;
  end

  // random words: a queue filled per request, given with random gaps
  logic [31:0] rnq [0:63];
  int rn_h = 0, rn_t = 0;
  int rn_gap = 3;
  initial forever begin
    @(negedge clk);
    if (rn_h != rn_t && $urandom_range(0, rn_gap) == 0) begin
      rn_valid = 1'b1; rn_data = rnq[rn_h % 64];
    end
    #1;
    if (rn_valid && rn_ready) begin
      @(posedge clk);
      rn_h++;
      #1 rn_valid = 1'b0;
    end else rn_valid = 1'b0;
  end

  localparam int NV = 20000;
  logic [31:0] vec [0:NV-1];
  int vp = 0;
  function automatic logic [7:0] vbyte(input int base, input int i);
    vbyte = 8'(vec[base + i / 4] >> (8 * (i % 4)));
  endfunction

  task automatic cyc(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic pulse_clr;
    @(negedge clk); clr = 1'b1;
    @(negedge clk); clr = 1'b0;
  endtask
  task automatic wait_idle(input int lim);
    int n;
    n = 0;
    while (busy && n < lim) begin @(negedge clk); n++; end
    if (busy) fail("still busy");
    @(negedge clk);                     // the pulse counters see the last pulses
  endtask

  // send the request bytes [from, to) of the request at vec[base]
  int gap = 3;
  task automatic send(input int base, input int n, input int from, input int to);
    for (int i = from; i < to; i++) begin
      @(negedge clk);
      while ($urandom_range(0, gap) == 1) @(negedge clk);
      rq_valid = 1'b1; rq_data = vbyte(base, i); rq_last = i == n - 1;
      #1;
      while (!rq_ready) begin @(negedge clk); #1; end
      @(posedge clk);
      #1 rq_valid = 1'b0; rq_last = 1'b0;
    end
  endtask

  // receive one response byte (with back-pressure); returns its data and last
  int bp = 3;
  task automatic rcv(output logic [7:0] d, output logic l, output logic ok);
    int n;
    n = 0;
    @(negedge clk);
    rs_ready = $urandom_range(0, bp) != 0;
    while (!(rs_valid && rs_ready) && n < 3000000) begin
      @(negedge clk); n++;
      rs_ready = $urandom_range(0, bp) != 0;
    end
    ok = rs_valid && rs_ready;
    d = rs_data; l = rs_last;
    @(posedge clk);
    #1 rs_ready = 1'b0;
  endtask

  task automatic do_req(input logic [23:0] arg);
    int ql, rl, nrn, qb, rb, ca, nd0, ne0, bad;
    logic [7:0] d;
    logic l, ok;
    ql = int'(arg[15:0]);
    ca = int'(arg[23:20]);
    nrn = int'(vec[vp] >> 24);
    rl = int'(vec[vp] & 32'hFFFFFF);
    for (int i = 0; i < nrn; i++) begin rnq[rn_t % 64] = vec[vp + 1 + i]; rn_t++; end
    qb = vp + 1 + nrn;
    rb = qb + (ql + 3) / 4;
    vp = rb + (rl + 3) / 4;
    nd0 = n_done; ne0 = n_err;
    ncase++;
    if (ca == 1) begin
      send(qb, ql, 0, ql / 2);
      pulse_clr;
      send(qb, ql, ql / 2, ql);
      cyc(2);
      wait_idle(100000);
    end else begin
      send(qb, ql, 0, ql);
      if (ca == 2) begin
        // read the response up to the signature, then clr while it is computed
        while (!u_dut.u_mldsa.busy) begin
          @(negedge clk); rs_ready = 1'b1;
        end
        @(negedge clk); rs_ready = 1'b0;
        cyc(500);
        pulse_clr;
        wait_idle(3000000);
      end else if (ca == 3) begin
        rcv(d, l, ok);
        pulse_clr;
        cyc(2);
        wait_idle(100000);
      end
    end
    if (ca != 0) begin
      if (key_ok || conn != 2'd0) fail($sformatf("case %0d: key or connection left after clr", ncase));
      // the random words not used
      rn_h = rn_t;
    end else begin
      bad = 0;
      for (int i = 0; i < rl; i++) begin
        rcv(d, l, ok);
        if (!ok) begin fail($sformatf("case %0d: response byte %0d missing", ncase, i)); i = rl; end
        else begin
          if (d !== vbyte(rb, i)) begin
            if (bad < 4) fail($sformatf("case %0d (%02h %02h): byte %0d got %02h want %02h",
                                          ncase, vbyte(qb, 0), vbyte(qb, 1), i, d, vbyte(rb, i)));
            bad++;
          end
          if (l !== (i == rl - 1)) fail($sformatf("case %0d: rs_last wrong at byte %0d", ncase, i));
        end
      end
      cyc(2);
      wait_idle(100000);
      if (n_done != nd0 + 1) fail($sformatf("case %0d: rsp_done pulses %0d", ncase, n_done - nd0));
      if ((n_err != ne0) != (vbyte(rb, 1) == 8'h7F)) fail($sformatf("case %0d: rsp_err", ncase));
      if (vbyte(rb, 1) == 8'h7F && err_code != vbyte(rb, 2)) fail($sformatf("case %0d: err_code", ncase));
      if (rn_h != rn_t) fail($sformatf("case %0d: %0d random words not taken", ncase, rn_t - rn_h));
    end
  endtask

  task automatic do_keygen(input logic [23:0] arg);
    int c0, k0;
    logic [255:0] s;
    for (int i = 0; i < 8; i++) s[32 * i +: 32] = vec[vp + i];
    vp += 8;
    c0 = n_cmderr; k0 = n_kg;
    @(negedge clk);
    pset = arg[13:12]; kg_sel = arg[0];
    if (arg[0]) begin sl_seed = s; seed = ~s; end else begin seed = s; sl_seed = ~s; end
    kg_start = 1'b1;
    @(negedge clk); kg_start = 1'b0;
    if (arg[8]) begin
      cyc(2);
      if (n_cmderr != c0 + 1 || busy) fail("KeyGen not refused");
    end else if (arg[4]) begin
      cyc(3000);
      pulse_clr;
      wait_idle(1000000);
      if (key_ok) fail("key after clr in KeyGen");
    end else begin
      wait_idle(1000000);
      if (n_kg != k0 + 1 || !key_ok || key_pset != arg[13:12]) fail("KeyGen");
      if (u_dut.u_mldsa.mem[16'h2F60 + 5] !== 8'h00) fail("seed not wiped");
    end
    seed = '0; sl_seed = '0;
  endtask

  task automatic do_pk(input logic [23:0] arg);
    int n, c0, bad, t;
    c0 = n_cmderr;
    @(negedge clk); pk_open = 1'b1;
    @(negedge clk); pk_open = 1'b0;
    if (arg[23]) begin
      cyc(2);
      if (n_cmderr != c0 + 1 || busy) fail("pk_open not refused");
    end else begin
      n = int'(arg[15:0]);
      bad = 0;
      for (int i = 0; i < n; i++) begin
        t = 0;
        @(negedge clk); pk_ready = $urandom_range(0, 2) != 0;
        while (!(pk_valid && pk_ready) && t < 1000) begin @(negedge clk); pk_ready = $urandom_range(0, 2) != 0; t++; end
        if (pk_data !== vec[vp + i] || pk_last !== (i == n - 1)) begin
          if (bad < 3) fail($sformatf("PK word %0d: got %h want %h", i, pk_data, vec[vp + i]));
          bad++;
        end
        @(posedge clk); #1 pk_ready = 1'b0;
      end
      vp += n;
      cyc(2);
      if (busy) fail("busy after PK");
    end
  endtask

  task automatic do_store(input logic [23:0] arg);
    int n;
    n = int'(arg[15:0]);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      st_we = 1'b1; st_sel = arg[16]; st_addr = (CC_AW - 2)'(vec[vp] + 32'(i)); st_data = vec[vp + 1 + i];
    end
    @(negedge clk); st_we = 1'b0;
    vp += n + 1;
  endtask

  initial begin
    int op;
    logic [23:0] arg;
    logic done_v;
    if ($fopen("tb/SPDM_vec.hex", "r") != 0) $readmemh("tb/SPDM_vec.hex", vec);
    else if ($fopen("../tb/SPDM_vec.hex", "r") != 0) $readmemh("../tb/SPDM_vec.hex", vec);
    else $readmemh("../../../../tb/SPDM_vec.hex", vec);
    cyc(3); rst_n = 1'b1; cyc(2);
    done_v = 1'b0;
    while (!done_v) begin
      op = int'(vec[vp] >> 24); arg = vec[vp][23:0]; vp++;
      gap = $urandom_range(0, 3); bp = $urandom_range(1, 4); rn_gap = $urandom_range(0, 3);
      case (op)
        1: begin
          @(negedge clk);
          ct_exp = vec[vp][7:0]; asym_id = vec[vp + 1]; pset = vec[vp + 2][1:0]; cc_len = vec[vp + 3][CC_AW:0];
          m_en = vec[vp + 4][NM-1:0]; m_tcb = vec[vp + 5][NM-1:0]; m_type = vec[vp + 6];
          vp += 7;
        end
        2: do_store(arg);
        3: do_keygen(arg);
        4: do_pk(arg);
        5: do_req(arg);
        6: begin
          pulse_clr; cyc(2); wait_idle(100000);
          if (key_ok || conn != 2'd0) fail("clr");
        end
        7: sl_valid = arg[0];
        default: done_v = 1'b1;
      endcase
    end
    $display("%0d requests from the vectors", ncase);
    directed();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // ---------------- directed cases ----------------
  task automatic directed;
    int c0;
    logic [7:0] d;
    logic l, ok;
    // a command while a request is received or answered is refused
    @(negedge clk); rq_valid = 1'b1; rq_data = 8'h10; rq_last = 1'b0;
    @(negedge clk); rq_data = 8'h84;
    c0 = n_cmderr;
    kg_start = 1'b1; @(negedge clk); kg_start = 1'b0; pk_open = 1'b1; rq_data = 8'h00;
    @(negedge clk); pk_open = 1'b0; rq_last = 1'b1;
    @(negedge clk); rq_valid = 1'b0; rq_last = 1'b0;
    if (n_cmderr != c0 + 2) fail("commands while busy not refused");
    for (int i = 0; i < 8; i++) rcv(d, l, ok);
    if (!l) fail("VERSION length");
    cyc(2);
    // a request is held off while a command is given in the same clock
    @(negedge clk); rq_valid = 1'b1; rq_data = 8'h10; pk_open = 1'b1;
    #1 if (rq_ready) fail("request taken with a command");
    @(negedge clk); pk_open = 1'b0; rq_valid = 1'b0;
    cyc(3);
    // clr when idle, and clr while KeyGen is pending a clr already
    pulse_clr; cyc(2); wait_idle(10000);
    // reset in the middle of a request
    @(negedge clk); rq_valid = 1'b1; rq_data = 8'h12; rq_last = 1'b0;
    @(negedge clk); rq_valid = 1'b0;
    rst_n = 1'b0; cyc(2); rst_n = 1'b1; cyc(2);
    if (busy || conn != 2'd0) fail("reset");
  endtask

  initial begin
    #2000ms;
    $display("TIMEOUT");
    $finish;
  end
endmodule
