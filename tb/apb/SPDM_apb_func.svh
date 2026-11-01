// SPDX-License-Identifier: Apache-2.0
// SPDM-specific part of tb/SPDM_apb_tb.sv: runs tb/SPDM_apb_vec.hex
// (scripts/spdm/gen_vec.py --apb, from the SPDM 1.2 reference model) with
// the configuration, the certificate chain and measurement stores, KeyGen
// (seed registers and the sideload pins), the public-key readout and the
// random words all through the registers, and the requests / responses on
// the rq_* / rs_* pins: every response byte is compared, signatures
// included. Also checks STATUS (conn, key, err_code), the RSP_DONE /
// RSP_ERR / KG_DONE / CMD_ERR interrupts, RN_FULL back-pressure and the irq
// pin, enabled and masked.
logic [31:0] spv [0:16383];
int          spp;

function automatic logic [7:0] spb(input int base, input int i);
  return 8'(spv[base + i / 4] >> (8 * (i % 4)));
endfunction

task automatic sp_cfg;
  wr(A_CFG, {21'd0, 1'b0, 2'(spv[spp + 2]), 8'(spv[spp])});
  wr(A_ASYM, spv[spp + 1]);
  wr(A_CCLEN, spv[spp + 3]);
  wr(A_MEAS, {24'd0, 4'(spv[spp + 5]), 4'(spv[spp + 4])});
  wr(A_MTYPE, spv[spp + 6]);
  spp += 7;
endtask

task automatic sp_store(input logic [23:0] arg);
  int n;
  n = int'(arg[15:0]);
  for (int i = 0; i < n; i++) begin
    wr(A_STORE0, spv[spp + 1 + i]);
    wr(A_STORE1, {19'd0, arg[16], 12'(spv[spp] + 32'(i))});
  end
  spp += n + 1;
endtask

task automatic sp_keygen(input logic [23:0] arg);
  logic [255:0] s;
  for (int i = 0; i < 8; i++) s[32 * i +: 32] = spv[spp + i];
  spp += 8;
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_CFG);
  wr(A_CFG, {21'd0, arg[0], arg[13:12], rdv[7:0]});
  if (arg[0]) sl_seed = s;
  else for (int i = 0; i < 8; i++) wr(A_SEED0 + 12'(4 * i), s[32 * i +: 32]);
  wr(A_CMD, 32'h1);
  if (arg[8]) begin
    cycles(2);
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_CMD_ERR]) fail("KeyGen not refused");
  end else begin
    poll(A_IRQ_STATUS, 32'h1 << IRQ_KG_DONE, 32'h1 << IRQ_KG_DONE, 100000);
    rd(A_STATUS);
    if (!rdv[3] || rdv[5:4] !== arg[13:12] || rdv[0]) fail($sformatf("STATUS after KeyGen: %h", rdv));
  end
  for (int i = 0; i < 8; i++) wr(A_SEED0 + 12'(4 * i), 32'h0);
  sl_seed = '0;
endtask

task automatic sp_pk(input logic [23:0] arg);
  int n;
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD, 32'h2);
  n = int'(arg[15:0]);
  for (int i = 0; i < n; i++) begin
    poll(A_FLAGS, 32'h1 << FLAG_PK_AVAIL, 32'h1 << FLAG_PK_AVAIL, 50);
    rd(A_PK0);
    if (rdv !== spv[spp + i]) fail($sformatf("PK word %0d: %h, expected %h", i, rdv, spv[spp + i]));
    rd(A_PK1);
    if (rdv[0] !== (i == n - 1)) fail($sformatf("PK word %0d: last %b", i, rdv[0]));
  end
  spp += n;
  cycles(4);
  rd_exp(A_FLAGS, 0);
endtask

task automatic sp_req(input logic [23:0] arg);
  int ql, rl, nrn, qb, rb, bad, t;
  ql = int'(arg[15:0]);
  nrn = int'(spv[spp] >> 24);
  rl = int'(spv[spp] & 32'hFFFFFF);
  qb = spp + 1 + nrn;
  rb = qb + (ql + 3) / 4;
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (int i = 0; i < ql; i++) begin
    @(negedge PCLK);
    rq_valid = 1'b1; rq_data = spb(qb, i); rq_last = i == ql - 1;
    #1;
    while (!rq_ready) begin @(negedge PCLK); #1; end
    @(posedge PCLK);
    #1 rq_valid = 1'b0; rq_last = 1'b0;
  end
  // the random words: each written once RN is free
  for (int i = 0; i < nrn; i++) begin
    poll(A_FLAGS, 32'h1 << FLAG_RN_FULL, 0, 2000);
    wr(A_RN, spv[spp + 1 + i]);
  end
  bad = 0;
  for (int i = 0; i < rl; i++) begin
    t = 0;
    @(negedge PCLK); rs_ready = 1'b1;
    while (!rs_valid && t < 3000000) begin @(negedge PCLK); t++; end
    if (!rs_valid) begin fail("response byte missing"); i = rl; end
    else if (rs_data !== spb(rb, i) || rs_last !== (i == rl - 1)) begin
      if (bad < 3) fail($sformatf("response %02h %02h byte %0d: %02h, expected %02h",
                                  spb(qb, 0), spb(qb, 1), i, rs_data, spb(rb, i)));
      bad++;
    end
    @(posedge PCLK);
    #1 rs_ready = 1'b0;
  end
  poll(A_STATUS, 32'h1, 32'h0, 2000);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_RSP_DONE] || rdv[IRQ_RSP_ERR] !== (spb(rb, 1) == 8'h7F)) fail($sformatf("IRQ_STATUS after a response: %h", rdv));
  if (spb(rb, 1) == 8'h7F) begin
    rd(A_STATUS);
    if (rdv[13:6] !== spb(rb, 2)) fail($sformatf("STATUS.err_code %h, expected %h", rdv[13:6], spb(rb, 2)));
  end
  spp = rb + (rl + 3) / 4;
endtask

task automatic ip_func;
  int op;
  logic [23:0] arg;
  bit fin;
  if ($fopen("tb/SPDM_apb_vec.hex", "r") != 0) $readmemh("tb/SPDM_apb_vec.hex", spv);
  else if ($fopen("../tb/SPDM_apb_vec.hex", "r") != 0) $readmemh("../tb/SPDM_apb_vec.hex", spv);
  else $readmemh("../../../../tb/SPDM_apb_vec.hex", spv);
  sl_seed = '0; sl_valid = 1'b0; rq_valid = 1'b0; rq_data = '0; rq_last = 1'b0; rs_ready = 1'b0;
  // the register tests pulsed CMD with all ones: clr ran; a word may sit in RN
  poll(A_STATUS, 32'h1, 32'h0, 5000);
  rd_exp(A_STATUS, 32'h0);
  // the PK readout without a key is refused, and so is a command while busy
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CMD, 32'h2);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_CMD_ERR]) fail("pk_open without a key not refused");
  wr(A_IRQ_ENABLE, 32'h1 << IRQ_CMD_ERR);
  cycles(1);
  if (irq !== 1'b1) fail("irq pin low with CMD_ERR enabled");
  wr(A_IRQ_ENABLE, 0);
  cycles(1);
  if (irq !== 1'b0) fail("irq pin high with every interrupt masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  spp = 0;
  fin = 0;
  while (!fin) begin
    op = int'(spv[spp] >> 24); arg = spv[spp][23:0]; spp++;
    case (op)
      1: sp_cfg();
      2: sp_store(arg);
      3: sp_keygen(arg);
      4: sp_pk(arg);
      5: sp_req(arg);
      6: begin
        wr(A_CMD, 32'h4);
        poll(A_STATUS, 32'h1, 32'h0, 5000);
        rd(A_STATUS);
        if (rdv[3:1] !== 3'd0) fail("key or connection left after clr");
      end
      7: sl_valid = arg[0];
      default: fin = 1;
    endcase
  end
  // RN back-pressure: a second word while one is held is dropped (RN_OVF)
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_RN, 32'h1234_5678);
  wr(A_RN, 32'h9ABC_DEF0);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_RN_OVF]) fail("no RN_OVF");
  rd(A_FLAGS);
  if (!rdv[FLAG_RN_FULL]) fail("RN not held");
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
