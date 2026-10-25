// SPDX-License-Identifier: Apache-2.0
// UALink-specific part of tb/UALink_apb_tb.sv. A small originator model
// sits on the UPLI channels: it counts the request and data credits the
// completer grants, sends requests and their data beats, grants response
// credits, and checks every response against a reference memory.
// Covered through the registers: traffic without an error leaves
// IRQ_STATUS clear, UR and BAD requests set ERR, a request without a
// credit, a wrong od_last and a response credit past 15 set PROTO, every
// interrupt bit masked, raising irq and cleared.
localparam int MW = 16;

// ---------------- originator ----------------
logic [63:0] r_mem [0:MW-1];
logic [74:0] e_rd [$];                         // {tag, data, last, status}
logic [9:0]  e_wr [$];                         // {tag, status}
logic [72:0] oq [$];                           // {data, be, last}
int  m_rq = 0, m_od = 0, c_rd = 0, c_wr = 0, n_req = 0;
bit  req_on = 0, nocrd = 0, bad_last = 0, over = 0, crd_on = 1, od_hold = 0;
int  p_err = 0;
initial begin
  for (int i = 0; i < MW; i++) r_mem[i] = 0;
  req_valid = 0; req_cmd = 0; req_tag = 0; req_addr = 0; req_len = 0;
  od_valid = 0; od_data = 0; od_be = 0; od_last = 0; rd_crd = 0; wr_crd = 0;
end

task automatic make_req(output logic [2:0] cmd, output logic [15:0] addr, output logic [2:0] len, input logic [7:0] tag);
  int w, st, nb;
  bit at;
  logic [63:0] d0, d1, old;
  logic [7:0]  be;
  cmd = $urandom % 5;
  w = $urandom % MW;
  len = cmd >= 2 ? 0 : $urandom % 8;
  if (w + len >= MW) len = MW - 1 - w;
  addr = 16'(w * 8);
  if ($urandom % 100 < p_err)
    case ($urandom % 3)
      0: cmd = 5 + $urandom % 3;
      1: addr[2:0] = 1 + $urandom % 7;
      default: begin addr = $urandom; addr[2:0] = 0; addr[15] = 1; end
    endcase
  at = cmd >= 2 && cmd <= 4;
  w = addr[15:3];
  st = cmd > 4 || addr[2:0] != 0 ? 2 : w + (at ? 0 : len) >= MW ? 1 : 0;
  nb = cmd == 1 ? len + 1 : cmd == 2 || cmd == 3 ? 1 : cmd == 4 ? 2 : 0;
  case (cmd)
    0: if (st != 0) e_rd.push_back({tag, 64'd0, 1'b1, 2'(st)});
       else for (int i = 0; i <= len; i++) e_rd.push_back({tag, r_mem[w + i], i == len, 2'd0});
    1: begin
      for (int i = 0; i <= len; i++) begin
        d0 = {$urandom, $urandom}; be = $urandom % 2 ? 8'hFF : 8'($urandom);
        oq.push_back({d0, be, i == len});
        if (st == 0) for (int b = 0; b < 8; b++) if (be[b]) r_mem[w + i][8*b +: 8] = d0[8*b +: 8];
      end
      e_wr.push_back({tag, 2'(st)});
    end
    2, 3, 4: begin
      d0 = {$urandom, $urandom}; d1 = {$urandom, $urandom};
      if (cmd == 4 && st == 0 && $urandom % 2) d0 = r_mem[w];
      oq.push_back({d0, 8'hFF, nb == 1});
      if (nb == 2) oq.push_back({d1, 8'hFF, 1'b1});
      if (st != 0) e_rd.push_back({tag, 64'd0, 1'b1, 2'(st)});
      else begin
        old = r_mem[w];
        e_rd.push_back({tag, old, 1'b1, 2'd0});
        r_mem[w] = cmd == 2 ? old + d0 : cmd == 3 ? d0 : old == d0 ? d1 : old;
      end
    end
    default: e_wr.push_back({tag, 2'(st)});
  endcase
endtask

always @(negedge PCLK) begin : b_req
  logic [2:0]  c, l;
  logic [15:0] a;
  req_valid = 0;
  {req_cmd, req_tag, req_addr, req_len} = $urandom;
  if (PRESETN && req_crd) m_rq++;
  if (PRESETN && nocrd) begin
    nocrd = 0; req_valid = 1;
  end else if (PRESETN && req_on && m_rq > 0 && $urandom % 100 < 60) begin
    req_tag = $urandom;
    make_req(c, a, l, req_tag);
    req_valid = 1; req_cmd = c; req_addr = a; req_len = l;
    m_rq--; n_req++;
  end
end
always @(negedge PCLK) begin : b_od
  od_valid = 0;
  {od_data, od_be, od_last} = {$urandom, $urandom, $urandom};
  if (PRESETN && od_crd) m_od++;
  if (PRESETN && !od_hold && m_od > 0 && oq.size() != 0 && $urandom % 100 < 70) begin
    od_valid = 1; {od_data, od_be, od_last} = oq.pop_front();
    if (bad_last) begin bad_last = 0; od_last = !od_last; end
    m_od--;
  end
end
always @(negedge PCLK) begin
  rd_crd = 0; wr_crd = 0;
  if (PRESETN && (crd_on && c_rd < 15 && $urandom % 100 < 60 || over)) begin rd_crd = 1; if (!over) c_rd++; over = 0; end
  if (PRESETN && crd_on && c_wr < 15 && $urandom % 100 < 60) begin wr_crd = 1; c_wr++; end
end
always @(negedge PCLK) if (PRESETN) begin : b_chk
  logic [74:0] e;
  logic [9:0]  f;
  if (rd_valid) begin
    c_rd--;
    if (e_rd.size() == 0) fail("read response with none expected");
    else begin
      e = e_rd.pop_front();
      if ({rd_tag, rd_data, rd_last, rd_status} !== e) fail($sformatf("RD %h %h %0d %0d, expected %h", rd_tag, rd_data, rd_last, rd_status, e));
    end
  end
  if (wr_valid) begin
    c_wr--;
    if (e_wr.size() == 0) fail("write response with none expected");
    else begin
      f = e_wr.pop_front();
      if ({wr_tag, wr_status} !== f) fail($sformatf("WR %h %0d, expected %h", wr_tag, wr_status, f));
    end
  end
end

task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic drain;
  int t;
  t = 0;
  while ((e_rd.size() != 0 || e_wr.size() != 0 || oq.size() != 0) && t < 5000) begin cycles(1); t++; end
  if (t == 5000) fail("originator stuck");
  cycles(5);
endtask
task automatic traffic(input int n);
  req_on = 1;
  cycles(n);
  req_on = 0;
  drain();
endtask
// every response credit held: one more
task automatic credit_past_15;
  while (c_rd != 15) cycles(1);
  crd_on = 0;
  over = 1;
  cycles(3);
  crd_on = 1;
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);                            // no stream registers
  // the memory: every bit both ways, then random traffic with no error
  traffic(1500);
  rd_exp(A_IRQ_STATUS, 0);
  // errors
  p_err = 50;
  traffic(300);
  p_err = 0;
  irq_expect(IRQ_ERR);
  // a request without a credit: data held back, the request slots fill
  od_hold = 1; req_on = 1;
  while (!(m_rq == 0 && dut.u_core.rq_n == 4)) cycles(1);
  req_on = 0;
  nocrd = 1;
  cycles(2);
  od_hold = 0;
  drain();
  irq_expect(IRQ_PROTO);
  // a wrong od_last
  bad_last = 1;
  traffic(100);
  irq_expect(IRQ_PROTO);
  credit_past_15();
  irq_expect(IRQ_PROTO);
  // masked: each event again, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  p_err = 50;
  traffic(200);
  p_err = 0;
  bad_last = 1;
  traffic(100);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
