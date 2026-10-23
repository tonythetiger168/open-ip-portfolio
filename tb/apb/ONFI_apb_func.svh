// SPDX-License-Identifier: Apache-2.0
// ONFI-specific part of tb/ONFI_apb_tb.sv. A small NAND target model (8
// pages of 64 bytes, a feature store, status noise, FAIL and a busy time
// past the controller's timeout on request) sits on the NAND pins.
// Covered through the registers: every command with its data checked
// through WR and RD, STATUS, FAIL and TIMEOUT, CMD written while the core
// is busy and again while full, WR written while full, FLAGS, every
// interrupt bit.
localparam int PS = 64, NP = 8;

// ---------------- target ----------------
logic [7:0] t_fl [0:NP*PS-1];
logic [7:0] t_pr [0:PS-1];
logic [7:0] t_ft [0:1023];
logic [7:0] t_ab [0:4];
logic [7:0] t_fb [0:3];
int         t_mode = 0, t_na = 0, t_ptr = 0, t_nd = 0, t_busy = 0, t_pend = 0;
bit         t_failbit = 0, t_nx_fail = 0, t_nx_slow = 0;
logic [3:0] t_noise = 0;
logic [7:0] t_id [0:4];
logic       p_we = 1, p_re = 1;
initial begin
  t_id[0] = 8'h2C; t_id[1] = 8'hDA; t_id[2] = 8'h90; t_id[3] = 8'h95; t_id[4] = 8'h06;
  rb_n = 1; dq_i = 0;
end
task automatic t_go(input int what);
  t_busy = t_nx_slow ? 2600 : 5 + $urandom % 20;
  t_nx_slow = 0;
  t_pend = what;
endtask
always @(posedge PCLK) begin
  if (!PRESETN) begin p_we = 1; p_re = 1; t_mode = 0; t_busy = 0; t_pend = 0; end
  else begin
    if (we_n && !p_we && !ce_n) begin
      if (cle)
        case (dq_o)
          8'hFF: begin t_mode = 0; t_go(0); end
          8'h90: begin t_mode = 1; t_na = 0; end
          8'h70: t_mode = 3;
          8'h00: begin t_mode = 4; t_na = 0; end
          8'h30: t_go(1);
          8'h80: begin t_mode = 6; t_na = 0; t_nd = 0; for (int i = 0; i < PS; i++) t_pr[i] = 8'hFF; end
          8'h10: t_go(2);
          8'h60: begin t_mode = 7; t_na = 0; end
          8'hD0: t_go(3);
          8'hEE: begin t_mode = 8; t_na = 0; end
          8'hEF: begin t_mode = 10; t_na = 0; t_nd = 0; end
          default: fail($sformatf("target: command %h", dq_o));
        endcase
      else if (ale) begin
        if (t_na < 5) t_ab[t_na] = dq_o;
        t_na++;
        if (t_mode == 1) begin t_mode = 2; t_ptr = 0; end
        if (t_mode == 8) t_go(4);
      end else if (t_mode == 6) begin t_pr[(t_ab[0] + t_nd) % PS] = dq_o; t_nd++; end
      else if (t_mode == 10) begin
        t_fb[t_nd % 4] = dq_o;
        t_nd++;
        if (t_nd == 4) t_go(5);
      end else fail("target: data cycle out of place");
    end
    if (re_n && !p_re) t_ptr++;
    p_we = we_n; p_re = re_n;
  end
end
always @(negedge PCLK) begin
  if (t_busy > 0) begin
    t_busy--;
    rb_n = 0;
    if (t_busy == 0) begin : b_fin
      int p;
      rb_n = 1;
      p = t_ab[2] % NP;
      case (t_pend)
        1: begin for (int i = 0; i < PS; i++) t_pr[i] = t_fl[p * PS + i]; t_mode = 5; t_ptr = t_ab[0]; end
        2: begin
          t_failbit = t_nx_fail;
          if (!t_nx_fail) for (int i = 0; i < PS; i++) t_fl[p * PS + i] = t_fl[p * PS + i] & t_pr[i];
          t_nx_fail = 0; t_mode = 0;
        end
        3: begin
          p = t_ab[0] % NP;
          t_failbit = t_nx_fail;
          if (!t_nx_fail) for (int i = 0; i < PS; i++) t_fl[p * PS + i] = 8'hFF;
          t_nx_fail = 0; t_mode = 0;
        end
        4: begin t_mode = 9; t_ptr = 0; end
        5: begin for (int i = 0; i < 4; i++) t_ft[t_ab[0] * 4 + i] = t_fb[i]; t_mode = 0; end
        default: t_mode = 0;
      endcase
    end
  end
  if (!PRESETN) rb_n = 1;
  dq_i = $urandom;
  if (!re_n && !ce_n)
    case (t_mode)
      2: dq_i = t_id[t_ptr % 5];
      3: dq_i = {1'b1, rb_n, rb_n, t_noise, t_failbit};
      5: dq_i = t_pr[t_ptr % PS];
      9: dq_i = t_ft[t_ab[0] * 4 + t_ptr % 4];
      default: fail("target: read with nothing to read");
    endcase
end

// ---------------- host ----------------
logic [7:0] hf [0:NP*PS-1];                     // reference pages
task automatic o_cmd(input logic [2:0] op, input logic [23:0] row, input logic [15:0] col, input logic [11:0] len);
  wr(A_CMD0, {5'd0, op, row});
  wr(A_CMD1, {4'd0, len, col});
endtask
task automatic o_wait();
  poll(A_IRQ_STATUS, 1 << IRQ_DONE, 1 << IRQ_DONE, 6000);
  wr(A_IRQ_STATUS, 1 << IRQ_DONE);
endtask
task automatic o_put(input logic [7:0] b);
  poll(A_FLAGS, 1 << FLAG_WR_FULL, 0, 1000);
  wr(A_WR, b);
endtask
task automatic o_get(input logic [7:0] b);
  poll(A_FLAGS, 1 << FLAG_RD_AVAIL, 1 << FLAG_RD_AVAIL, 1000);
  rd(A_RD);
  if (rdv[7:0] !== b) fail($sformatf("RD %h, expected %h", rdv[7:0], b));
endtask
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask

task automatic ip_func;
  logic [7:0] d [0:15];
  for (int i = 0; i < NP * PS; i++) begin t_fl[i] = $urandom; hf[i] = t_fl[i]; end
  for (int i = 0; i < 1024; i++) t_ft[i] = $urandom;
  wr(A_IRQ_ENABLE, 0);
  // Reset, Read ID, Read Status
  o_cmd(0, 24'hABCDFF, 16'h1234, 12'hFFF);
  o_wait();
  irq_expect(IRQ_CMD_DONE);
  o_cmd(1, 0, 0, 5);
  for (int i = 0; i < 5; i++) o_get(t_id[i]);
  o_wait();
  irq_expect(IRQ_RD_AVAIL);
  t_noise = 4'hF;
  o_cmd(2, 0, 0, 0);
  o_wait();
  rd_exp(A_STATUS, 32'hFE);
  t_noise = 0;
  // erase page 2, program 16 bytes, read back
  o_cmd(5, 24'h000002, 16'h5555, 12'hAAA);
  o_wait();
  rd_exp(A_STATUS, 32'hE0);
  for (int i = 0; i < PS; i++) hf[2 * PS + i] = 8'hFF;
  o_cmd(4, 24'h000002, 16'h0004, 16);
  for (int i = 0; i < 16; i++) begin d[i] = $urandom; o_put(d[i]); hf[2 * PS + 4 + i] = d[i]; end
  o_wait();
  irq_expect(IRQ_WR_DONE);
  rd_exp(A_STATUS, 32'hE0);
  o_cmd(3, 24'hFFFF02, 16'hFF00, 24);
  for (int i = 0; i < 24; i++) o_get(hf[2 * PS + i]);
  o_wait();
  // features
  o_cmd(7, 0, 16'h0089, 12'h555);
  for (int i = 0; i < 4; i++) begin d[i] = $urandom; o_put(d[i]); end
  o_wait();
  o_cmd(6, 0, 16'h0089, 0);
  for (int i = 0; i < 4; i++) o_get(d[i]);
  o_wait();
  // FAIL
  t_nx_fail = 1;
  o_cmd(4, 24'h000003, 0, 2);
  o_put(8'h00); o_put(8'h00);
  o_wait();
  irq_expect(IRQ_FAIL);
  rd_exp(A_STATUS, 32'hE1);
  // TIMEOUT; CMD written while the core is busy, then again while full
  t_nx_slow = 1;
  o_cmd(5, 24'h000004, 0, 0);
  cycles(50);
  o_cmd(2, 0, 0, 0);
  rd(A_FLAGS);
  if (!rdv[FLAG_CMD_FULL]) fail("FLAGS: CMD not full while the core is busy");
  wr(A_CMD1, 0);
  irq_expect(IRQ_CMD_OVF);
  poll(A_IRQ_STATUS, 1 << IRQ_TIMEOUT, 1 << IRQ_TIMEOUT, 2000);
  cycles(100);                                 // the Read Status sees the target busy
  rd_exp(A_STATUS, 32'h81);
  wr(A_IRQ_STATUS, 1 << IRQ_DONE);
  while (!rb_n) cycles(1);
  for (int i = 0; i < PS; i++) hf[4 * PS + i] = 8'hFF;
  // WR written while full: the held byte opens the next Set Features
  o_put(8'h11);
  wr(A_WR, 8'h22);
  irq_expect(IRQ_WR_OVF);
  o_cmd(7, 0, 16'h0002, 0);
  o_put(8'h33); o_put(8'h44); o_put(8'h55);
  o_wait();
  o_cmd(6, 0, 16'h0002, 0);
  o_get(8'h11); o_get(8'h33); o_get(8'h44); o_get(8'h55);
  o_wait();
  o_cmd(3, 24'h000004, 0, 8);
  for (int i = 0; i < 8; i++) o_get(8'hFF);
  o_wait();
  rd(A_RD);                                    // empty
  o_cmd(2, 0, 0, 0);
  cycles(60);

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[7:0] != 8'hFF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 8; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[7:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  wr(A_IRQ_ENABLE, 1 << IRQ_DONE);
  o_cmd(2, 0, 0, 0);
  cycles(40);
  if (!irq) fail("irq low with DONE pending");
  wr(A_IRQ_ENABLE, 0);
endtask
