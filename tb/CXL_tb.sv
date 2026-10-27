// SPDX-License-Identifier: Apache-2.0
// CXL_top testbench: a host model drives M2S Req and RwD with random
// opcodes, meta fields, SnpTypes, tags, addresses (in and out of the HDM
// range), byte enables and poison, with gaps, while S2M NDR and DRS are
// read with random back-pressure.
//  - a reference memory (data, meta state, poison) predicts every response:
//    the host keeps at most one transaction on a line outstanding, so the
//    device's order between the channels cannot change a result; each
//    response must match an outstanding tag of the right kind, exactly once
//  - event pulses are counted against the requests that must raise them
//  - a conflict phase sends overlapping transactions to two lines (only
//    tags are checked, then the reference is taken from the device), a
//    stall phase fills the Req FIFO with the responses held, the HDM base
//    moves (including across the top of the address space), and a reset
//    lands with traffic in flight
// The bound checker (tb/cov/CXL_sva.sv) checks every output on every clock
// against its own model, which also fixes the arbitration order.
`timescale 1ns/1ps
module CXL_tb;
  localparam int LINES = 16, RQD = 4;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic [15:0] hdm_base = 0;
  logic        req_valid = 0, rwd_valid = 0, rwd_poison = 0, ndr_ready = 0, drs_ready = 0;
  logic [3:0]  req_opcode = 0, rwd_opcode = 0;
  logic [1:0]  req_meta_field = 0, req_meta_value = 0, rwd_meta_field = 0, rwd_meta_value = 0;
  logic [2:0]  req_snp_type = 0, rwd_snp_type = 0;
  logic [15:0] req_tag = 0, req_addr = 0, rwd_tag = 0, rwd_addr = 0;
  logic [63:0] rwd_data = 0;
  logic [7:0]  rwd_be = 0;
  wire         req_ready, rwd_ready, ndr_valid, drs_valid, drs_poison, drs_last;
  wire  [1:0]  ndr_opcode, ndr_meta_value, ndr_devload, drs_meta_value, drs_devload;
  wire  [15:0] ndr_tag, drs_tag;
  wire  [63:0] drs_data;
  wire         ev_range, ev_opcode, ev_proto, ev_poison;

  CXL_top #(.LINES(LINES), .RQD(RQD)) dut (.*);

  // ---------------- reference ----------------
  logic [511:0] rm [0:LINES-1];
  logic [1:0]   rmt [0:LINES-1];
  bit           rps [0:LINES-1];
  int           busy [0:LINES-1];
  // outstanding responses: kind 1 NDR, 2 DRS; chk 0: tag and kind only
  int           e_tag [$], e_kind [$], e_ln [$];
  logic [1:0]   e_op [$], e_mv [$];
  bit           e_po [$], e_chk [$];
  logic [511:0] e_line [$];
  bit           tag_used [0:65535];
  int           x_range = 0, x_opcode = 0, x_proto = 0, x_poison = 0;     // expected
  int           n_range = 0, n_opcode = 0, n_proto = 0, n_poison = 0;     // seen
  int           n_ndr = 0, n_drs = 0;
  bit           hz = 0;                        // conflict phase
  int           hz_lines = 2;
  int           rmode = 0;                     // response back-pressure
  int           gap_max = 4, p_out = 10;       // gaps, % out of range
  int           f_off = -100, f_po = -1;       // forced line offset, poison (directed)
  int           f_dp = -1;                    // forced data byte pattern (directed)
  bit           stop = 0;

  task automatic ref_clear();
    for (int l = 0; l < LINES; l++) begin rm[l] = '0; rmt[l] = 2'b00; rps[l] = 0; busy[l] = 0; end
  endtask
  task automatic ref_from_dut();
    for (int l = 0; l < LINES; l++) begin
      for (int b = 0; b < 8; b++) rm[l][64 * b +: 64] = dut.mem[l * 8 + b];
      rmt[l] = dut.meta[l]; rps[l] = dut.pois[l];
    end
  endtask
  task automatic exp_clear();
    e_tag.delete(); e_kind.delete(); e_ln.delete(); e_op.delete(); e_mv.delete(); e_po.delete();
    e_chk.delete(); e_line.delete();
    for (int t = 0; t < 65536; t++) tag_used[t] = 0;
    for (int l = 0; l < LINES; l++) busy[l] = 0;
  endtask
  task automatic exp_add(input int tag, input int kind, input int ln, input logic [1:0] op, input logic [1:0] mv,
                         input bit po, input logic [511:0] line);
    e_tag.push_back(tag); e_kind.push_back(kind); e_ln.push_back(ln); e_op.push_back(op); e_mv.push_back(mv);
    e_po.push_back(po); e_line.push_back(line); e_chk.push_back(!hz);
    tag_used[tag] = 1;
    if (ln >= 0) busy[ln]++;
  endtask
  function automatic int exp_find(input int tag, input int kind);
    for (int i = 0; i < e_tag.size(); i++) if (e_tag[i] == tag && e_kind[i] == kind) return i;
    return -1;
  endfunction
  task automatic exp_del(input int i);
    tag_used[e_tag[i]] = 0;
    if (e_ln[i] >= 0) busy[e_ln[i]]--;
    e_tag.delete(i); e_kind.delete(i); e_ln.delete(i); e_op.delete(i); e_mv.delete(i); e_po.delete(i);
    e_chk.delete(i); e_line.delete(i);
  endtask
  function automatic logic [15:0] new_tag();
    logic [15:0] t;
    t = $urandom;
    while (tag_used[t]) t = $urandom;
    return t;
  endfunction

  // an address: a free line in range (any of the first hz_lines in the
  // conflict phase), or out of range; ln = -1 out of range
  task automatic pick_addr(input bit need_free, output logic [15:0] a, output int ln);
    if (f_off != -100) begin
      ln = f_off >= 0 && f_off < LINES ? f_off : -1;
      while (need_free && ln >= 0 && busy[ln] != 0) @(negedge clk);
      a = hdm_base + 16'(f_off);
    end else if ($urandom % 100 < p_out) begin
      a = hdm_base + 16'(LINES) + 16'($urandom % (65536 - LINES));
      ln = -1;
    end else begin
      if (hz) ln = $urandom % hz_lines;
      else begin
        ln = $urandom % LINES;
        while (need_free && busy[ln] != 0 && !stop) begin
          @(negedge clk);
          ln = $urandom % LINES;
        end
      end
      a = hdm_base + 16'(ln);
    end
  endtask
  function automatic logic [1:0] rnd_mf();
    int r;
    r = $urandom % 100;
    return r < 45 ? 2'b00 : r < 90 ? 2'b11 : r < 95 ? 2'b01 : 2'b10;
  endfunction
  function automatic logic [2:0] rnd_snp();
    return $urandom % 100 < 6 ? 3'(4 + $urandom % 4) : 3'($urandom % 4);
  endfunction

  // ---------------- M2S Req ----------------
  task automatic send_req(input logic [3:0] op);
    logic [1:0]  mf, mv, emf, old;
    logic [2:0]  snp;
    logic [15:0] a, tag;
    int          ln;
    bit          need;
    mf = rnd_mf(); mv = $urandom; snp = rnd_snp(); tag = new_tag();
    need = op == 4'd0 || op == 4'd1 || op == 4'd2 || op == 4'd9 || op == 4'd10;
    pick_addr(need, a, ln);
    emf = mf == 2'b01 || mf == 2'b10 || snp[2] ? 2'b11 : mf;
    if (mf == 2'b01 || mf == 2'b10 || snp[2]) x_proto++;
    old = ln >= 0 ? rmt[ln] : 2'b00;
    case (op)
      4'd1, 4'd2: begin
        exp_add(tag, 2, ln, 2'd0, old, ln < 0 || rps[ln], ln >= 0 ? rm[ln] : 512'd0);
        if (ln >= 0 && rps[ln] && !hz) x_poison++;
        if (ln >= 0 && op == 4'd1 && emf == 2'b00) rmt[ln] = mv;
      end
      4'd0, 4'd9, 4'd10: begin
        exp_add(tag, 1, ln, op != 4'd10 && emf == 2'b00 ? (mv == 2'b11 ? 2'd1 : mv == 2'b10 ? 2'd2 : 2'd0) : 2'd0,
                old, 0, 512'd0);
        if (ln >= 0 && emf == 2'b00) rmt[ln] = mv;
      end
      4'd8: ;
      default: x_opcode++;
    endcase
    if (need && ln < 0) x_range++;
    req_valid = 1; req_opcode = op; req_meta_field = mf; req_meta_value = mv; req_snp_type = snp;
    req_tag = tag; req_addr = a;
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    @(negedge clk);
    req_valid = 0;
    req_opcode = $urandom; req_tag = $urandom; req_addr = $urandom;
  endtask
  function automatic logic [3:0] rnd_req_op();
    int r, k;
    r = $urandom % 100;
    k = $urandom % 10;                         // unsupported: 3..7, 11..15
    return r < 30 ? 4'd1 : r < 40 ? 4'd2 : r < 55 ? 4'd0 : r < 65 ? 4'd9 : r < 78 ? 4'd10 : r < 88 ? 4'd8 :
           k < 5 ? 4'(3 + k) : 4'(6 + k);
  endfunction

  // ---------------- M2S RwD ----------------
  task automatic send_rwd(input logic [3:0] op);
    logic [1:0]   mf, mv, emf, old;
    logic [2:0]   snp;
    logic [15:0]  a, tag;
    logic [63:0]  d [0:7];
    logic [7:0]   be [0:7];
    logic [511:0] nl;
    int           ln, bm;
    bit           po;
    mf = rnd_mf(); mv = $urandom; snp = rnd_snp(); tag = new_tag(); po = f_po >= 0 ? f_po[0] : $urandom % 100 < 15;
    pick_addr(op == 4'd1 || op == 4'd2, a, ln);
    emf = mf == 2'b01 || mf == 2'b10 || snp[2] ? 2'b11 : mf;
    if (mf == 2'b01 || mf == 2'b10 || snp[2]) x_proto++;
    bm = $urandom % 6;                         // byte enables: 0 none, 1 all, else random
    for (int b = 0; b < 8; b++) begin
      d[b] = f_dp >= 0 ? {8{8'(f_dp)}} : {$urandom, $urandom};
      be[b] = bm == 0 ? 8'h00 : bm == 1 ? 8'hFF : 8'($urandom);
    end
    if (op == 4'd1 || op == 4'd2) begin
      old = ln >= 0 ? rmt[ln] : 2'b00;
      exp_add(tag, 1, ln, 2'd0, old, 0, 512'd0);
      if (ln < 0) x_range++;
      else begin
        nl = rm[ln];
        for (int b = 0; b < 8; b++)
          for (int k = 0; k < 8; k++)
            if (op == 4'd1 || be[b][k]) nl[64 * b + 8 * k +: 8] = d[b][8 * k +: 8];
        rm[ln] = nl;
        rps[ln] = po || op == 4'd2 && rps[ln];
        if (emf == 2'b00) rmt[ln] = mv;
      end
    end else x_opcode++;
    for (int b = 0; b < 8; b++) begin
      rwd_valid = 1; rwd_data = d[b]; rwd_be = be[b];
      if (b == 0 || $urandom % 2) begin
        rwd_opcode = op; rwd_meta_field = mf; rwd_meta_value = mv; rwd_snp_type = snp; rwd_tag = tag;
        rwd_addr = a; rwd_poison = po;
      end else begin
        // only beat 0's header counts
        rwd_opcode = $urandom; rwd_meta_field = $urandom; rwd_meta_value = $urandom; rwd_snp_type = $urandom;
        rwd_tag = $urandom; rwd_addr = $urandom; rwd_poison = $urandom;
      end
      @(posedge clk);
      while (!rwd_ready) @(posedge clk);
      @(negedge clk);
      rwd_valid = 0;
      if ($urandom % 4 == 0) repeat ($urandom % 3) @(negedge clk);
    end
  endtask
  function automatic logic [3:0] rnd_rwd_op();
    int r;
    r = $urandom % 100;
    return r < 45 ? 4'd1 : r < 90 ? 4'd2 : r < 93 ? 4'd0 : 4'(3 + $urandom % 13);
  endfunction

  task automatic req_driver(input int n);
    for (int i = 0; i < n && !stop; i++) begin
      send_req(rnd_req_op());
      if ($urandom % 3 == 0) repeat ($urandom % (gap_max + 1)) @(negedge clk);
    end
  endtask
  task automatic rwd_driver(input int n);
    for (int i = 0; i < n && !stop; i++) begin
      send_rwd(rnd_rwd_op());
      if ($urandom % 3 == 0) repeat ($urandom % (gap_max + 1)) @(negedge clk);
    end
  endtask

  // ---------------- S2M ----------------
  always @(negedge clk) begin
    case (rmode)
      0: begin ndr_ready = 1; drs_ready = 1; end
      1: begin ndr_ready = $urandom % 2; drs_ready = $urandom % 2; end
      2: begin ndr_ready = $urandom % 6 == 0; drs_ready = $urandom % 6 == 0; end
      3: begin ndr_ready = $urandom % 4 != 0; drs_ready = $urandom % 4 != 0; end
      default: begin ndr_ready = 0; drs_ready = 0; end
    endcase
  end
  int     d_beat = 0, d_idx = -1;
  logic [15:0] d_tag = 0;
  logic [511:0] d_ln = 0;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      d_beat = 0; d_idx = -1;
    end else begin
      n_range += ev_range; n_opcode += ev_opcode; n_proto += ev_proto; n_poison += ev_poison;
      if (ndr_valid && ndr_ready) begin : b_ndr
        int i;
        i = exp_find(ndr_tag, 1);
        n_ndr++;
        if (i < 0) fail($sformatf("NDR tag %h not outstanding", ndr_tag));
        else begin
          if (e_chk[i] && (ndr_opcode != e_op[i] || ndr_meta_value != e_mv[i]))
            fail($sformatf("NDR tag %h: opcode %0d meta %b, expected %0d %b", ndr_tag, ndr_opcode, ndr_meta_value,
                           e_op[i], e_mv[i]));
          exp_del(i);
        end
      end
      if (drs_valid && drs_ready) begin
        if (d_beat == 0) d_tag = drs_tag;
        d_idx = exp_find(d_tag, 2);         // other responses may have moved it
        if (d_beat == 0) begin
          if (d_idx < 0) fail($sformatf("DRS tag %h not outstanding", drs_tag));
          else if (e_chk[d_idx] && (drs_meta_value != e_mv[d_idx] || drs_poison != e_po[d_idx]))
            fail($sformatf("DRS tag %h: meta %b poison %0d, expected %b %0d", drs_tag, drs_meta_value, drs_poison,
                           e_mv[d_idx], e_po[d_idx]));
        end
        if (d_idx >= 0) d_ln = e_line[d_idx];   // (Icarus: no part-select of a queue element)
        if (d_idx >= 0 && e_chk[d_idx] && drs_data != d_ln[64 * d_beat +: 64])
          fail($sformatf("DRS tag %h beat %0d: %h, expected %h", drs_tag, d_beat, drs_data, d_ln[64 * d_beat +: 64]));
        if (drs_tag != d_tag) fail("DRS tag changed within the message");
        if (drs_last != (d_beat == 7)) fail($sformatf("DRS last on beat %0d", d_beat));
        d_beat = (d_beat + 1) % 8;
        if (d_beat == 0) begin
          if (d_idx >= 0) exp_del(d_idx);
          n_drs++;
          d_idx = -1;
        end
      end
    end

  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  // wait for every response, then compare the event counts
  task automatic drain(input string ph);
    int t;
    t = 0;
    while (e_tag.size() != 0 && t < 5000) begin @(negedge clk); t++; end
    if (e_tag.size() != 0) fail($sformatf("%s: %0d responses missing", ph, e_tag.size()));
    wait_clk(4);
    if (n_range != x_range || n_opcode != x_opcode || n_proto != x_proto || !hz && n_poison != x_poison)
      fail($sformatf("%s: events range %0d/%0d opcode %0d/%0d proto %0d/%0d poison %0d/%0d", ph, n_range, x_range,
                     n_opcode, x_opcode, n_proto, x_proto, n_poison, x_poison));
    x_range = 0; x_opcode = 0; x_proto = 0; x_poison = 0;
    n_range = 0; n_opcode = 0; n_proto = 0; n_poison = 0;
    if (hz) ref_from_dut();
  endtask
  task automatic traffic(input int nq, input int nw, input string ph);
    fork
      req_driver(nq);
      rwd_driver(nw);
    join
    drain(ph);
  endtask

  initial begin
    ref_clear();
    exp_clear();
    hdm_base = 16'hAAA7;
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    // reads of the reset memory
    for (int l = 0; l < LINES; l++) begin
      p_out = 0;
      send_req(4'd2);
    end
    drain("reset memory");
    // random traffic, each back-pressure mode, moving base
    for (int m = 0; m < 5; m++) begin
      rmode = m == 4 ? 3 : m;
      gap_max = m == 1 ? 0 : 4;
      p_out = m == 2 ? 30 : 10;
      traffic(150, 100, $sformatf("traffic %0d", m));
      hdm_base = m == 0 ? 16'hFFF8 : m == 1 ? 16'h0000 : m == 2 ? 16'hFFFF - 16'(LINES) + 1 : 16'h5557;
    end
    // every line poisoned, read, cleared
    for (int l = 0; l < LINES; l++) begin
      f_off = l;
      f_po = 1; send_rwd(4'd1);
      send_req(4'd1);
      f_po = 0; send_rwd(4'd1);
    end
    f_po = -1;
    drain("poison sweep");
    // the range edges
    for (int i = 0; i < 4; i++) begin
      f_off = i == 0 ? -1 : i == 1 ? LINES : i == 2 ? 0 : LINES - 1;
      send_rwd(4'd1);
      send_req(4'd1);
      send_req(4'd0);
      send_rwd(4'd2);
      send_req(4'd2);
    end
    f_off = -100;
    drain("range edges");
    // conflicts on two lines
    hz = 1;
    for (int m = 0; m < 3; m++) begin
      rmode = m;
      hz_lines = m == 2 ? 1 : 2;
      p_out = 5;
      traffic(80, 60, "conflict");
    end
    hz = 0;
    // a full Req FIFO with the responses held
    rmode = 4;
    p_out = 0;
    fork
      begin
        for (int i = 0; i < RQD + 3; i++) send_req(i % 2 ? 4'd1 : 4'd0);
      end
      begin
        send_rwd(4'd1);
        send_rwd(4'd3);
      end
      begin
        wait_clk(60);
        rmode = 3;
      end
    join
    drain("stall");
    // a reset with traffic in flight
    rmode = 1;
    fork
      begin
        req_driver(200);
      end
      begin
        rwd_driver(200);
      end
      begin
        wait_clk(150);
        // mid-message on the clock before as well
        while (!(drs_valid && !drs_last && d_beat != 0)) @(negedge clk);
        stop = 1;
        rst_n = 0;
      end
    join
    exp_clear();
    ref_clear();
    wait_clk(3);
    rst_n = 1;
    stop = 0;
    x_range = 0; x_opcode = 0; x_proto = 0; x_poison = 0;
    n_range = 0; n_opcode = 0; n_proto = 0; n_poison = 0;
    rmode = 0;
    traffic(60, 40, "after reset");
    // every line written and read with each data pattern
    for (int k = 0; k < 4; k++)
      for (int l = 0; l < LINES; l++) begin
        f_off = l; f_po = 0; f_dp = k == 0 ? 8'h00 : k == 1 ? 8'hFF : k == 2 ? 8'h55 : 8'hAA;
        send_rwd(4'd1);
        send_req(4'd1);
      end
    f_off = -100; f_po = -1; f_dp = -1;
    drain("data patterns");

    if (errors == 0) $display("TEST PASSED: CXL (%0d NDR, %0d DRS)", n_ndr, n_drs);
    else $display("TEST FAILED: CXL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: CXL (timeout, %0d responses outstanding)", e_tag.size());
    $finish;
  end
endmodule
