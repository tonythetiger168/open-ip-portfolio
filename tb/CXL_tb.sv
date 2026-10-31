// SPDX-License-Identifier: Apache-2.0
// CXL_top testbench: a host model (tb/CXL_host.svh) on the 256-byte flit
// link sends M2S Req, RwD and BIRsp messages packed into CXL.cachemem
// flits, CXL.io flits and NOP flits, with random opcodes, meta fields,
// SnpTypes, tags, addresses (in and out of the HDM range), byte enables,
// poison, empty units and beat gaps, within the device's credits, and reads
// the device's flits with random back-pressure; the device's CXL.io side
// sends and takes CXL.io payloads.
//  - every response is predicted by a reference memory; every S2M flit is
//    checked (CRC, sequence, reserved bytes, packing); credits must all
//    come back; event pulses are counted against what must raise them
//  - phases: HDM-H traffic in each back-pressure mode with the HDM base
//    moving, credits returned at once, one at a time and held; a poison
//    sweep; the range edges; conflicts on two lines (tags only); a stall
//    that fills the Req FIFO, then messages and CXL.io flits sent without
//    credit (dropped); error flits (bad CRC, reserved type, skipped
//    sequence number, reserved unit code, misplaced RwD header); HDM-DB
//    traffic with snoop filter evictions, device BI requests, legal,
//    illegal and stale BIRsps, write-backs and BIConflict; an RwD that
//    would overfill the snoop filter; a reset with traffic in flight;
//    every line written and read with each data pattern
// The bound checker (tb/cov/CXL_sva.sv) checks every output on every clock
// against its own model.
`timescale 1ns/1ps
module CXL_tb;
  localparam int LINES = 16, RQD = 4, WQD = 2, SFE = 4, IOD = 2;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic        bi_en = 0;
  logic        rx_valid, tx_ready, io_rx_ready, io_tx_valid, bi_valid;
  logic [63:0] rx_data, io_tx_data;
  logic [1:0]  bi_op;
  logic [3:0]  bi_line;
  wire         tx_valid, io_rx_valid, io_rx_last, io_tx_ready, bi_ready, bi_done;
  wire  [63:0] tx_data, io_rx_data;
  wire  [1:0]  bi_state;
  wire  [4:0]  sf_cnt;
  wire         ev_range, ev_opcode, ev_proto, ev_poison, ev_crc, ev_seq, ev_fmt, ev_ovf;

`define CXL_CLK clk
`define CXL_C dut
`include "CXL_host.svh"

  CXL_top #(.LINES(LINES), .RQD(RQD), .WQD(WQD), .SFE(SFE), .IOD(IOD)) dut (.*);

  // host buffers for S2M messages: the credits it gives at the start
  task automatic host_start();
    ho_ndr = 2; ho_drs = 2; ho_bis = 1; ho_io = 2;
  endtask
  task automatic io_traffic(input int nh, input int nd);
    for (int i = 0; i < nh; i++) hio_flit();
    for (int i = 0; i < nd; i++) dio_flit();
  endtask

  initial begin
    ref_clear();
    exp_clear();
    hdm_base = 16'hAAA7;
    wait_clk(3);
    rst_n = 1;
    host_start();
    wait_clk(3);
    // reads of the reset memory
    p_out = 0;
    for (int l = 0; l < LINES; l++) begin
      f_off = l;
      send_req(4'd2);
    end
    f_off = -100;
    drain("reset memory");
    // HDM-H traffic, each back-pressure mode, moving base, CXL.io both ways
    for (int m = 0; m < 6; m++) begin
      tx_mode = m == 4 ? 3 : m == 5 ? 1 : m;
      io_rx_mode = m % 3;
      h_gap = m == 1 ? 0 : m == 3 ? 60 : 20;
      h_beat_gap = m == 1 ? 0 : m == 2 ? 6 : 1;
      dio_gap = m == 1 ? 0 : 30;
      h_crd_mode = m == 5 ? 1 : 0;
      p_out = m == 2 ? 30 : 10;
      io_traffic(3, 3);
      traffic(150, 100, $sformatf("traffic %0d", m));
      hdm_base = m == 0 ? 16'hFFF8 : m == 1 ? 16'h0000 : m == 2 ? 16'hFFFF - 16'(LINES) + 1 : 16'h5557;
    end
    h_crd_mode = 0; tx_mode = 0; io_rx_mode = 0;
    // every line poisoned, read, cleared
    for (int l = 0; l < LINES; l++) begin
      f_off = l;
      f_po = 1; send_rwd(4'd1);
      wait_clk(40);
      send_req(4'd1);
      wait_clk(40);
      f_po = 0; send_rwd(4'd1);
      wait_clk(40);
    end
    f_po = -1;
    drain("poison sweep");
    // the range edges
    for (int i = 0; i < 4; i++) begin
      f_off = i == 0 ? -1 : i == 1 ? LINES : i == 2 ? 0 : LINES - 1;
      send_rwd(4'd1); wait_clk(40);
      send_req(4'd1); wait_clk(40);
      send_req(4'd0); wait_clk(40);
      send_rwd(4'd2); wait_clk(40);
      send_req(4'd2); wait_clk(40);
    end
    f_off = -100;
    drain("range edges");
    // conflicts on two lines
    hz = 1;
    for (int m = 0; m < 3; m++) begin
      tx_mode = m;
      hz_lines = m == 2 ? 1 : 2;
      p_out = 5;
      traffic(80, 60, "conflict");
    end
    hz = 0;
    // S2M held: the Req FIFO and the RwD ring fill
    tx_mode = 4;
    p_out = 0;
    for (int i = 0; i < RQD + 1; i++) send_req(i % 2 ? 4'd1 : 4'd0);
    wait_clk(400);
    tx_mode = 3;
    drain("stall");
    // credits held by the host: the device waits
    h_crd_mode = 2;
    for (int i = 0; i < 6; i++) send_req(i % 2 ? 4'd2 : 4'd9);
    io_traffic(0, 2);
    wait_clk(600);
    h_crd_mode = 0;
    drain("credits held");
    // messages without credit: NDR held, the FIFO fills, then overflows
    tx_mode = 4;
    wait_clk(20);
    h_ovf = 1;
    f_mf = 3;
    begin : b_ovf
      int k;
      k = RQD + 2;
      for (int i = 0; i < k; i++) begin
        f_off = i % LINES;
        send_req(i == k - 1 || i == k - 2 ? 4'd8 : 4'd0);
      end
      // the last two (MemSpecRd: no response) find every buffer in use or
      // owed back
      x_ovf += 2;
      hc_req += 2;
    end
    f_off = -100; f_mf = -1;
    wait_clk(600);
    h_ovf = 0;
    tx_mode = 0;
    drain("Req overflow");
    // CXL.io flits without credit: the buffers fill, one is dropped
    io_rx_mode = 3;
    h_ovf = 1;
    io_traffic(IOD + 1, 0);
    while (hq_io_n != 0) wait_clk(1);
    wait_clk(300);
    x_ovf++;
    hc_io++;
    for (int i = 0; i < 30; i++) dio_w = hio_exp.pop_back();
    h_ovf = 0;
    io_rx_mode = 1;
    drain("CXL.io overflow");
    io_rx_mode = 0;
    // RwD messages without credit: the NDR is held, the ring fills, an
    // RwD and a BIConflict are dropped (sent out of range, so the
    // reference does not change)
    tx_mode = 4;
    wait_clk(20);
    f_mf = 3; f_off = 0;
    send_req(4'd0);
    wait_clk(100);
    h_ovf = 1;
    for (int i = 0; i < WQD; i++) begin f_off = 1 + i; send_rwd(4'd1); end
    wait_clk(200);
    f_off = -1;
    send_rwd(4'd1);
    exp_del(e_tag.size() - 1); x_range--;
    send_rwd(4'd4);
    x_opcode--;
    x_ovf += 2; hc_rwd += 2;
    f_off = -100; f_mf = -1;
    wait_clk(300);
    h_ovf = 0;
    tx_mode = 0;
    drain("RwD overflow");
    // two BIRsps back to back without credit: the second finds the first
    h_hold = 1;
    wait_clk(80);
    h_gap = 0; h_ovf = 1;
    for (int i = 0; i < 2; i++) begin hq_bir.push_back(u_bir(4'd0, 12'h7)); hq_bln.push_back(-1); end
    x_proto++; x_ovf++; hc_bir++;
    h_hold = 0;
    wait_clk(100);
    h_ovf = 0; h_gap = 20;
    drain("BIRsp overflow");
    // an RwD whose data rolls over into a flit with a bad CRC: abandoned
    h_hold = 1;
    wait_clk(80);
    for (int j = 0; j < 30; j++) fb[j] = 64'd0;
    fb[28] = u_rwd(4'd1, 2'b11, 2'b00, 3'd0, 0, 16'h1234, hdm_base + 16'(LINES) + 16'd7);
    fb[29] = '1;
    flit_close(2'd2, 1, 0);
    send_flit();
    for (int j = 0; j < 30; j++) fb[j] = {$urandom, $urandom};
    flit_close(2'd2, 0, 1);
    send_flit();
    x_crc++;
    h_hold = 0;
    traffic(20, 20, "bad CRC after an RwD header");
    // BIRsps without HDM-DB, in every unit (mostly empty flits spread them out)
    h_gap = 92;
    for (int i = 0; i < 800; i++) begin
      while (hq_bir.size() > 1) wait_clk(1);
      hq_bir.push_back(u_bir(4'($urandom), 12'($urandom))); hq_bln.push_back(-1); x_proto++;
      if ($urandom % 2) send_req(rnd_req_op());
      if ($urandom % 3 == 0) send_rwd(rnd_rwd_op());
      wait_clk($urandom % 4);
    end
    drain("BIRsp spray");
    h_gap = 20;
    // a BIRsp without HDM-DB, error flits
    hq_bir.push_back(u_bir(4'd0, 12'h123)); hq_bln.push_back(-1); x_proto++;
    for (int e = 1; e <= 7; e++) begin
      h_err = e == 6 ? 7 : e == 7 ? 1 : e;
      while (h_err != 0) begin
        if (e >= 3) begin send_req(rnd_req_op()); send_rwd(4'd1); end
        wait_clk(30);
      end
      traffic(10, 5, $sformatf("error flit %0d", e));
    end
    // HDM-DB: snoop filter evictions, device BI requests, write-backs,
    // conflicts
    drain("HDM-H done");
    bi_en = 1;
    for (int m = 0; m < 4; m++) begin
      tx_mode = m;
      bi_illegal = m == 2 ? 30 : 0;
      bi_stale = m == 3 ? 20 : 0;
      bi_wb = m == 1 ? 80 : 30;
      p_out = 5;
      bi_req_n = 20;
      io_traffic(2, 2);
      traffic(150, 80, $sformatf("HDM-DB %0d", m));
    end
    // many device BI requests, half the BIRsps illegal, S2M credits held a while
    tx_mode = 1; bi_illegal = 50; bi_stale = 10; bi_wb = 30; bi_req_n = 200;
    fork
      traffic(200, 100, "HDM-DB 4");
      begin
        wait_clk(300);
        h_crd_mode = 2;
        wait_clk(1500);
        h_crd_mode = 0;
      end
    join
    // BISnps among back-to-back responses, at every unit
    tx_mode = 0; bi_illegal = 0; bi_stale = 0; bi_wb = 0; bi_req_n = 1000;
    fork
      traffic(1500, 300, "HDM-DB 5");
      begin
        // BISnp credits held: a BISnp waits
        wait_clk(300);
        h_crd_mode = 3;
        wait_clk(1000);
        h_crd_mode = 0;
      end
    join
    bi_wb = 30;
    // a BIRsp with no BISnp outstanding
    hq_bir.push_back(u_bir(4'd0, 12'h5A5)); hq_bln.push_back(-1); x_proto++;
    drain("BIRsp with none outstanding");
    // an RwD that would take a line from Invalid with the filter full
    begin : b_sf
      int n;
      n = 0;
      for (int l = 0; l < LINES; l++) if (rmt[l] != 2'b00) n++;
      p_out = 0;
      for (int l = 0; l < LINES && n < SFE; l++)
        if (rmt[l] == 2'b00) begin
          f_off = l; f_mf = 0; f_mv = 2; send_req(4'd1); n++;
          drain("filling the snoop filter");
        end
      for (int l = 0; l < LINES; l++)
        if (rmt[l] == 2'b00 && f_off != -50) begin
          f_off = l; f_mf = 0; f_mv = 3;
          send_rwd(4'd1);
          rmt[l] = 2'b00;
          f_off = -50;
        end
      f_off = -100; f_mf = -1; f_mv = -1;
      drain("RwD with the snoop filter full");
    end
    bi_en = 0;
    drain("HDM-DB done");
    // every line taken (Any) without HDM-DB, then given back
    p_out = 0; f_mf = 0;
    for (int l = 0; l < LINES; l++) begin f_off = l; f_mv = 2; send_req(4'd0); end
    drain("every line held");
    for (int l = 0; l < LINES; l++) begin f_off = l; f_mv = 0; send_req(4'd10); end
    f_off = -100; f_mf = -1; f_mv = -1;
    drain("every line given back");
    // credits from the host past 255: the counters saturate
    ho_ndr += 400; ho_drs += 400; ho_bis += 400; ho_io += 400;
    while (ho_ndr > 0 || ho_drs > 0 || ho_bis > 0 || ho_io > 0) wait_clk(10);
    traffic(40, 30, "saturated credits");
    // a reset with traffic in flight
    tx_mode = 1;
    io_traffic(2, 2);
    fork
      req_driver(200);
      rwd_driver(200);
      begin
        wait_clk(150);
        // tx_valid already high at the last clock edge, mid-flit both ways
        for (int ok = 0; ok < 2; ) begin
          @(negedge clk);
          ok = tx_valid && hj > 3 && hj < 28 && dut.rj > 3 && dut.rj < 28 ? ok + 1 : 0;
        end
        stop = 1;
        rst_n = 0;
      end
    join
    wait_clk(3);
    exp_clear();
    ref_clear();
    hq_req.delete(); hq_rh.delete(); hq_rbe.delete(); hq_rd.delete(); hq_bir.delete(); hq_bln.delete(); hq_io.delete();
    hio_exp.delete(); dio_q.delete(); dio_exp.delete(); bq_op.delete(); bq_tag.delete(); bq_addr.delete();
    hq_io_n = 0; h_owe = 0; bi_req_n = 0; n_bi_acc = 0; n_bi_done = 0; cf_line = -1; cf_ack = 0; cf_tag = -1;
    hc_req = 0; hc_rwd = 0; hc_bir = 0; hc_io = 0; h_seq = 0;
    // the first ties after reset (the arbiters' reset values): the host
    // holds its credits while the device queues work of every kind, then
    // gives them all at once
    h_crd_mode = 2;
    rst_n = 1;
    host_start();
    stop = 0;
    ev_clear();
    tx_mode = 0;
    wait_clk(10);
    bi_en = 1; p_out = 0; f_mf = 0;
    f_off = 3; f_mv = 2; send_req(4'd1);       // a DRS, line 3 to Any
    f_off = 4; f_mv = 0; send_req(4'd0);       // an NDR into the one NDR register
    wait_clk(150);
    f_off = 5; send_rwd(4'd1);                 // RwD and Req both wait for it
    f_off = 6; send_req(4'd0);
    dio_flit();                                // a CXL.io flit to send
    wait_clk(200);
    @(negedge clk);
    bi_valid = 1; bi_op = 2'd2; bi_line = 4'd3; // a BISnpInv besides the responses
    @(posedge clk);
    while (!bi_ready) @(posedge clk);
    n_bi_acc++;
    @(negedge clk);
    bi_valid = 0;
    wait_clk(50);
    h_crd_mode = 0;
    f_off = -100; f_mf = -1; f_mv = -1;
    drain("ties after reset");
    bi_en = 0;
    traffic(60, 40, "after reset");
    // every line written and read with each data pattern
    for (int k = 0; k < 4; k++)
      for (int l = 0; l < LINES; l++) begin
        f_off = l; f_po = 0; f_dp = k == 0 ? 8'h00 : k == 1 ? 8'hFF : k == 2 ? 8'h55 : 8'hAA;
        send_rwd(4'd1);
        wait_clk(30);
        send_req(4'd1);
        wait_clk(30);
      end
    f_off = -100; f_po = -1; f_dp = -1;
    drain("data patterns");

    if (errors == 0)
      $display("TEST PASSED: CXL (%0d flits in, %0d NDR, %0d DRS, %0d BISnp, %0d BIConflictAck, %0d+%0d CXL.io flits)",
               n_flit, n_ndr, n_drs, n_bis, n_ack, n_iof, n_dio);
    else $display("TEST FAILED: CXL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #40ms;
    $display("TEST FAILED: CXL (timeout, %0d responses outstanding)", e_tag.size());
    $finish;
  end
endmodule
