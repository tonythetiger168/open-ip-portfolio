// SPDX-License-Identifier: Apache-2.0
// Host model of the CXL TBs (included by tb/CXL_tb.sv and, through
// tb/apb/CXL_apb_func.svh, by tb/CXL_apb_tb.sv): a CXL host on the device's
// 256-byte flit link.
//  - M2S: Req, RwD (header, byte enables, 4 data slots) and BIRsp messages
//    wait in queues and are packed into CXL.cachemem flits unit by unit
//    (random empty units, RwD headers only in the first unit of a G slot,
//    data rolling over into the next flit), within the device's credits;
//    CXL.io flits and NOP flits (credits only) are mixed in. Each flit gets
//    its sequence number and CRC; FEC and reserved bytes are random. Beats
//    go out with random gaps. Error flits on request: bad CRC, reserved
//    type, a skipped sequence number, a reserved unit code, an RwD header in
//    a second unit.
//  - S2M: every flit is checked (CRC, sequence, zero FEC and reserved
//    bits, empty units zero) and parsed: NDR, DRS with its line, BISnp,
//    credits, CXL.io payload.
//  - A reference memory (data, meta state, poison) predicts every
//    response; the host keeps at most one transaction on a line
//    outstanding, so the device's order between its queues cannot change a
//    result (except in the conflict phase, where only tags are checked).
//  - BISnp: answered by a BIRsp (legal at random, or illegal / stale on
//    request), after a write-back first at random; if the line has a
//    transaction outstanding the host sends BIConflict first and waits for
//    the BIConflictAck: a response before it means the transaction was
//    served first, else it is served after the BIRsp and its expectation is
//    recomputed from the new state.
// Before the include: `define CXL_CLK (clock), `define CXL_C (path of the
// core instance), and the link and CXL.io signals, rst_n, LINES, RQD, WQD,
// IOD, SFE, bi_en and fail(string).

localparam logic [63:0] H_POLY = 64'h42F0E1EBA9EA3693;
function automatic logic [63:0] h_crc(input logic [63:0] c, input logic [63:0] d, input int n);
  logic [63:0] r;
  r = c;
  for (int i = n - 1; i >= 0; i--) r = {r[62:0], 1'b0} ^ ({64{r[63] ^ d[i]}} & H_POLY);
  return r;
endfunction
function automatic logic [63:0] u_req(input logic [3:0] op, input logic [1:0] mf, input logic [1:0] mv,
                                      input logic [2:0] snp, input logic [15:0] tag, input logic [15:0] a);
  return {16'd0, a, tag, 1'b0, snp, mv, mf, op, 4'd1};
endfunction
function automatic logic [63:0] u_rwd(input logic [3:0] op, input logic [1:0] mf, input logic [1:0] mv,
                                      input logic [2:0] snp, input bit po, input logic [15:0] tag,
                                      input logic [15:0] a);
  return {16'd0, a, tag, po, snp, mv, mf, op, 4'd2};
endfunction
function automatic logic [63:0] u_bir(input logic [3:0] op, input logic [11:0] tag);
  return {44'd0, tag, op, 4'd3};
endfunction

// ---------------- reference ----------------
logic [511:0] rm [0:LINES-1];
logic [1:0]   rmt [0:LINES-1];
bit           rps [0:LINES-1];
int           busy [0:LINES-1];
bit           snp_pend [0:LINES-1];          // a BISnp on the line is being answered
logic [15:0]  hdm_base = 0;
// outstanding responses: kind 1 NDR, 2 DRS; chk 0: tag and kind only;
// sm / nmv: the transaction sets the line's meta state to nmv
int           e_tag [$], e_kind [$], e_ln [$];
logic [2:0]   e_op [$];
logic [1:0]   e_mv [$], e_nmv [$];
bit           e_po [$], e_chk [$], e_sm [$];
logic [511:0] e_line [$];
bit           tag_used [0:65535];
int           x_range = 0, x_opcode = 0, x_proto = 0, x_poison = 0, x_crc = 0, x_seq = 0, x_fmt = 0, x_ovf = 0;
int           n_range = 0, n_opcode = 0, n_proto = 0, n_poison = 0, n_crc = 0, n_seq = 0, n_fmt = 0, n_ovf = 0;
int           n_ndr = 0, n_drs = 0, n_bis = 0, n_ack = 0, n_iof = 0, n_dio = 0, n_flit = 0;
bit           hz = 0;                          // conflict phase
int           hz_lines = 2;
int           p_out = 10;                      // % out of range
int           f_off = -100, f_po = -1, f_dp = -1;   // forced line offset, poison, data byte (directed)
int           f_mf = -1, f_mv = -1;            // forced meta field / value (directed)
bit           stop = 0;

task automatic ref_clear();
  for (int l = 0; l < LINES; l++) begin rm[l] = '0; rmt[l] = 2'b00; rps[l] = 0; busy[l] = 0; snp_pend[l] = 0; end
endtask
task automatic ref_from_dut();
  for (int l = 0; l < LINES; l++) begin
    for (int b = 0; b < 8; b++) rm[l][64 * b +: 64] = `CXL_C.mem[l * 8 + b];
    rmt[l] = `CXL_C.meta[l]; rps[l] = `CXL_C.pois[l];
  end
endtask
task automatic exp_clear();
  e_tag.delete(); e_kind.delete(); e_ln.delete(); e_op.delete(); e_mv.delete(); e_nmv.delete(); e_po.delete();
  e_chk.delete(); e_sm.delete(); e_line.delete();
  for (int t = 0; t < 65536; t++) tag_used[t] = 0;
  for (int l = 0; l < LINES; l++) busy[l] = 0;
endtask
// cl: pick_addr already counted the line busy (it claims a free line at
// once, since a task call may let another driver run in between)
task automatic exp_add(input int tag, input int kind, input int ln, input logic [2:0] op, input logic [1:0] mv,
                       input bit po, input logic [511:0] line, input bit sm, input logic [1:0] nmv, input bit cl);
  e_tag.push_back(tag); e_kind.push_back(kind); e_ln.push_back(ln); e_op.push_back(op); e_mv.push_back(mv);
  e_po.push_back(po); e_line.push_back(line); e_chk.push_back(!hz); e_sm.push_back(sm); e_nmv.push_back(nmv);
  tag_used[tag] = 1;
  if (ln >= 0 && !cl) busy[ln]++;
endtask
function automatic int exp_find(input int tag, input int kind);
  for (int i = 0; i < e_tag.size(); i++) if (e_tag[i] == tag && e_kind[i] == kind) return i;
  return -1;
endfunction
function automatic int exp_line(input int ln);
  for (int i = 0; i < e_tag.size(); i++) if (e_ln[i] == ln) return i;
  return -1;
endfunction
task automatic exp_del(input int i);
  tag_used[e_tag[i]] = 0;
  if (e_ln[i] >= 0) busy[e_ln[i]]--;
  e_tag.delete(i); e_kind.delete(i); e_ln.delete(i); e_op.delete(i); e_mv.delete(i); e_nmv.delete(i);
  e_po.delete(i); e_chk.delete(i); e_sm.delete(i); e_line.delete(i);
endtask
function automatic logic [15:0] new_tag();
  logic [15:0] t;
  t = $urandom;
  while (tag_used[t]) t = $urandom;
  return t;
endfunction

// ---------------- host link state ----------------
int           hc_req = 0, hc_rwd = 0, hc_bir = 0, hc_io = 0;      // credits from the device
int           ho_ndr = 0, ho_drs = 0, ho_bis = 0, ho_io = 0;      // credits owed to the device
int           h_crd_mode = 0;                  // 0 all, 1 one per flit, 2 none, 3 all but BISnp
logic [63:0]  hq_req [$], hq_bir [$], hq_rh [$], hq_rbe [$], hq_rd [$], hq_io [$];
int           hq_bln [$];                      // the line of each BIRsp (-1: none)
int           hq_io_n = 0;                     // complete CXL.io flits in hq_io
logic [63:0]  hio_exp [$];                     // CXL.io beats the device must deliver
int           h_owe = 0;                       // data units owed in the current RwD
bit           h_ovf = 0;                       // send Req and CXL.io flits without credit
int           h_gap = 20;                      // % empty units
int           h_beat_gap = 1;                  // 0 none, else gaps between beats
bit           h_hold = 0;                      // send nothing
int           h_err = 0;                       // next error: 1 CRC, 2 type 3, 3 seq skip, 4 reserved unit, 5 odd RwD,
                                               // 7 type 3 with a seq skip
logic [7:0]   h_seq = 0;
logic [63:0]  fb [0:31];
bit           h_busy = 0;                      // a flit is being sent

function automatic int crd_n(input int c);
  return h_crd_mode == 2 ? 0 : h_crd_mode == 1 ? (c > 0 ? 1 : 0) : (c > 15 ? 15 : c);
endfunction
// finish fb: header, CRD, CRC, FEC; corrupt: flip one bit
task automatic flit_close(input logic [1:0] typ, input bit crd, input bit corrupt);
  logic [63:0] c;
  logic [15:0] cr;
  fb[0][15:0] = {h_seq, 6'($urandom), typ};
  cr = 16'd0;
  if (crd) begin
    cr = {4'(crd_n(ho_io)), 4'(h_crd_mode == 3 ? 0 : crd_n(ho_bis)), 4'(crd_n(ho_drs)), 4'(crd_n(ho_ndr))};
    ho_io -= cr[15:12]; ho_bis -= cr[11:8]; ho_drs -= cr[7:4]; ho_ndr -= cr[3:0];
  end
  c = '1;
  for (int b = 0; b < 30; b++) c = h_crc(c, fb[b], 64);
  c = h_crc(c, {48'd0, cr}, 16);
  fb[30] = {c[47:0], cr};
  fb[31] = {16'($urandom), 32'($urandom), c[63:48]};
  if (corrupt) begin : b_cor
    int b, k;
    b = $urandom % 32; k = $urandom % 64;
    if (b == 31) k = k % 16;                    // the FEC is not checked
    fb[b][k] = ~fb[b][k];
  end
endtask

// a CXL.cachemem flit from the queues
task automatic build_cm();
  bit          be_next, c_rq, c_bi, c_rw;
  logic [63:0] be_u;
  int          r, bl;
  be_next = 0; be_u = 0;
  fb[0] = {16'($urandom), 32'($urandom), 16'd0};
  for (int j = 1; j < 30; j++) begin
    c_rq = hq_req.size() > 0 && (hc_req > 0 || h_ovf);
    c_bi = hq_bir.size() > 0 && (hc_bir > 0 || h_ovf);
    c_rw = j % 2 == 0 && j <= 28 && hq_rh.size() > 0 && (hc_rwd > 0 || h_ovf);
    if (be_next) begin
      fb[j] = be_u;
      be_next = 0;
    end else if (j >= 2 && h_owe > 0) begin
      fb[j] = hq_rd.pop_front();
      h_owe--;
    end else if (h_err == 4 && $urandom % 4 == 0) begin
      fb[j] = {60'($urandom), 4'(4 + $urandom % 12)};
      x_fmt++; h_err = 0;
    end else if (h_err == 5 && j % 2 == 1) begin
      fb[j] = {32'($urandom), 28'($urandom), 4'd2};
      x_fmt++; h_err = 0;
    end else if ($urandom % 100 < h_gap && !(j == 1 && h_owe > 0) || !(c_rq || c_bi || c_rw)) begin
      fb[j] = 64'd0;
    end else begin
      r = $urandom % 3;
      while (!(r == 0 && c_rq || r == 1 && c_bi || r == 2 && c_rw)) r = (r + 1) % 3;
      if (r == 0) begin
        fb[j] = hq_req.pop_front();
        hc_req--;
      end else if (r == 1) begin
        fb[j] = hq_bir.pop_front();
        hc_bir--;
        // later messages to the line go into later flits, after the BIRsp
        bl = hq_bln.pop_front();
        if (bl >= 0) snp_pend[bl] = 0;
      end else begin
        fb[j] = hq_rh.pop_front();
        be_u = hq_rbe.pop_front();
        be_next = 1;
        h_owe = fb[j][7:4] == 4'd4 ? 0 : 8;
        hc_rwd--;
      end
    end
  end
endtask
task automatic build_io();
  logic [63:0] w, p;
  p = 0;
  for (int j = 0; j < 30; j++) begin
    w = hq_io.pop_front();
    fb[j] = j == 0 ? {w[47:0], 16'd0} : {w[47:0], p[63:48]};
    p = w;
  end
  hq_io_n--;
  hc_io--;
endtask
task automatic send_flit();
  for (int b = 0; b < 32 && rst_n; b++) begin
    rx_valid = 1; rx_data = fb[b];
    @(negedge `CXL_CLK);
    rx_valid = 0;
    if (h_beat_gap != 0 && $urandom % 4 == 0) repeat ($urandom % (h_beat_gap + 1)) @(negedge `CXL_CLK);
  end
  rx_valid = 0;
  h_seq++;
  n_flit++;
endtask
function automatic bit cm_ready();
  return h_owe > 0 || (hq_req.size() > 0 || hq_bir.size() > 0 || hq_rh.size() > 0) && h_ovf ||
         hq_req.size() > 0 && hc_req > 0 || hq_bir.size() > 0 && hc_bir > 0 || hq_rh.size() > 0 && hc_rwd > 0;
endfunction
// one flit, if there is anything to send
task automatic host_flit();
  bit cm, io, crd;
  cm = cm_ready();
  io = hq_io_n > 0 && (hc_io > 0 || h_ovf);
  crd = h_crd_mode != 2 && (ho_ndr > 0 || ho_drs > 0 || ho_bis > 0 && h_crd_mode != 3 || ho_io > 0);
  h_busy = h_err == 1 && h_owe == 0 || h_err == 2 || h_err == 7 || io || cm || crd;
  if (h_err == 1 && h_owe == 0 || h_err == 2 || h_err == 7) begin
    // a junk flit: dropped whole by the device
    for (int j = 0; j < 30; j++) fb[j] = {$urandom, $urandom};
    if (h_err == 1) begin
      for (int j = 1; j < 30; j++) fb[j][3:0] = 4'd0;
      flit_close(2'd2, 0, 1); x_crc++;
    end else begin
      if (h_err == 7) begin h_seq += 8'(1 + $urandom % 200); x_seq++; end
      flit_close(2'd3, 0, 0); x_fmt++;
    end
    h_err = 0;
    send_flit();
  end else if (io && (!cm || $urandom % 2)) begin
    build_io();
    if (h_err == 3) begin h_seq += 8'(1 + $urandom % 200); x_seq++; h_err = 0; end
    flit_close(2'd1, 1, 0);
    send_flit();
  end else if (cm) begin
    build_cm();
    if (h_err == 3) begin h_seq += 8'(1 + $urandom % 200); x_seq++; h_err = 0; end
    flit_close(2'd2, 1, 0);
    send_flit();
  end else if (crd) begin
    for (int j = 0; j < 30; j++) fb[j] = j == 0 ? {16'($urandom), 32'($urandom), 16'd0} : 64'd0;
    flit_close(2'd0, 1, 0);
    send_flit();
  end else @(negedge `CXL_CLK);
  h_busy = 0;
endtask
initial begin
  rx_valid = 0; rx_data = 0;
  forever begin
    if (rst_n && !h_hold) host_flit();
    else @(negedge `CXL_CLK);
  end
end

// ---------------- the device's CXL.io source and sink ----------------
logic [63:0]  dio_q [$], dio_exp [$];          // beats to offer, beats the host must see
int           dio_gap = 20, io_rx_mode = 0;
initial begin
  io_tx_valid = 0; io_tx_data = 0;
  forever begin
    @(negedge `CXL_CLK);
    if (dio_q.size() > 0 && rst_n && $urandom % 100 >= dio_gap) begin
      io_tx_valid = 1; io_tx_data = dio_q[0];
      @(posedge `CXL_CLK);
      while (!io_tx_ready && rst_n) @(posedge `CXL_CLK);
      if (rst_n) io_tx_data = dio_q.pop_front();
      @(negedge `CXL_CLK);
      io_tx_valid = 0; io_tx_data = {$urandom, $urandom};
    end
  end
end
task automatic dio_flit();
  logic [63:0] w;
  for (int k = 0; k < 30; k++) begin
    w = {$urandom, $urandom};
    dio_q.push_back(w);
    dio_exp.push_back(k == 29 ? {16'd0, w[47:0]} : w);
  end
endtask
task automatic hio_flit();
  logic [63:0] w;
  for (int k = 0; k < 30; k++) begin
    w = {$urandom, $urandom};
    hq_io.push_back(w);
    hio_exp.push_back(k == 29 ? {16'd0, w[47:0]} : w);
  end
  hq_io_n++;
endtask
always @(negedge `CXL_CLK)
  case (io_rx_mode)
    0: io_rx_ready = 1;
    1: io_rx_ready = $urandom % 2;
    2: io_rx_ready = $urandom % 8 == 0;
    default: io_rx_ready = 0;
  endcase
int io_rx_beat = 0;
logic [63:0] hio_w, dio_w;
always @(posedge `CXL_CLK or negedge rst_n)
  if (!rst_n) io_rx_beat = 0;
  else if (io_rx_valid && io_rx_ready) begin
    if (hio_exp.size() == 0) fail("CXL.io beat with none expected");
    else begin
      if (io_rx_data !== hio_exp[0]) fail($sformatf("CXL.io rx beat %0d: %h, expected %h", io_rx_beat, io_rx_data, hio_exp[0]));
      hio_w = hio_exp.pop_front();
    end
    if (io_rx_last != (io_rx_beat == 29)) fail($sformatf("CXL.io rx last on beat %0d", io_rx_beat));
    io_rx_beat = (io_rx_beat + 1) % 30;
    if (io_rx_beat == 0) n_iof++;
  end

// ---------------- S2M ----------------
int           tx_mode = 0;
always @(negedge `CXL_CLK)
  case (tx_mode)
    0: tx_ready = 1;
    1: tx_ready = $urandom % 2;
    2: tx_ready = $urandom % 6 == 0;
    3: tx_ready = $urandom % 4 != 0;
    default: tx_ready = 0;
  endcase
logic [63:0]  hr [0:31];
int           hj = 0;
logic [7:0]   hx_seq = 0;
// the DRS line being received
bit           hd_owe = 0;
int           hd_cnt = 0, hd_idx = -1;
logic [15:0]  hd_tag = 0;
logic [511:0] hd_ln = 0, hd_got = 0;
logic [1:0]   hd_mv = 0;
bit           hd_po = 0;
// BISnps to answer
logic [3:0]   bq_op [$];
logic [11:0]  bq_tag [$];
logic [15:0]  bq_addr [$];
// a conflict being resolved
int           cf_line = -1;
bit           cf_ack = 0, cf_first = 0;        // the BIConflictAck arrived; before the line's response
int           cf_tag = -1;

task automatic h_ndr(input logic [63:0] u);
  int i;
  n_ndr++;
  ho_ndr++;
  if (u[63:32] != 0 || u[15:12] != 0 || u[7] != 0) fail($sformatf("NDR unit %h: reserved bits", u));
  i = exp_find(u[31:16], 1);
  if (i < 0) fail($sformatf("NDR tag %h not outstanding", u[31:16]));
  else begin
    if (e_chk[i] && (u[6:4] != e_op[i] || u[9:8] != e_mv[i]))
      fail($sformatf("NDR tag %h line %0d: opcode %0d meta %b, expected %0d %b", u[31:16], e_ln[i], u[6:4], u[9:8], e_op[i], e_mv[i]));
    if (e_op[i] == 3'd4 && e_tag[i] == cf_tag) begin
      cf_ack = 1; cf_first = cf_line >= 0 && busy[cf_line] != 0; n_ack++;
    end
    exp_del(i);
  end
endtask
task automatic h_drs_start(input logic [63:0] u);
  n_drs++;
  ho_drs++;
  if (u[63:32] != 0 || u[15:13] != 0 || u[7:4] != 0) fail($sformatf("DRS unit %h: reserved bits", u));
  hd_owe = 1; hd_cnt = 0; hd_tag = u[31:16]; hd_mv = u[9:8]; hd_po = u[12];
  hd_idx = exp_find(hd_tag, 2);
  if (hd_idx < 0) fail($sformatf("DRS tag %h not outstanding", hd_tag));
  else if (e_chk[hd_idx] && (hd_mv != e_mv[hd_idx] || hd_po != e_po[hd_idx]))
    fail($sformatf("DRS tag %h line %0d: meta %b poison %0d, expected %b %0d", hd_tag, e_ln[hd_idx], hd_mv, hd_po, e_mv[hd_idx], e_po[hd_idx]));
endtask
task automatic h_drs_data(input logic [63:0] u);
  hd_got[64 * hd_cnt +: 64] = u;
  hd_cnt++;
  if (hd_cnt == 8) begin
    hd_owe = 0;
    hd_idx = exp_find(hd_tag, 2);
    if (hd_idx >= 0) begin
      hd_ln = e_line[hd_idx];
      if (e_chk[hd_idx] && hd_got != hd_ln) fail($sformatf("DRS tag %h: line %h, expected %h", hd_tag, hd_got, hd_ln));
      exp_del(hd_idx);
    end
  end
endtask
task automatic h_parse();
  logic [63:0] c, u;
  logic [15:0] cr;
  logic [1:0]  typ;
  c = '1;
  for (int b = 0; b < 30; b++) c = h_crc(c, hr[b], 64);
  cr = hr[30][15:0];
  c = h_crc(c, {48'd0, cr}, 16);
  if (c != {hr[31][15:0], hr[30][63:16]}) fail($sformatf("S2M flit: bad CRC %h", {hr[31][15:0], hr[30][63:16]}));
  if (hr[31][63:16] != 0) fail("S2M flit: FEC bytes not zero");
  if (hr[0][15:8] != hx_seq) fail($sformatf("S2M flit: SEQ %0d, expected %0d", hr[0][15:8], hx_seq));
  hx_seq = hr[0][15:8] + 8'd1;
  if (hr[0][7:2] != 0) fail("S2M flit: reserved header bits");
  typ = hr[0][1:0];
  hc_req += cr[3:0]; hc_rwd += cr[7:4]; hc_bir += cr[11:8]; hc_io += cr[15:12];
  if (hc_req > RQD || hc_rwd > WQD || hc_bir > 1 || hc_io > IOD)
    fail($sformatf("credits from the device: Req %0d RwD %0d BIRsp %0d io %0d", hc_req, hc_rwd, hc_bir, hc_io));
  if (typ == 2'd1) begin
    n_dio++;
    ho_io++;
    for (int k = 0; k < 30; k++) begin
      u = k == 29 ? {16'd0, hr[29][63:16]} : {hr[k + 1][15:0], hr[k][63:16]};
      if (dio_exp.size() == 0) fail("S2M CXL.io flit with none expected");
      else begin
        if (u !== dio_exp[0]) fail($sformatf("S2M CXL.io beat %0d: %h, expected %h", k, u, dio_exp[0]));
        dio_w = dio_exp.pop_front();
      end
    end
  end else if (typ == 2'd0) begin
    if (hr[0][63:16] != 0) fail("NOP flit: H slot not zero");
    for (int j = 1; j < 30; j++) if (hr[j] != 0) fail($sformatf("NOP flit: unit %0d not zero", j));
  end else if (typ == 2'd2) begin
    if (hr[0][63:16] != 0) fail("S2M flit: H slot reserved bytes not zero");
    for (int j = 1; j < 30; j++) begin
      u = hr[j];
      if (j >= 2 && hd_owe && (hd_cnt != 0 || j % 2 == 0)) h_drs_data(u);
      else
        case (u[3:0])
          4'd0: if (u != 0) fail($sformatf("S2M unit %0d: empty with %h", j, u));
          4'd4: h_ndr(u);
          4'd5: begin
            if (hd_owe) fail("DRS header while a line is owed");
            h_drs_start(u);
          end
          4'd6: begin
            n_bis++;
            if (u[63:48] != 0 || u[31:20] != 0 || u[7:6] != 0) fail($sformatf("BISnp unit %h: reserved bits", u));
            bq_op.push_back(u[7:4]); bq_tag.push_back(u[19:8]); bq_addr.push_back(u[47:32]);
          end
          default: fail($sformatf("S2M unit %0d: code %0d", j, u[3:0]));
        endcase
    end
  end else fail("S2M flit: reserved type");
endtask
always @(posedge `CXL_CLK or negedge rst_n)
  if (!rst_n) begin
    hj = 0; hx_seq = 0; hd_owe = 0; hd_cnt = 0;
  end else begin
    n_range += `CXL_C.ev_range; n_opcode += `CXL_C.ev_opcode; n_proto += `CXL_C.ev_proto;
    n_poison += `CXL_C.ev_poison; n_crc += `CXL_C.ev_crc; n_seq += `CXL_C.ev_seq; n_fmt += `CXL_C.ev_fmt;
    n_ovf += `CXL_C.ev_ovf;
    if (tx_valid && tx_ready) begin
      hr[hj] = tx_data;
      hj++;
      if (hj == 32) begin
        hj = 0;
        h_parse();
      end
    end
  end

// ---------------- M2S messages ----------------
// an address: a free line in range (any of the first hz_lines in the
// conflict phase), or out of range; ln = -1 out of range
task automatic pick_addr(input bit need_free, output logic [15:0] a, output int ln, output bit cl);
  cl = 0;
  if (f_off != -100) begin
    ln = f_off >= 0 && f_off < LINES ? f_off : -1;
    while (need_free && ln >= 0 && (busy[ln] != 0 || snp_pend[ln])) @(negedge `CXL_CLK);
    if (need_free && ln >= 0) begin busy[ln]++; cl = 1; end
    a = hdm_base + 16'(f_off);
  end else if ($urandom % 100 < p_out) begin
    a = hdm_base + 16'(LINES) + 16'($urandom % (65536 - LINES));
    ln = -1;
  end else begin
    if (hz) ln = $urandom % hz_lines;
    else begin
      ln = $urandom % LINES;
      while (need_free && (busy[ln] != 0 || snp_pend[ln]) && !stop) begin
        @(negedge `CXL_CLK);
        ln = $urandom % LINES;
      end
      if (need_free) begin busy[ln]++; cl = 1; end
    end
    a = hdm_base + 16'(ln);
  end
endtask
function automatic logic [1:0] rnd_mf();
  int r;
  if (f_mf >= 0) return 2'(f_mf);
  r = $urandom % 100;
  return r < 45 ? 2'b00 : r < 90 ? 2'b11 : r < 95 ? 2'b01 : 2'b10;
endfunction
function automatic logic [2:0] rnd_snp();
  if (f_mf >= 0) return 3'd0;
  return $urandom % 100 < 6 ? 3'(4 + $urandom % 4) : 3'($urandom % 4);
endfunction
// wait while the M2S queues are long
task automatic q_wait();
  while ((hq_req.size() > 3 || hq_rh.size() > 2) && rst_n && !stop) @(negedge `CXL_CLK);
endtask

task automatic send_req(input logic [3:0] op);
  logic [1:0]  mf, mv, emf, old;
  logic [2:0]  snp;
  logic [15:0] a, tag;
  int          ln;
  bit          need, cl;
  q_wait();
  mf = rnd_mf(); mv = f_mv >= 0 ? 2'(f_mv) : 2'($urandom); snp = rnd_snp(); tag = new_tag();
  need = op == 4'd0 || op == 4'd1 || op == 4'd2 || op == 4'd9 || op == 4'd10;
  pick_addr(need, a, ln, cl);
  emf = mf == 2'b01 || mf == 2'b10 || snp[2] ? 2'b11 : mf;
  if (mf == 2'b01 || mf == 2'b10 || snp[2]) x_proto++;
  old = ln >= 0 ? rmt[ln] : 2'b00;
  case (op)
    4'd1, 4'd2: begin
      exp_add(tag, 2, ln, 3'd0, old, ln < 0 || rps[ln], ln >= 0 ? rm[ln] : 512'd0, op == 4'd1 && emf == 2'b00, mv, cl);
      if (ln >= 0 && rps[ln] && !hz) x_poison++;
      if (ln >= 0 && op == 4'd1 && emf == 2'b00) rmt[ln] = mv;
    end
    4'd0, 4'd9, 4'd10: begin
      exp_add(tag, 1, ln, op != 4'd10 && emf == 2'b00 ? (mv == 2'b11 ? 3'd1 : mv == 2'b10 ? 3'd2 : 3'd0) : 3'd0,
              old, 0, 512'd0, emf == 2'b00, mv, cl);
      if (ln >= 0 && emf == 2'b00) rmt[ln] = mv;
    end
    4'd8: ;
    default: x_opcode++;
  endcase
  if (need && ln < 0) x_range++;
  hq_req.push_back(u_req(op, mf, mv, snp, tag, a));
endtask
function automatic logic [3:0] rnd_req_op();
  int r, k;
  r = $urandom % 100;
  k = $urandom % 10;                           // unsupported: 3..7, 11..15
  return r < 30 ? 4'd1 : r < 40 ? 4'd2 : r < 55 ? 4'd0 : r < 65 ? 4'd9 : r < 78 ? 4'd10 : r < 88 ? 4'd8 :
         k < 5 ? 4'(3 + k) : 4'(6 + k);
endfunction

task automatic send_rwd(input logic [3:0] op);
  logic [1:0]   mf, mv, emf, old;
  logic [2:0]   snp;
  logic [15:0]  a, tag;
  logic [63:0]  d [0:7];
  logic [63:0]  be;
  logic [511:0] nl;
  int           ln, bm;
  bit           po, cl;
  q_wait();
  mf = rnd_mf(); mv = f_mv >= 0 ? 2'(f_mv) : 2'($urandom); snp = rnd_snp(); tag = new_tag();
  po = f_po >= 0 ? f_po[0] : $urandom % 100 < 15;
  pick_addr(op == 4'd1 || op == 4'd2, a, ln, cl);
  emf = mf == 2'b01 || mf == 2'b10 || snp[2] ? 2'b11 : mf;
  bm = $urandom % 6;                           // byte enables: 0 none, 1 all, else random
  for (int b = 0; b < 8; b++) d[b] = f_dp >= 0 ? {8{8'(f_dp)}} : {$urandom, $urandom};
  be = bm == 0 ? 64'd0 : bm == 1 ? '1 : {$urandom, $urandom};
  if (op == 4'd4 && bi_en) begin
    exp_add(tag, 1, -1, 3'd4, 2'b00, 0, 512'd0, 0, 2'b00, 0);
  end else if (op == 4'd1 || op == 4'd2) begin
    if (mf == 2'b01 || mf == 2'b10 || snp[2]) x_proto++;
    // the device would leave the line Invalid with the snoop filter full:
    // the host does not ask for it when that depends on timing
    if (bi_en && emf == 2'b00 && ln >= 0 && rmt[ln] == 2'b00 && f_mv < 0) mv = 2'b00;
    old = ln >= 0 ? rmt[ln] : 2'b00;
    exp_add(tag, 1, ln, 3'd0, old, 0, 512'd0, emf == 2'b00, mv, cl);
    if (ln < 0) x_range++;
    else begin
      nl = rm[ln];
      for (int b = 0; b < 8; b++)
        for (int k = 0; k < 8; k++)
          if (op == 4'd1 || be[8 * b + k]) nl[64 * b + 8 * k +: 8] = d[b][8 * k +: 8];
      rm[ln] = nl;
      rps[ln] = po || op == 4'd2 && rps[ln];
      if (emf == 2'b00) rmt[ln] = mv;
    end
  end else begin
    if (mf == 2'b01 || mf == 2'b10 || snp[2]) x_proto++;
    x_opcode++;
  end
  hq_rh.push_back(u_rwd(op, mf, mv, snp, po, tag, a));
  hq_rbe.push_back(be);
  if (op != 4'd4) for (int b = 0; b < 8; b++) hq_rd.push_back(d[b]);
endtask
function automatic logic [3:0] rnd_rwd_op();
  int r;
  r = $urandom % 100;
  return r < 45 ? 4'd1 : r < 90 ? 4'd2 : r < 93 ? 4'd0 : r < 95 ? 4'd4 : 4'(5 + $urandom % 11);
endfunction

task automatic req_driver(input int n);
  for (int i = 0; i < n && !stop; i++) begin
    send_req(rnd_req_op());
    if ($urandom % 3 == 0) repeat ($urandom % 5) @(negedge `CXL_CLK);
  end
endtask
task automatic rwd_driver(input int n);
  for (int i = 0; i < n && !stop; i++) begin
    send_rwd(rnd_rwd_op());
    if ($urandom % 3 == 0) repeat ($urandom % 5) @(negedge `CXL_CLK);
  end
endtask

// a write-back of a line before a BIRsp: MemWr, Meta0-State Invalid
task automatic send_wb(input int ln);
  logic [15:0] tag;
  logic [63:0] d;
  tag = new_tag();
  exp_add(tag, 1, ln, 3'd0, rmt[ln], 0, 512'd0, 1, 2'b00, 0);
  hq_rh.push_back(u_rwd(4'd1, 2'b00, 2'b00, 3'd0, 0, tag, hdm_base + 16'(ln)));
  hq_rbe.push_back({$urandom, $urandom});
  for (int b = 0; b < 8; b++) begin
    d = {$urandom, $urandom};
    rm[ln][64 * b +: 64] = d;
    hq_rd.push_back(d);
  end
  rps[ln] = 0; rmt[ln] = 2'b00;
endtask

// ---------------- BISnp handling ----------------
int           bi_illegal = 0, bi_stale = 0, bi_wb = 30;   // % illegal BIRsp, % stale one first, % write-back
int           n_birsp = 0;
function automatic logic [3:0] rsp_for(input logic [3:0] op);
  int r;
  r = $urandom % 3;
  if ($urandom % 100 < bi_illegal) begin
    x_proto++;
    return op == 4'd2 ? 4'(1 + $urandom % 15) : op == 4'd1 ? (r == 0 ? 4'd2 : 4'(3 + $urandom % 13)) : 4'(3 + $urandom % 13);
  end
  return op == 4'd2 ? 4'd0 : op == 4'd1 ? 4'(r % 2) : 4'(r);
endfunction
function automatic logic [1:0] rsp_state(input logic [3:0] op, input logic [3:0] rsp);
  bit legal;
  legal = rsp == 4'd0 || rsp == 4'd1 && op != 4'd2 || rsp == 4'd2 && op == 4'd0;
  return !legal ? 2'b00 : rsp == 4'd1 ? 2'b11 : rsp == 4'd2 ? 2'b10 : 2'b00;
endfunction
initial begin : b_bisnp
  logic [3:0]  op, rsp;
  logic [11:0] tag;
  logic [15:0] a, t;
  int          ln, i, ts;
  logic [1:0]  s;
  forever begin
    @(negedge `CXL_CLK);
    if (bq_op.size() > 0 && rst_n) begin
      op = bq_op.pop_front(); tag = bq_tag.pop_front(); a = bq_addr.pop_front();
      ln = int'(16'(a - hdm_base));
      ho_bis++;
      if (ln >= LINES) fail($sformatf("BISnp for address %h, outside the device", a));
      else begin
        snp_pend[ln] = 1;
        if (busy[ln] != 0) begin
          // BIConflict, then wait for the Ack
          t = new_tag();
          cf_line = ln; cf_ack = 0; cf_tag = t;
          exp_add(t, 1, -1, 3'd4, 2'b00, 0, 512'd0, 0, 2'b00, 0);
          hq_rh.push_back(u_rwd(4'd4, 2'b11, 2'b00, 3'd0, 0, t, a));
          hq_rbe.push_back({$urandom, $urandom});
          while (!cf_ack && rst_n) @(negedge `CXL_CLK);
        end else if ($urandom % 100 < bi_wb && !hz) begin
          // write the line back (and give it up) first
          send_wb(ln);
          while (busy[ln] != 0 && rst_n) @(negedge `CXL_CLK);
          cf_ack = 0; cf_first = 0;
        end else begin
          cf_ack = 0; cf_first = 0;
        end
        if (!rst_n) ln = -1;
      end
      if (ln >= 0 && ln < LINES) begin
        rsp = rsp_for(op);
        s = rsp_state(op, rsp);
        if ($urandom % 100 < bi_stale) begin
          hq_bir.push_back(u_bir(4'd0, tag + 12'(1 + $urandom % 4000)));
          hq_bln.push_back(-1);
          x_proto++;
        end
        if (cf_ack && cf_first) begin
          // the line's transaction is served after the BIRsp
          i = exp_line(ln);
          if (i >= 0) begin
            e_mv[i] = s;
            rmt[ln] = e_sm[i] ? e_nmv[i] : s;
          end else rmt[ln] = s;
        end else rmt[ln] = s;
        cf_line = -1; cf_ack = 0; cf_tag = -1;
        hq_bir.push_back(u_bir(rsp, tag));
        hq_bln.push_back(ln);
        n_birsp++;
      end
    end
  end
end

// device back-invalidation requests (on the core's pins; with `CXL_BI_APB
// the APB TB sends them through the BI register instead)
int           bi_req_n = 0, n_bi_acc = 0, n_bi_done = 0;
`ifndef CXL_BI_APB
initial begin
  bi_valid = 0; bi_op = 0; bi_line = 0;
  forever begin
    @(negedge `CXL_CLK);
    if (bi_req_n > 0 && rst_n && $urandom % 20 == 0) begin
      bi_valid = 1; bi_op = $urandom; bi_line = $urandom;
      @(posedge `CXL_CLK);
      while (!bi_ready && rst_n && !stop) @(posedge `CXL_CLK);
      if (bi_ready) begin n_bi_acc++; bi_req_n--; end
      @(negedge `CXL_CLK);
      bi_valid = 0;
    end
  end
end
`endif
always @(posedge `CXL_CLK) if (rst_n && `CXL_C.bi_done) n_bi_done++;

task automatic wait_clk(input int n);
  repeat (n) @(negedge `CXL_CLK);
endtask
task automatic ev_clear();
  x_range = 0; x_opcode = 0; x_proto = 0; x_poison = 0; x_crc = 0; x_seq = 0; x_fmt = 0; x_ovf = 0;
  n_range = 0; n_opcode = 0; n_proto = 0; n_poison = 0; n_crc = 0; n_seq = 0; n_fmt = 0; n_ovf = 0;
endtask
// wait for every response and every message to be sent, then compare the
// event counts and the credits
logic [7:0]   ev_mask = 0;                     // the events seen in the last phase
task automatic drain(input string ph);
  int t;
  t = 0;
  while ((e_tag.size() != 0 || hq_req.size() != 0 || hq_rh.size() != 0 || hq_bir.size() != 0 || h_owe != 0 ||
          bq_op.size() != 0 || hq_io_n != 0 || dio_q.size() != 0 || hio_exp.size() != 0 || dio_exp.size() != 0 ||
          bi_req_n != 0 || h_busy) && t < 20000) begin
    @(negedge `CXL_CLK); t++;
  end
  if (t >= 20000) fail($sformatf("%s: %0d responses, %0d Req, %0d RwD, %0d CXL.io beats missing", ph, e_tag.size(),
                                 hq_req.size(), hq_rh.size(), hio_exp.size() + dio_exp.size()));
  wait_clk(200);
  t = 0;
  while (tx_mode != 4 && (hc_req != RQD || hc_rwd != WQD || hc_bir != 1 || hc_io != IOD) && t < 5000) begin
    @(negedge `CXL_CLK); t++;
  end
  if (n_range != x_range || n_opcode != x_opcode || n_proto != x_proto || !hz && n_poison != x_poison ||
      n_crc != x_crc || n_seq != x_seq || n_fmt != x_fmt || n_ovf != x_ovf)
    fail($sformatf("%s: events range %0d/%0d opcode %0d/%0d proto %0d/%0d poison %0d/%0d crc %0d/%0d seq %0d/%0d fmt %0d/%0d ovf %0d/%0d",
                   ph, n_range, x_range, n_opcode, x_opcode, n_proto, x_proto, n_poison, x_poison, n_crc, x_crc,
                   n_seq, x_seq, n_fmt, x_fmt, n_ovf, x_ovf));
  if (tx_mode != 4 && (hc_req != RQD || hc_rwd != WQD || hc_bir != 1 || hc_io != IOD))
    fail($sformatf("%s: credits held Req %0d RwD %0d BIRsp %0d io %0d", ph, hc_req, hc_rwd, hc_bir, hc_io));
  if (n_bi_done != n_bi_acc) fail($sformatf("%s: %0d BI requests, %0d done", ph, n_bi_acc, n_bi_done));
  ev_mask = {n_ovf != 0, n_fmt != 0, n_seq != 0, n_crc != 0, n_poison != 0, n_proto != 0, n_opcode != 0, n_range != 0};
  ev_clear();
  if (hz) ref_from_dut();
  $display("-- %s done @%0t", ph, $time);
endtask
task automatic traffic(input int nq, input int nw, input string ph);
  fork
    req_driver(nq);
    rwd_driver(nw);
  join
  drain(ph);
endtask
