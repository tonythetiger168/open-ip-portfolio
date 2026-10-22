// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Link-partner testbench for SAS_4__Serial_Attached_SCSI__top (v2.0).
// The TB is the far end of the serial link:
//  - OOB: answers the DUT's bursts (a plan can leave bursts unanswered, and
//    the burst length is a knob).
//  - Block TX: its own 128b/130b encoder and x^16+x^5+1 scrambler, with a
//    random start offset (bit-slip hunt) and optional data-only lead-in
//    (lock must wait for a control code).
//  - Block RX: an independent decoder of the DUT's line that checks every
//    frame (structure, CRC, response data against a register model).
//  - Reflector: echoes the DUT's frames back, as the loopback partner the
//    built-in sequencer expects; knobs drop or corrupt a reflection.
//  - Injector: frames with any type / dst / src / len (0..8, two payload
//    blocks) and protocol faults, plus invalid sync headers.
// The bound checker (tb/cov/SAS_4__Serial_Attached_SCSI__sva.sv) predicts
// tx_p, link_up and irq on every clock.
// ============================================================================
`timescale 1ns/1ps
module SAS_4__Serial_Attached_SCSI__tb;

  localparam logic [1:0]  SH_DATA   = 2'b01;
  localparam logic [1:0]  SH_CTRL   = 2'b10;
  localparam logic [31:0] CODE_IDLE = 32'hA5C3_0000;
  localparam logic [31:0] CODE_SOF  = 32'hA5C3_0001;
  localparam logic [31:0] CODE_EOF  = 32'hA5C3_0002;
  localparam logic [15:0] SCR_SEED  = 16'hACE1;
  localparam logic [7:0]  T_WRITE   = 8'h01;
  localparam logic [7:0]  T_RDREQ   = 8'h02;
  localparam logic [7:0]  T_RDRSP   = 8'h83;
  // injected frame faults
  localparam int F_NONE = 0, F_CRC = 1, F_HDR_CTRL = 2, F_PAY_CTRL = 3, F_CRC_CTRL = 4,
                 F_NO_EOF = 5, F_LEN9 = 6, F_EOF_DATA = 7;

  logic clk = 0, rst_n = 0;
  logic tx_p, tx_n, link_up, irq;
  logic pl_oob = 0, pl_blk = 0, blk_mode = 0;
  wire  rx_p = blk_mode ? pl_blk : pl_oob;
  wire  rx_n = ~rx_p;
  int   errors = 0;
  logic [31:0] crc_flip = 0;   // bits flipped in an F_CRC frame's CRC

  SAS_4__Serial_Attached_SCSI__top dut (
    .clk(clk), .rst_n(rst_n), .tx_p(tx_p), .tx_n(tx_n),
    .rx_p(rx_p), .rx_n(rx_n), .link_up(link_up), .irq(irq)
  );

  always #5 clk = ~clk;

  function automatic void fail(input string m);
    errors++;
    $display("ERROR @%0t: %s", $time, m);
  endfunction

  function automatic logic [31:0] crc32_dw(input logic [31:0] crc, input logic [31:0] dw);
    logic [31:0] c;
    c = crc;
    for (int b = 3; b >= 0; b--)
      for (int i = 0; i < 8; i++) begin
        if (c[0] ^ dw[b*8+i]) c = (c >> 1) ^ 32'hEDB88320;
        else                  c = c >> 1;
      end
    return c;
  endfunction

  function automatic logic [31:0] crc_blk(input logic [31:0] crc, input logic [127:0] b);
    return crc32_dw(crc32_dw(crc32_dw(crc32_dw(crc, b[127:96]), b[95:64]), b[63:32]), b[31:0]);
  endfunction

  // irq events seen since the last clear
  int irq_n = 0;
  always @(posedge clk) if (rst_n && irq) irq_n++;

  // ---------------------------------------------------------------- OOB peer
  int oob_plan [$];          // per DUT burst: answer burst length (0: no answer)
  int oob_blen = 100;
  int bursts_seen = 0;
  always @(negedge clk) begin : oob_peer
    static int run = 0, dly = 0, len = 0, ans = 0;
    if (!rst_n || link_up) begin
      run = 0; dly = 0; len = 0; pl_oob = 0;
    end else begin
      if (tx_p) run++;
      else begin
        if (run >= 64) begin
          bursts_seen++;
          ans = oob_blen;
          if (oob_plan.size() > 0) ans = oob_plan.pop_front();
          if (ans > 0) dly = 10;
        end
        run = 0;
      end
      if (dly > 0) begin
        dly--;
        if (dly == 0) len = ans;
      end
      pl_oob = len > 0;
      if (len > 0) len--;
    end
  end

  // ---------------------------------------------------------------- block TX
  logic [1:0]   bq_sh [$];
  logic [127:0] bq_pl [$];
  int           bq_wa [$];   // when this (EOF) block is sent: 0..15 write applied,
                             // 16..31 read request taken (snapshot), -1 none
  logic [31:0]  bq_wd [$];
  logic [31:0]  mreg [0:15]; // model of the DUT register file
  logic [31:0]  snap [0:15]; // register value seen by the latest read request
  int  pre_zero = 0;         // line bits before the first block
  int  pre_data = 0;         // data blocks before the first idle
  int  pre_junk = 0;         // then control blocks with an unknown code
  logic [15:0] pscr = 16'h1D0F;

  function automatic void push(input logic [1:0] sh, input logic [127:0] p, input int wa = -1,
                      input logic [31:0] wd = 0);
    bq_sh.push_back(sh); bq_pl.push_back(p); bq_wa.push_back(wa); bq_wd.push_back(wd);
  endfunction

  always begin : peer_tx
    logic [1:0] sh;
    logic [127:0] p;
    int wa;
    logic [31:0] wd;
    bit up;
    blk_mode = 0; pl_blk = 0;
    wait (rst_n && link_up);
    blk_mode = 1;
    up = 1;
    for (int i = 0; i < pre_zero && up; i++) begin
      @(negedge clk); pl_blk = 0; up = rst_n && link_up;
    end
    for (int n = 0; up; n++) begin
      wa = -1; wd = 0;
      if (n < pre_data) begin sh = SH_DATA; p = {$urandom, $urandom, $urandom, $urandom}; end
      else if (n < pre_data + pre_junk) begin
        sh = SH_CTRL; p = {CODE_IDLE ^ (32'h100 << (n % 8)), $urandom, $urandom, $urandom};
      end
      else if (bq_sh.size() > 0) begin
        sh = bq_sh.pop_front(); p = bq_pl.pop_front(); wa = bq_wa.pop_front(); wd = bq_wd.pop_front();
      end else begin sh = SH_CTRL; p = {CODE_IDLE, $urandom, $urandom, $urandom}; end
      for (int i = 129; i >= 0 && up; i--) begin
        logic o;
        @(negedge clk);
        up = rst_n && link_up;
        if (i >= 128) o = sh[i-128];
        else begin
          o = p[i] ^ pscr[15] ^ pscr[4];
          pscr = {pscr[14:0], o};
        end
        pl_blk = up && o;
      end
      if (up && wa >= 0 && wa < 16) mreg[wa] = wd;
      if (up && wa >= 16) snap[wa-16] = mreg[wa-16];
    end
    bq_sh.delete(); bq_pl.delete(); bq_wa.delete(); bq_wd.delete();
    pre_zero = 0; pre_data = 0; pre_junk = 0;
    @(negedge clk);
  end

  // build a frame: SOF, header, payload block(s), CRC, EOF
  function automatic void frame(input logic [7:0] ty, input logic [7:0] dst, input logic [7:0] src,
                       input logic [3:0] len, input logic [31:0] d0, input int fault = F_NONE,
                       input bit junk = 1);
    logic [127:0] h, pb [0:1];
    logic [31:0] crc;
    int nb, wa;
    logic [31:0] j0, j1, j2, j3;
    {j0, j1, j2, j3} = junk ? {$urandom, $urandom, $urandom, $urandom} : 128'd0;
    h = {j0[31:8], ty, j1[31:8], dst, j2[31:8], src, j3[31:8], 4'h0, len};
    if (fault == F_LEN9) h[7:0] = 8'd9 + 8'($urandom % 200);
    nb = (len == 0) ? 0 : (len <= 4) ? 1 : 2;
    pb[0] = {d0, $urandom, $urandom, $urandom};
    pb[1] = {$urandom, $urandom, $urandom, $urandom};
    crc = crc_blk(32'hFFFF_FFFF, h);
    for (int i = 0; i < nb; i++) crc = crc_blk(crc, pb[i]);
    crc = ~crc;
    if (fault == F_CRC) crc = crc ^ (crc_flip == 0 ? 32'h8000_0000 : crc_flip);
    wa = (fault != F_NONE || dst >= 16) ? -1 :
         (ty == T_WRITE && len != 0) ? int'(dst) : (ty == T_RDREQ) ? 16 + int'(dst) : -1;
    push(SH_CTRL, {CODE_SOF, $urandom, $urandom, $urandom});
    if (fault == F_HDR_CTRL) begin push(SH_CTRL, {CODE_IDLE, 96'd0}); return; end
    push(SH_DATA, h);
    if (fault == F_LEN9) return;
    for (int i = 0; i < nb; i++)
      if (fault == F_PAY_CTRL) begin push(SH_CTRL, {CODE_EOF, 96'd0}); return; end
      else push(SH_DATA, pb[i]);
    if (fault == F_CRC_CTRL) push(SH_CTRL, {crc, $urandom, $urandom, $urandom});
    else push(SH_DATA, {crc, $urandom, $urandom, $urandom});
    if (fault == F_NO_EOF)        push(SH_CTRL, {CODE_IDLE, 96'd0});
    else if (fault == F_EOF_DATA) push(SH_DATA, {CODE_EOF, 96'd0});
    else                          push(SH_CTRL, {CODE_EOF, $urandom, $urandom, $urandom}, wa, d0);
  endfunction

  function automatic void bad_sync(input int n);
    for (int i = 0; i < n; i++) push((i % 2) ? 2'b11 : 2'b00, {$urandom, $urandom, $urandom, $urandom});
  endfunction

  // --------------------------------------------------------- DUT line decoder
  int  refl_drop_wr = 0, refl_drop_rd = 0, refl_bad_rsp = 0;
  bit  reflect = 1;
  int  frames_wr = 0, frames_rd = 0, frames_rsp = 0, rsp_to_peer = 0;
  logic [127:0] fb [0:7];
  logic [1:0]   fs [0:7];

  function automatic void check_frame(input int nb);
    logic [7:0] ty, dst, src, len;
    logic [31:0] crc;
    int np;
    ty = fb[1][103:96]; dst = fb[1][71:64]; src = fb[1][39:32]; len = fb[1][7:0];
    np = (len == 0) ? 0 : 1;
    if (fb[1][127:104] != 0 || fb[1][95:72] != 0 || fb[1][63:40] != 0 || fb[1][31:8] != 0)
      fail("DUT header junk bits");
    if (nb != 4 + np || fs[1] != SH_DATA || fs[nb-1] != SH_CTRL || fb[nb-1][127:96] != CODE_EOF)
      fail($sformatf("DUT frame structure: %0d blocks", nb));
    if (np == 1 && fb[2][95:0] != 0) fail("DUT payload padding");
    crc = crc_blk(32'hFFFF_FFFF, fb[1]);
    if (np == 1) crc = crc_blk(crc, fb[2]);
    if (fb[2+np][127:96] != ~crc || fb[2+np][95:0] != 0) fail("DUT frame CRC");
    case (ty)
      T_WRITE: begin
        frames_wr++;
        if (len != 1 || src != 1 || dst >= 16) fail("DUT write header");
      end
      T_RDREQ: begin
        frames_rd++;
        if (len != 0 || src != 1 || dst >= 16) fail("DUT read request header");
      end
      T_RDRSP: begin
        frames_rsp++;
        if (len != 1 || src >= 16) fail("DUT read response header");
        else if (fb[2][127:96] !== snap[src[3:0]])
          fail($sformatf("read response reg %0d: %h exp %h", src, fb[2][127:96], snap[src[3:0]]));
        if (dst != 1) rsp_to_peer++;
      end
      default: fail($sformatf("DUT frame type %h", ty));
    endcase
    // reflect
    if (!reflect) return;
    if (ty == T_WRITE && refl_drop_wr > 0) begin refl_drop_wr--; return; end
    if (ty == T_RDREQ && refl_drop_rd > 0) begin refl_drop_rd--; return; end
    if (ty == T_RDRSP && dst != 1) return;
    if (ty == T_RDRSP && refl_bad_rsp > 0) begin
      refl_bad_rsp--;
      frame(T_RDRSP, dst, src, 1, fb[2][127:96] ^ 32'h0400_0000, F_NONE, 0);
      return;
    end
    for (int i = 0; i < nb; i++)
      push(fs[i], fb[i], (i != nb - 1) ? -1 : (ty == T_WRITE) ? int'(dst) : 16 + int'(dst),
           (ty == T_WRITE) ? fb[2][127:96] : 32'd0);
  endfunction

  always begin : dut_rx
    logic [15:0] ds;
    logic [1:0] sh;
    logic [127:0] p;
    int nb;
    bit up;
    wait (rst_n && link_up);
    @(negedge clk);                          // tx_bit still holds its reset value
    ds = SCR_SEED; nb = 0; up = 1;
    while (up) begin
      for (int i = 129; i >= 0 && up; i--) begin
        @(negedge clk);
        up = rst_n && link_up;
        if (i >= 128) sh[i-128] = tx_p;
        else begin
          p[i] = tx_p ^ ds[15] ^ ds[4];
          ds = {ds[14:0], tx_p};
        end
      end
      if (up) begin
        if (sh != SH_DATA && sh != SH_CTRL) fail("DUT sync header");
        if (sh == SH_CTRL && p[127:96] == CODE_SOF) nb = 0;
        if (nb == 0 && !(sh == SH_CTRL && p[127:96] == CODE_SOF)) begin
          if (sh != SH_CTRL || p[127:96] != CODE_IDLE || p[95:0] != 0) fail("DUT idle block");
        end else begin
          if (nb < 8) begin fb[nb] = p; fs[nb] = sh; end
          nb++;
          if (sh == SH_CTRL && p[127:96] == CODE_EOF) begin check_frame(nb); nb = 0; end
          else if (nb > 6) begin fail("DUT frame too long"); nb = 0; end
        end
      end
    end
  end

  // ---------------------------------------------------------------- helpers
  task automatic cycles(input int n);
    repeat (n) @(negedge clk);
  endtask

  task automatic wait_link(input int lim = 4000);
    int t;
    t = 0;
    while (!link_up && t < lim) begin @(negedge clk); t++; end
    if (!link_up) fail("link did not come up");
  endtask

  task automatic wait_rsp(input int n, input int lim = 200000);
    int t, n0;
    t = 0; n0 = frames_rsp;
    while (frames_rsp < n0 + n && t < lim) begin @(negedge clk); t++; end
    if (frames_rsp < n0 + n) fail($sformatf("only %0d of %0d read responses", frames_rsp - n0, n));
  endtask

  task automatic drain_q(input int lim = 20000);
    int t;
    t = 0;
    while (bq_sh.size() > 0 && t < lim) begin @(negedge clk); t++; end
  endtask

  task automatic expect_irq(input string m, input int win = 2000);
    int n0;
    n0 = irq_n;
    drain_q();
    cycles(win);
    if (irq_n == n0) fail({"no irq: ", m});
  endtask

  task automatic hard_reset;
    @(negedge clk); rst_n = 0;
    cycles(3);
    if (tx_p !== 1'b0 || tx_n !== 1'b1 || link_up !== 1'b0 || irq !== 1'b0) fail("reset state");
    for (int i = 0; i < 16; i++) begin mreg[i] = 0; snap[i] = 0; end
    oob_plan.delete();
    oob_blen = 100;
    rst_n = 1;
  endtask

  // ------------------------------------------------------------------ test
  initial begin
    for (int i = 0; i < 16; i++) begin mreg[i] = 0; snap[i] = 0; end
    cycles(3);
    if (tx_p !== 1'b0 || link_up !== 1'b0 || irq !== 1'b0) fail("reset state");
    rst_n = 1;

    // ---- OOB with unanswered bursts, long answer burst; data-only lead-in
    oob_plan = '{50, 150, 0};            // COMRESET answered too short (below the
                                         // 64-clk detect), then with a long burst
                                         // (run counter saturates); COMINIT once unanswered
    pre_zero = 37; pre_data = 7; pre_junk = 3;
    wait_link(6000);
    if (bursts_seen != 4) fail($sformatf("OOB bursts %0d exp 4", bursts_seen));

    // ---- sequencer loopback traffic: 20 write/read-verify transactions
    wait_rsp(20);
    if (irq_n != 0) fail("irq during clean traffic");

    // ---- register file from the peer: all-ones, all-zero, random, read back
    for (int pass = 0; pass < 3; pass++) begin
      for (int a = 0; a < 16; a++)
        frame(T_WRITE, 8'(a), 8'h40 + 8'(a), 4'(1 + $urandom % 8),
              pass == 0 ? 32'hFFFF_FFFF : pass == 1 ? 32'h0 : $urandom);
      for (int a = 0; a < 16; a++) begin           // spaced: one response in flight
        frame(T_RDREQ, 8'(a), 8'($urandom | 8'h80), 4'd0, 0);
        push(SH_CTRL, {CODE_IDLE, 96'd0}); push(SH_CTRL, {CODE_IDLE, 96'd0});
      end
      drain_q(40000);
      cycles(2000);
    end
    if (rsp_to_peer < 48) fail($sformatf("peer read responses %0d", rsp_to_peer));
    frame(T_RDREQ, 8'h3, 8'h02, 4'd0, 0);     // back to back: the newer request
    frame(T_RDREQ, 8'h4, 8'h00, 4'd0, 0);     // may replace the waiting one
    drain_q(); cycles(3000);
    wait_rsp(4);                             // sequencer recovers

    // ---- protocol faults (each raises irq)
    for (int k = 0; k < 6; k++) begin
      crc_flip = (k == 0) ? 32'h8000_0000 : (k == 1) ? 32'h0000_0001 : $urandom | 32'h1;
      frame(T_WRITE, 8'h2, 8'h9, 4'd1, 32'h1234_5678, F_CRC);    expect_irq("bad CRC");
    end
    frame(T_WRITE, 8'h2, 8'h9, 4'd1, 0, F_HDR_CTRL);             expect_irq("control block as header");
    frame(T_WRITE, 8'h2, 8'h9, 4'd1, 0, F_LEN9);                 expect_irq("len > 8");
    frame(T_WRITE, 8'h2, 8'h9, 4'd6, 0, F_PAY_CTRL);             expect_irq("control block as payload");
    frame(T_RDREQ, 8'h2, 8'h9, 4'd0, 0, F_CRC_CTRL);             expect_irq("control block as CRC");
    frame(T_WRITE, 8'h2, 8'h9, 4'd2, 32'h0BAD_F00D, F_NO_EOF);   expect_irq("missing EOF");
    frame(T_RDREQ, 8'h2, 8'h9, 4'd0, 0, F_EOF_DATA);             expect_irq("EOF as data block");
    frame(T_WRITE, 8'h2, 8'h9, 4'd0, 0);                         expect_irq("write len 0");
    frame(T_WRITE, 8'h12, 8'h9, 4'd1, 0);                        expect_irq("write dst >= 16");
    frame(T_RDREQ, 8'hF0, 8'h9, 4'd0, 0);                        expect_irq("read dst >= 16");
    frame(T_RDRSP, 8'h1, 8'h9, 4'd0, 0);                         expect_irq("response len 0");
    frame(8'h44, 8'h1, 8'h9, 4'd3, 0);                           expect_irq("unknown type");
    frame(8'hBC, 8'h1, 8'h9, 4'd8, 0);                           expect_irq("unknown type, two payload blocks");
    frame(T_RDRSP, 8'h1, 8'h9, 4'd1, $urandom);                  // unsolicited response
    push(SH_DATA, {$urandom, $urandom, $urandom, $urandom});     // stray data block outside a frame
    push(SH_CTRL, {CODE_EOF, 96'd0});                            // stray EOF
    drain_q(); cycles(200);

    // ---- sequencer timeouts and read-verify mismatch
    begin
      int n0;
      n0 = irq_n;
      refl_drop_wr = 1; wait_rsp(1, 40000); cycles(6000);
      refl_drop_rd = 1; cycles(12000);
      refl_bad_rsp = 1; cycles(8000);
      if (irq_n < n0 + 3) fail("sequencer faults: missing irq");
      wait_rsp(3);
    end

    // ---- invalid sync headers: 7 then good (no loss), then 8 (loss of sync)
    begin
      int n0;
      n0 = irq_n;
      bad_sync(7); drain_q(); cycles(1000);
      if (!link_up || irq_n != n0) fail("7 bad headers dropped the link");
      oob_plan = '{100};
      pre_zero = 5;
      bad_sync(8);
      while (link_up) @(negedge clk);
      cycles(2);
      if (irq_n == n0) fail("loss of sync: no irq");
      wait_link(6000);
      wait_rsp(3);
    end

    // ---- reset with traffic in flight, then bring-up with a short answer burst
    cycles($urandom % 300);
    hard_reset();
    oob_blen = 70;
    pre_zero = 97;                           // puts the sequencer's gap end on a TX block boundary
    wait_link(6000);
    wait_rsp(4);
    cycles(500);

    if (frames_wr == 0 || frames_rd == 0) fail("no sequencer traffic");
    if (errors == 0) $display("TEST PASSED: SAS_4__Serial_Attached_SCSI_");
    else $display("TEST FAILED: SAS_4__Serial_Attached_SCSI_ (%0d errors)", errors);
    $finish;
  end

  initial begin
    #40ms;
    $display("TEST FAILED: SAS_4__Serial_Attached_SCSI_ (timeout)");
    $finish;
  end

endmodule
