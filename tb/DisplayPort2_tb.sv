// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for DisplayPort2_top v2.0 -- the TB is the sink:
//  * main-link monitor: 8b/10b decoder built from the standard code tables
//    (not from the DUT encoder), running-disparity check, sink lane status
//    (CR_DONE after 16 D10.2 in a row, EQ_DONE after 4 TPS1 sequences),
//    video line checker (BS, pixels, BE, SS, MSA, SE, FS, fill) and the
//    K23.7 fill check after a training failure;
//  * AUX responder: Manchester-II request decoder, DPCD window + EDID ROM,
//    each request checked against the expected link-training op; per-reply
//    fault plan (no reply, NACK/DEFER codes, Manchester violations, bad
//    SYNC / start bit, wrong reply length, bad STOP chips) and reply delay;
//  * HPD unplug / replug at chosen points, resets with traffic in flight.
// ============================================================================
`timescale 1ns/1ps
module DisplayPort2_tb;

  logic clk = 0, rst_n = 0;
  logic lane_p, lane_valid, link_trained, train_fail;
  logic aux_tx_p, aux_tx_en;
  logic sink_present = 0;
  logic [63:0] edid;
  logic edid_valid, irq;

  logic sink_drv = 0, sink_val = 1;
  wire  aux_line = aux_tx_en ? aux_tx_p : (sink_drv ? sink_val : 1'b1);

  DisplayPort2_top dut (
    .clk(clk), .rst_n(rst_n),
    .lane_p(lane_p), .lane_valid(lane_valid),
    .link_trained(link_trained), .train_fail(train_fail),
    .aux_tx_p(aux_tx_p), .aux_tx_en(aux_tx_en), .aux_rx_p(aux_line),
    .sink_present(sink_present),
    .edid(edid), .edid_valid(edid_valid), .irq(irq)
  );

  always #5 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction

  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask

  // ------------------------------------------------------------ 8b/10b tables
  // standard tables, {RD- code, RD+ code}, bits abcdei / fghj
  function automatic logic [11:0] t6(input logic [4:0] x);
    case (x)
      5'd0:  t6 = {6'b100111, 6'b011000};  5'd1:  t6 = {6'b011101, 6'b100010};
      5'd2:  t6 = {6'b101101, 6'b010010};  5'd3:  t6 = {6'b110001, 6'b110001};
      5'd4:  t6 = {6'b110101, 6'b001010};  5'd5:  t6 = {6'b101001, 6'b101001};
      5'd6:  t6 = {6'b011001, 6'b011001};  5'd7:  t6 = {6'b111000, 6'b000111};
      5'd8:  t6 = {6'b111001, 6'b000110};  5'd9:  t6 = {6'b100101, 6'b100101};
      5'd10: t6 = {6'b010101, 6'b010101};  5'd11: t6 = {6'b110100, 6'b110100};
      5'd12: t6 = {6'b001101, 6'b001101};  5'd13: t6 = {6'b101100, 6'b101100};
      5'd14: t6 = {6'b011100, 6'b011100};  5'd15: t6 = {6'b010111, 6'b101000};
      5'd16: t6 = {6'b011011, 6'b100100};  5'd17: t6 = {6'b100011, 6'b100011};
      5'd18: t6 = {6'b010011, 6'b010011};  5'd19: t6 = {6'b110010, 6'b110010};
      5'd20: t6 = {6'b001011, 6'b001011};  5'd21: t6 = {6'b101010, 6'b101010};
      5'd22: t6 = {6'b011010, 6'b011010};  5'd23: t6 = {6'b111010, 6'b000101};
      5'd24: t6 = {6'b110011, 6'b001100};  5'd25: t6 = {6'b100110, 6'b100110};
      5'd26: t6 = {6'b010110, 6'b010110};  5'd27: t6 = {6'b110110, 6'b001001};
      5'd28: t6 = {6'b001110, 6'b001110};  5'd29: t6 = {6'b101110, 6'b010001};
      5'd30: t6 = {6'b011110, 6'b100001};  default: t6 = {6'b101011, 6'b010100};
    endcase
  endfunction
  function automatic logic [7:0] t4(input logic [2:0] y);
    case (y)
      3'd0: t4 = {4'b1011, 4'b0100};  3'd1: t4 = {4'b1001, 4'b1001};
      3'd2: t4 = {4'b0101, 4'b0101};  3'd3: t4 = {4'b1100, 4'b0011};
      3'd4: t4 = {4'b1101, 4'b0010};  3'd5: t4 = {4'b1010, 4'b1010};
      3'd6: t4 = {4'b0110, 4'b0110};  default: t4 = {4'b1110, 4'b0001};
    endcase
  endfunction
  function automatic logic [7:0] tk28(input logic [2:0] y);
    case (y)
      3'd0: tk28 = {4'b0100, 4'b1011};  3'd1: tk28 = {4'b1001, 4'b0110};
      3'd2: tk28 = {4'b0101, 4'b1010};  3'd3: tk28 = {4'b0011, 4'b1100};
      3'd4: tk28 = {4'b0010, 4'b1101};  3'd5: tk28 = {4'b1010, 4'b0101};
      3'd6: tk28 = {4'b0110, 4'b1001};  default: tk28 = {4'b1000, 4'b0111};
    endcase
  endfunction
  function automatic int ones(input logic [9:0] v);
    ones = 0;
    for (int i = 0; i < 10; i++) ones += v[i];
  endfunction
  // {rd_out, code[9:0]} with code[9] = 'a'; rd 1 = RD+
  function automatic logic [10:0] enc_ref(input logic [7:0] d, input bit k, input bit rd);
    logic [5:0] c6;
    logic [3:0] c4;
    logic [11:0] p6;
    logic [7:0] p4;
    bit r1;
    if (k && d[4:0] == 5'd28) begin
      c6 = rd ? 6'b110000 : 6'b001111;
      p4 = tk28(d[7:5]);
      c4 = rd ? p4[3:0] : p4[7:4];
    end else begin
      p6 = t6(d[4:0]);
      c6 = rd ? p6[5:0] : p6[11:6];
      r1 = (ones({4'd0, c6}) == 3) ? rd : !rd;
      if (d[7:5] == 3'd7 && (k || (!r1 && (d[4:0] == 17 || d[4:0] == 18 || d[4:0] == 20)) ||
                             (r1 && (d[4:0] == 11 || d[4:0] == 13 || d[4:0] == 14))))
        c4 = r1 ? 4'b1000 : 4'b0111;                       // A7
      else begin
        p4 = t4(d[7:5]);
        c4 = r1 ? p4[3:0] : p4[7:4];
      end
    end
    enc_ref = {(ones({c6, c4}) == 5) ? rd : !rd, c6, c4};
  endfunction

  // decoder: index {rd, code}
  logic [7:0] dec_d  [0:2047];
  logic       dec_k  [0:2047];
  logic       dec_rd [0:2047];
  logic       dec_ok [0:2047];
  initial begin : tables
    logic [10:0] e;
    logic [7:0] kc;
    for (int i = 0; i < 2048; i++) dec_ok[i] = 0;
    for (int r = 0; r < 2; r++) begin
      for (int d = 0; d < 256; d++) begin
        e = enc_ref(d[7:0], 0, r[0]);
        dec_ok[{r[0], e[9:0]}] = 1; dec_d[{r[0], e[9:0]}] = d[7:0];
        dec_k[{r[0], e[9:0]}] = 0;  dec_rd[{r[0], e[9:0]}] = e[10];
      end
      for (int j = 0; j < 5; j++) begin
        kc = j == 0 ? 8'hBC : j == 1 ? 8'hF7 : j == 2 ? 8'hFB : j == 3 ? 8'hFD : 8'hFE;
        e = enc_ref(kc, 1, r[0]);
        dec_ok[{r[0], e[9:0]}] = 1; dec_d[{r[0], e[9:0]}] = kc;
        dec_k[{r[0], e[9:0]}] = 1;  dec_rd[{r[0], e[9:0]}] = e[10];
      end
    end
    // anchors from the standard
    if (enc_ref(8'hBC, 1, 0) !== 11'b1_0011111010) fail("anchor K28.5 RD-");
    if (enc_ref(8'hBC, 1, 1) !== 11'b0_1100000101) fail("anchor K28.5 RD+");
    if (enc_ref(8'h4A, 0, 0) !== 11'b0_0101010101) fail("anchor D10.2");
    if (enc_ref(8'hF7, 1, 0) !== 11'b0_1110101000) fail("anchor K23.7 RD-");
  end

  // ------------------------------------------------------------ main-link monitor
  bit         cr_seen = 0, eq_seen = 0;     // sink lane status
  int         cr_run = 0, tps_pos = 0, tps_seq = 0;
  bit         vid_en = 0, in_line = 0, fc_known = 0, fill_chk = 0;
  int         vpos = 0, lines_ok = 0, fills_ok = 0, n_sym = 0;
  logic [7:0] fc;

  function automatic logic [7:0] msa_exp(input int i, input logic [7:0] f);
    case (i)
      0: msa_exp = 8'h01;  1: msa_exp = f;     4: msa_exp = 8'h56;  5: msa_exp = 8'h34;
      6: msa_exp = 8'h12;  8: msa_exp = 8'h40; 9: msa_exp = 8'h01;  12: msa_exp = 8'hF0;
      default: msa_exp = 8'h00;
    endcase
  endfunction

  function automatic void symbol(input logic [7:0] d, input bit k);
    bit ok;
    n_sym++;
    // lane status (training patterns)
    if (!k && d == 8'h4A) begin cr_run++; if (cr_run >= 16) cr_seen = 1; end
    else cr_run = 0;
    if (k && d == 8'hBC) tps_pos = 1;
    else if (!k && d == 8'h4A && tps_pos >= 1 && tps_pos <= 3) begin
      tps_pos++;
      if (tps_pos == 4) begin tps_pos = 0; tps_seq++; if (tps_seq >= 4) eq_seen = 1; end
    end else tps_pos = 0;
    if (fill_chk) begin
      if (!(k && d == 8'hF7)) fail($sformatf("fill expected after training failure: %b %h", k, d));
      else fills_ok++;
    end
    // video lines
    if (vid_en && !in_line && k && d == 8'hFB) begin in_line = 1; vpos = 0; end
    if (vid_en && in_line) begin
      if (vpos == 1 && !fc_known) begin fc = d; fc_known = 1; end
      if (vpos == 0)       ok = k && d == 8'hFB;
      else if (vpos <= 16) ok = !k && d == fc + 8'(vpos - 1);
      else if (vpos == 17) ok = k && d == 8'hBC;
      else if (vpos == 18) ok = k && d == 8'hFD;
      else if (vpos <= 34) ok = !k && d == msa_exp(vpos - 19, fc);
      else if (vpos == 35) ok = k && d == 8'hFE;
      else if (vpos == 36) ok = k && d == 8'hF7;
      else                 ok = !k && d == 8'h00;
      if (!ok) fail($sformatf("video line pos %0d: k=%b d=%h (fc %h)", vpos, k, d, fc));
      vpos++;
      if (vpos == 40) begin vpos = 0; fc++; lines_ok++; end
    end
  endfunction

  // decode every 10 bits from the rise of lane_valid; a drop resyncs
  initial begin : lane_mon
    logic [9:0] code;
    bit rd, alive;
    int i;
    forever begin
      @(negedge clk);
      if (lane_valid === 1'b1 && rst_n) begin
        rd = 0; alive = 1; i = 9;
        cr_run = 0; tps_pos = 0;
        while (alive) begin
          code[i] = lane_p;
          if (i == 0) begin
            if (!dec_ok[{rd, code}]) fail($sformatf("8b/10b code %b invalid at RD%s", code, rd ? "+" : "-"));
            else begin symbol(dec_d[{rd, code}], dec_k[{rd, code}]); rd = dec_rd[{rd, code}]; end
            i = 9;
          end else i--;
          @(negedge clk);
          if (lane_valid !== 1'b1 || !rst_n) alive = 0;
        end
        in_line = 0;
      end
    end
  end

  // ------------------------------------------------------------ AUX sink
  localparam int F_OK = 0, F_SILENT = 1, F_NACK = 2, F_VIOL_SYNC = 3, F_VIOL_DATA = 4,
                 F_BADSYNC = 5, F_BADSTART = 6, F_STOP0 = 7, F_STOP1 = 8, F_LEN = 9,
                 F_HDRLO = 10, F_NKINDS = 11;
  int          fq [$];              // fault for each successive reply (F_OK when empty)
  int          delay_q [$];         // reply delay for each successive reply (default 6)
  int          cr_nd = 0, eq_nd = 0;  // polls answered "not done"
  logic [7:0]  dpcd [0:3];
  logic [7:0]  rom [0:15];
  logic [7:0]  i2c_off;
  int          exp_op = 0, n_req = 0, n_fault = 0;
  int          fault_hits [0:F_NKINDS-1];
  int          n_badsync = 0, n_nack = 0;
  logic        rc [$];              // reply chips

  // expected request of each link-training op: {cmd, addr, len, wdata}
  function automatic logic [35:0] op_req(input int op);
    case (op)
      0: op_req = {4'h8, 20'h00000, 4'd1, 8'h14};
      1: op_req = {4'h8, 20'h00001, 4'd1, 8'h01};
      2: op_req = {4'h8, 20'h00002, 4'd1, 8'h21};
      3: op_req = {4'h9, 20'h00003, 4'd1, 8'h00};
      4: op_req = {4'h8, 20'h00002, 4'd1, 8'h22};
      5: op_req = {4'h9, 20'h00003, 4'd1, 8'h00};
      6: op_req = {4'h0, 20'h05000, 4'd0, 8'h00};
      7: op_req = {4'h1, 20'h05000, 4'd8, 8'h00};
      default: op_req = {4'h8, 20'h00002, 4'd1, 8'h00};
    endcase
  endfunction

  function automatic void pb(input logic b); rc.push_back(b); rc.push_back(!b); endfunction
  function automatic void pbyte(input logic [7:0] v, input int viol_bit);
    for (int i = 7; i >= 0 && i >= viol_bit; i--)     // stops after the violation
      if (i == viol_bit) begin rc.push_back(v[i]); rc.push_back(v[i]); end
      else pb(v[i]);
  endfunction

  // build the reply chips for one request; rc ends where the sink lets go
  function automatic void build_reply(input int f, input logic [3:0] code, input int nbytes,
                                      input logic [63:0] data);
    int vpos, n;
    bit cut;
    logic c;
    rc.delete();
    cut = 0;
    vpos = 1 + $urandom % 15;
    if (f == F_BADSYNC && n_badsync++ < 2) vpos = 15;      // the last SYNC bit
    for (int i = 0; i < 16 && !cut; i++)
      if (f == F_BADSYNC && i == vpos) begin pb(1); cut = 1; end
      else if (f == F_VIOL_SYNC && i == vpos) begin
        c = $urandom; rc.push_back(c); rc.push_back(c); cut = 1;
      end else pb(0);
    if (cut) return;
    pb(f != F_BADSTART);
    if (f == F_BADSTART) return;
    n = nbytes;
    if (f == F_NACK) n = 0;
    if (f == F_LEN) n = nbytes == 0 ? 0 : $urandom % nbytes;
    vpos = (f == F_VIOL_DATA) ? $urandom % (8 * (n + 1)) : -1;
    pbyte({f == F_NACK ? code : 4'h0, f == F_HDRLO ? 4'(1 + $urandom % 15) : 4'h0},
          vpos >= 0 && vpos < 8 ? vpos : -1);
    if (vpos >= 0 && vpos < 8) return;
    if ((f == F_LEN && nbytes == 0) ||     // a data bit where the STOP belongs
        (f == F_NACK && nbytes > 0 && n_nack % 2 == 1)) begin
      pb($urandom);
      return;
    end
    for (int b = 0; b < n; b++) begin
      pbyte(b < 8 ? data[8*b +: 8] : 8'($urandom),
            vpos >= 8*(b+1) && vpos < 8*(b+2) ? vpos - 8*(b+1) : -1);
      if (vpos >= 8*(b+1) && vpos < 8*(b+2)) return;
    end
    rc.push_back(f != F_STOP0);
    rc.push_back(f != F_STOP1);
  endfunction

  bit link_alive, play;
  int dly;
  task automatic sample(output logic c);
    @(negedge clk);
    c = aux_line;
    if (!sink_present || !rst_n) link_alive = 0;
  endtask

  task automatic rx_bits(input int n, output logic [63:0] v, output bit ok);
    logic c0, c1;
    v = 0; ok = 1;
    for (int i = 0; i < n; i++) begin
      sample(c0); sample(c1);
      if (c0 === c1) ok = 0;
      v = {v[62:0], c0};
    end
  endtask

  // serve one request; returns when the reply has been played (or dropped)
  task automatic serve;
    logic [63:0] v, rdata;
    bit ok, good, done;
    logic c0, c1;
    logic [3:0] cmd, len;
    logic [19:0] addr;
    logic [7:0] wd, st;
    logic [35:0] e;
    int f;
    link_alive = 1;
    rx_bits(16, v, ok);
    if (link_alive && (!ok || v[15:0] != 0)) fail("request SYNC");
    rx_bits(1, v, ok);
    if (link_alive && (!ok || v[0] != 1)) fail("request start bit");
    rx_bits(32, v, ok);
    if (link_alive && !ok) fail("request header chips");
    cmd = v[31:28]; addr = v[27:8]; len = v[3:0];
    if (link_alive && v[7:4] != 0) fail("request len byte high nibble");
    wd = 0;
    if (link_alive && (cmd == 4'h8 || cmd == 4'h0) && len != 0) begin
      rx_bits(8, v, ok);
      if (link_alive && !ok) fail("request data chips");
      wd = v[7:0];
    end
    sample(c0); sample(c1);
    if (link_alive && (c0 !== 1 || c1 !== 1)) fail("request STOP");
    if (link_alive && aux_tx_en !== 0) fail("source still drives the AUX pair after STOP");
    play = 0;
    if (link_alive) begin
    n_req++;
    e = op_req(exp_op);
    if ({cmd, addr, len, wd} != e)
      fail($sformatf("request %h %h %h %h, expected op %0d = %h", cmd, addr, len, wd, exp_op, e));
    // the sink's answer
    f = fq.size() ? fq.pop_front() : F_OK;
    dly = delay_q.size() ? delay_q.pop_front() : 6;
    fault_hits[f]++;
    rdata = 0;
    done = 1;
    case (cmd)
      4'h8: if (f == F_OK || f == F_HDRLO) dpcd[addr[1:0]] = wd;
      4'h9: begin
        st = {6'($urandom), eq_seen, cr_seen};
        if (exp_op == 3 && cr_nd > 0) begin st[0] = 0; if (f == F_OK || f == F_HDRLO) cr_nd--; end
        if (exp_op == 5 && eq_nd > 0) begin st[1] = 0; if (f == F_OK || f == F_HDRLO) eq_nd--; end
        rdata[7:0] = st;
        done = exp_op == 3 ? st[0] : st[1];
      end
      4'h0: if (f == F_OK || f == F_HDRLO) i2c_off = addr[7:0];
      default: for (int i = 0; i < 8; i++) rdata[8*i +: 8] = rom[(i2c_off + i) % 16];
    endcase
    good = (f == F_OK || f == F_HDRLO);
    if (good && done) exp_op++;
    if (good && exp_op == 3 && cmd == 4'h8) begin cr_seen = 0; cr_run = 0; end   // TP_CR written
    if (good && exp_op == 5 && cmd == 4'h8) begin eq_seen = 0; tps_seq = 0; end  // TP_TPS1 written
    if (f != F_SILENT) begin
      if (f == F_NACK) n_nack++;
      // NACK, DEFER, I2C NACK, I2C DEFER in turn
      build_reply(f, 4'(1 << (n_nack % 4)), (cmd == 4'h9 || cmd == 4'h1) ? int'(len) : 0, rdata);
      play = 1;
    end
    end
  endtask

  // play the reply chips after the reply delay; HPD low / reset drops it
  task automatic play_reply;
    while (dly > 0 && sink_present && rst_n) begin @(negedge clk); dly--; end
    while (rc.size() > 0 && sink_present && rst_n) begin
      @(negedge clk);
      if (sink_present && rst_n) begin sink_drv = 1; sink_val = rc.pop_front(); end
    end
    @(negedge clk);
    sink_drv = 0; sink_val = 1;
    rc.delete();
  endtask

  initial begin : sink
    for (int i = 0; i < F_NKINDS; i++) fault_hits[i] = 0;
    forever begin
      @(posedge aux_tx_en);
      if (sink_present && rst_n) begin
        serve();
        if (play) play_reply();
      end
    end
  end

  // ------------------------------------------------------------ sessions
  function automatic void new_sink;
    for (int i = 0; i < 4; i++) dpcd[i] = 0;
    for (int i = 0; i < 16; i++) rom[i] = $urandom;
    i2c_off = 8'hFF;
    exp_op = 0; n_req = 0;
    fq.delete(); delay_q.delete();
    cr_nd = 0; eq_nd = 0;
    cr_seen = 0; eq_seen = 0;
    vid_en = 0; in_line = 0; fc_known = 0; fill_chk = 0;
  endfunction

  task automatic unplug;
    sink_present = 0;
    cycles(2);
    if (lane_valid !== 0 || aux_tx_en !== 0 || edid_valid !== 0 || train_fail !== 0 ||
        irq !== 0 || link_trained !== 0)
      fail("outputs after HPD low");
    fill_chk = 0; vid_en = 0;
    cycles(3 + $urandom % 20);
  endtask

  // plug in and wait for the training result
  task automatic plug(input bit exp_ok);
    int t;
    sink_present = 1;
    t = 0;
    while (link_trained !== 1 && train_fail !== 1 && t < 200000) begin @(negedge clk); t++; end
    if (exp_ok) begin
      if (link_trained !== 1) fail($sformatf("training did not complete (op %0d)", exp_op));
      else begin
        if (dpcd[0] != 8'h14 || dpcd[1] != 8'h01 || dpcd[2] != 8'h00)
          fail($sformatf("DPCD %h %h %h", dpcd[0], dpcd[1], dpcd[2]));
        if (edid_valid !== 1 || edid !== {rom[7], rom[6], rom[5], rom[4], rom[3], rom[2], rom[1], rom[0]})
          fail($sformatf("EDID %h", edid));
        if (irq !== 0) fail("irq after successful training");
        if (exp_op != 9) fail("ops after training");
      end
    end else begin
      if (train_fail !== 1 || irq !== 1) fail($sformatf("training did not fail (op %0d)", exp_op));
      cycles(200);
      if (link_trained !== 0 || train_fail !== 1) fail("train_fail not sticky");
    end
  endtask

  task automatic hard_reset;
    rst_n = 0;
    sink_present = 0;
    sink_drv = 0; sink_val = 1;
    cycles(3);
    if (lane_valid !== 0 || aux_tx_en !== 0 || aux_tx_p !== 1 || edid_valid !== 0 || edid !== 0 ||
        irq !== 0 || link_trained !== 0 || train_fail !== 0 || lane_p !== 0)
      fail("reset values");
    rst_n = 1;
    cycles(2);
  endtask

  task automatic watch_video(input int n);
    int t;
    lines_ok = 0; fc_known = 0; in_line = 0;
    vid_en = 1;
    t = 0;
    while (lines_ok < n && t < 500 * n + 1000) begin @(negedge clk); t++; end
    if (lines_ok < n) fail($sformatf("video lines %0d of %0d", lines_ok, n));
    vid_en = 0;
  endtask

  // fail op `op` `k` times in a row with fault kinds starting at kind `f0`
  task automatic op_faults(input int op, input int k, input int f0);
    int f;
    new_sink();
    for (int i = 0; i < op; i++) fq.push_back(F_OK);
    for (int i = 0; i < k; i++) begin
      f = f0 + i;
      f = 1 + f % (F_NKINDS - 2);             // F_SILENT .. F_LEN
      // a reply length fault needs a request with data to shorten or extend
      fq.push_back(f);
    end
  endtask

  // ------------------------------------------------------------ test
  initial begin
    int fk;
    cycles(3);
    if (lane_valid !== 0 || aux_tx_en !== 0 || irq !== 0) fail("reset state");
    rst_n = 1;
    cycles(5);
    if (lane_valid !== 0 || aux_tx_en !== 0) fail("activity without HPD");

    // ---- clean training, EDID, 140 video lines (frame counter past 128)
    new_sink();
    plug(1);
    watch_video(260);                       // every pixel value, counter wraps
    unplug();

    // ---- one failed attempt per op (each fault kind in turn), then success
    fk = 0;
    for (int rep = 0; rep < 3; rep++)
      for (int op = 0; op < 9; op++) begin
        op_faults(op, 1, fk); fk++;
        fq.push_back(F_HDRLO);                // accepted: header low nibble ignored
        plug(1);
        unplug();
      end
    // ---- four failed attempts per op: training fails, fill on the lane
    for (int op = 0; op < 9; op++) begin
      op_faults(op, 4, fk); fk += 4;
      plug(0);
      if (n_req != op + 4) fail($sformatf("op %0d: %0d requests", op, n_req));
      fill_chk = 1; cycles(300); fill_chk = 0;
      unplug();
    end
    // ---- polls answered "not done"
    new_sink(); cr_nd = 1; plug(1); unplug();
    new_sink(); eq_nd = 3; plug(1); unplug();
    new_sink(); cr_nd = 4; plug(0); unplug();
    new_sink(); eq_nd = 4; plug(0); unplug();
    new_sink(); cr_nd = 2; fq.push_back(F_OK); fq.push_back(F_OK); fq.push_back(F_OK);
    fq.push_back(F_OK); fq.push_back(F_NACK); plug(1); unplug();     // not-done then error
    // ---- reply delays
    new_sink();
    for (int i = 0; i < 9; i++) delay_q.push_back(1 + $urandom % 150);
    plug(1); unplug();
    new_sink(); delay_q.push_back(198); plug(1); unplug();   // reply on the last cycle of the wait

    // ---- HPD low during a request, a reply, the CR phase, video, failure
    new_sink(); sink_present = 1;
    while (aux_tx_en !== 1) @(negedge clk);
    cycles(20 + $urandom % 40); unplug();
    new_sink(); sink_present = 1;
    while (!sink_drv) @(negedge clk);
    cycles(10 + $urandom % 30); unplug();
    new_sink(); sink_present = 1;
    while (exp_op != 3) @(negedge clk);
    cycles(100); unplug();
    new_sink(); plug(1); cycles(1000); unplug();
    new_sink(); for (int i = 0; i < 4; i++) fq.push_back(F_SILENT); plug(0); unplug();
    new_sink(); plug(1); watch_video(3); unplug();

    // ---- reset with traffic in flight
    new_sink(); sink_present = 1;
    while (exp_op != 4) @(negedge clk);
    cycles($urandom % 200);
    hard_reset();
    cycles(5);
    new_sink(); plug(1); watch_video(2);
    hard_reset();
    cycles(5);
    new_sink(); plug(1); watch_video(2);
    cycles(100);

    for (int i = 1; i < F_NKINDS; i++)
      if (fault_hits[i] == 0) fail($sformatf("fault kind %0d never injected", i));
    if (errors == 0) $display("TEST PASSED: DisplayPort2");
    else $display("TEST FAILED: DisplayPort2 (%0d errors)", errors);
    $finish;
  end

  initial begin
    #80ms;
    $display("TEST FAILED: DisplayPort2 (timeout)");
    $finish;
  end

endmodule
