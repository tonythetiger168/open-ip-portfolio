// SPDX-License-Identifier: Apache-2.0
// DisplayPort2-specific part of tb/DisplayPort2_apb_tb.sv. The sink model
// of tb/DisplayPort2_tb.sv: a main-lane decoder (8b/10b tables built from
// the standard, training-pattern and video-line checks) and an AUX sink
// (DPCD window, EDID ROM over I2C-over-AUX, injected reply faults).
// Checked: training to the end with STATUS read along the way (lane up,
// trained, EDID valid), the EDID bytes in EDID0 / EDID1 against the sink's
// ROM, video lines on the lane, training failure (four faulty replies to
// one operation) with STATUS.train_fail and fill on the lane, HPD low
// clearing everything, the sink re-plugged with new EDID data.
// Covered through the registers: TRAINED and TRAIN_FAIL (both held by the
// core), masked, raising irq and cleared.
logic sink_drv = 0, sink_val = 1;
wire  aux_line = aux_tx_en ? aux_tx_p : (sink_drv ? sink_val : 1'b1);
always @* aux_rx_p = aux_line;
initial sink_present = 0;

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
    @(negedge PCLK);
    if (lane_valid === 1'b1 && PRESETN) begin
      rd = 0; alive = 1; i = 9;
      cr_run = 0; tps_pos = 0;
      while (alive) begin
        code[i] = lane_p;
        if (i == 0) begin
          if (!dec_ok[{rd, code}]) fail($sformatf("8b/10b code %b invalid at RD%s", code, rd ? "+" : "-"));
          else begin symbol(dec_d[{rd, code}], dec_k[{rd, code}]); rd = dec_rd[{rd, code}]; end
          i = 9;
        end else i--;
        @(negedge PCLK);
        if (lane_valid !== 1'b1 || !PRESETN) alive = 0;
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
  @(negedge PCLK);
  c = aux_line;
  if (!sink_present || !PRESETN) link_alive = 0;
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
  while (dly > 0 && sink_present && PRESETN) begin @(negedge PCLK); dly--; end
  while (rc.size() > 0 && sink_present && PRESETN) begin
    @(negedge PCLK);
    if (sink_present && PRESETN) begin sink_drv = 1; sink_val = rc.pop_front(); end
  end
  @(negedge PCLK);
  sink_drv = 0; sink_val = 1;
  rc.delete();
endtask

initial begin : sink
  for (int i = 0; i < F_NKINDS; i++) fault_hits[i] = 0;
  forever begin
    @(posedge aux_tx_en);
    if (sink_present && PRESETN) begin
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

// STATUS bits: {edid_valid, train_fail, link_trained, lane_valid}
localparam logic [31:0] S_LANE = 1, S_TRAINED = 2, S_FAIL = 4, S_EDID = 8;
task automatic plug_ok;
  int t;
  sink_present = 1;
  t = 0;
  rd(A_STATUS);
  while (!rdv[1] && !rdv[2] && t < 20000) begin rd(A_STATUS); t++; end
  if (rdv !== (S_LANE | S_TRAINED | S_EDID)) fail($sformatf("STATUS %h after training (op %0d)", rdv, exp_op));
  if (dpcd[0] != 8'h14 || dpcd[1] != 8'h01 || dpcd[2] != 8'h00) fail("DPCD after training");
  rd_exp(A_EDID0, {rom[3], rom[2], rom[1], rom[0]});
  rd_exp(A_EDID1, {rom[7], rom[6], rom[5], rom[4]});
  rd(A_IRQ_STATUS);
  if (rdv !== (32'(1) << IRQ_TRAINED)) fail($sformatf("IRQ_STATUS %h after training", rdv));
  if (!irq) fail("irq low with TRAINED set");
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_TRAINED]) fail("TRAINED not held while trained");
endtask
task automatic plug_fail(input bit e_edid);
  int t;
  logic [31:0] e;
  e = S_LANE | S_FAIL | (e_edid ? S_EDID : 0);
  sink_present = 1;
  t = 0;
  rd(A_STATUS);
  while (!rdv[1] && !rdv[2] && t < 20000) begin rd(A_STATUS); t++; end
  if (rdv !== e) fail($sformatf("STATUS %h after a failed training (op %0d)", rdv, exp_op));
  rd(A_IRQ_STATUS);
  if (rdv !== (32'(1) << IRQ_TRAIN_FAIL)) fail($sformatf("IRQ_STATUS %h after a failed training", rdv));
  if (!irq) fail("irq low with TRAIN_FAIL set");
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_TRAIN_FAIL);   // held
  fill_chk = 1; cycles(200); fill_chk = 0;
  rd_exp(A_STATUS, e);
endtask
task automatic unplug;
  sink_present = 0;
  cycles(2);
  rd_exp(A_STATUS, 0);
  fill_chk = 0; vid_en = 0;
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_IRQ_STATUS, 0);
  cycles(3 + $urandom % 20);
endtask
task automatic watch_video(input int n);
  int t;
  lines_ok = 0; fc_known = 0; in_line = 0;
  vid_en = 1;
  t = 0;
  while (lines_ok < n && t < 500 * n + 1000) begin @(negedge PCLK); t++; end
  if (lines_ok < n) fail($sformatf("video lines %0d of %0d", lines_ok, n));
  vid_en = 0;
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  rd_exp(A_EDID0, 0); rd_exp(A_EDID1, 0);
  // clean sessions with new EDID data each time
  for (int s = 0; s < 4; s++) begin
    new_sink();
    if (s == 0) for (int i = 0; i < 8; i++) rom[i] = 8'hFF;
    if (s == 1) for (int i = 0; i < 8; i++) rom[i] = 8'h00;
    plug_ok();
    watch_video(3);
    unplug();
  end
  // training failure: four faulty replies to one operation
  for (int op = 0; op < 9; op += 4) begin
    new_sink();
    for (int i = 0; i < op; i++) fq.push_back(F_OK);
    for (int i = 0; i < 4; i++) fq.push_back(F_SILENT);
    plug_fail(op == 8);
    unplug();
  end
  // one fault then success
  new_sink(); fq.push_back(F_NACK); plug_ok(); unplug();
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  new_sink();
  for (int i = 0; i < 4; i++) fq.push_back(F_SILENT);
  sink_present = 1;
  while (train_fail !== 1) @(negedge PCLK);
  sink_present = 0;
  cycles(2);
  new_sink();
  sink_present = 1;
  while (link_trained !== 1) @(negedge PCLK);
  cycles(3);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
