// SPDX-License-Identifier: Apache-2.0
// OBI 1.6 subordinate: concurrent SVA against an independent model (memory
// shadow with byte enables, AMO / LR / SC, error classes, the response
// queue) + the OBI handshake rules + functional coverage.
`include "cov_macros.svh"
module OBI_sva #(parameter int NOUT = 4, IDW = 4, parameter logic [9:0] PROT_BASE = 10'h300) (
  input logic clk, rst_n,
  input logic req, gnt, we, reqpar, gntpar,
  input logic [31:0] addr, wdata,
  input logic [3:0] be,
  input logic [IDW-1:0] aid, rid,
  input logic [2:0] prot,
  input logic [5:0] atop,
  input logic rvalid, rready, err, rvalidpar, rreadypar,
  input logic [31:0] rdata,
  input logic irq_dec, irq_prot, irq_atop, irq_par
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- reference model ----------------
  logic [31:0] shadow [0:255];
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  logic           m_rv;
  logic [7:0]     m_ra;
  logic [31:0]    q_d [0:NOUT];
  logic           q_e [0:NOUT];
  logic [IDW-1:0] q_i [0:NOUT];
  int             m_n;
  logic [3:0]     m_irq;              // expected {dec, prot, atop, par}

  wire acc = req && gnt;
  wire pop = rvalid && rready;
  wire [7:0] wi  = addr[9:2];
  wire [4:0] op  = atop[4:0];
  wire amo_op = op == 5'h01 || op == 5'h00 || op == 5'h04 || op == 5'h0C || op == 5'h08 ||
                op == 5'h10 || op == 5'h14 || op == 5'h18 || op == 5'h1C;
  wire c_dec  = addr[31:10] != 0;
  wire c_prv  = !c_dec && addr[9:0] >= PROT_BASE && prot[2:1] != 2'b11;
  wire c_atp  = atop[5] ? !((op == 5'h02 && !we) || ((op == 5'h03 || amo_op) && we)) : op != 0;
  wire c_bad  = c_dec || c_prv || c_atp;
  wire c_lr   = atop[5] && op == 5'h02, c_sc = atop[5] && op == 5'h03, c_amo = atop[5] && amo_op;
  wire c_scok = m_rv && m_ra == wi;
  wire [31:0] o = shadow[wi];
  function automatic logic [31:0] f_amo(input logic [4:0] f, input logic [31:0] a, input logic [31:0] b);
    case (f)
      5'h01: return b;
      5'h00: return a + b;
      5'h04: return a ^ b;
      5'h0C: return a & b;
      5'h08: return a | b;
      5'h10: return ($signed(a) < $signed(b)) ? a : b;
      5'h14: return ($signed(a) < $signed(b)) ? b : a;
      5'h18: return (a < b) ? a : b;
      default: return (a < b) ? b : a;
    endcase
  endfunction
  logic [31:0] e_d;
  always_comb begin
    if (c_bad) e_d = 0;
    else if (c_sc) e_d = {31'h0, !c_scok};
    else if (c_lr || c_amo || !we) e_d = o;
    else e_d = 0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_rv <= 0; m_ra <= 0; m_n <= 0; m_irq <= 0;
    end else begin
      m_irq <= {acc && c_dec, acc && c_prv, acc && !c_dec && !c_prv && c_atp,
                reqpar == req || rreadypar == rready};
      if (acc && !c_bad) begin
        if (c_lr) begin m_rv <= 1; m_ra <= wi; end
        else if (c_sc) begin m_rv <= 0; if (c_scok) shadow[wi] <= wdata; end
        else if (c_amo) begin shadow[wi] <= f_amo(op, o, wdata); if (m_ra == wi) m_rv <= 0; end
        else if (we) begin
          for (int b = 0; b < 4; b++) if (be[b]) shadow[wi][8*b +: 8] <= wdata[8*b +: 8];
          if (m_ra == wi) m_rv <= 0;
        end
      end
      // response queue: shift on pop, append on accept
      for (int k = 0; k < NOUT; k++)
        if (pop) begin q_d[k] <= q_d[k+1]; q_e[k] <= q_e[k+1]; q_i[k] <= q_i[k+1]; end
      if (acc) begin
        q_d[m_n - int'(pop)] <= e_d; q_e[m_n - int'(pop)] <= c_bad; q_i[m_n - int'(pop)] <= aid;
      end
      m_n <= m_n + int'(acc) - int'(pop);
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_gnt, gnt == (req && m_n < NOUT))
  `SVA_INV(a_rvalid, rvalid == (m_n != 0))
  `SVA_IMP(a_rsp, rvalid, rdata == q_d[0] && err == q_e[0] && rid == q_i[0])
  `SVA_NXT(a_hold, rvalid && !rready, rvalid && $stable(rdata) && $stable(err) && $stable(rid))
  `SVA_INV(a_par_out, gntpar == !gnt && rvalidpar == !rvalid)
  `SVA_INV(a_irq, {irq_dec, irq_prot, irq_atop, irq_par} == m_irq)
  `SVA_INV(a_no_x, !$isunknown({gnt, rvalid, irq_dec, irq_prot, irq_atop, irq_par}))
  `SVA_RST(a_rst, 1'b1, !gnt && !rvalid && !irq_dec && !irq_prot && !irq_atop && !irq_par)

  // ---------------- functional coverage ----------------
  function automatic logic [1:0] dcls(input logic [31:0] d);
    return d == 0 ? 2'd0 : d == 32'hFFFF_FFFF ? 2'd1 : (d == 32'h5555_5555 || d == 32'hAAAA_AAAA) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_req @(posedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint (c_bad ? 3'd0 : c_lr ? 3'd1 : c_sc ? 3'd2 : c_amo ? 3'd3 : we ? 3'd4 : 3'd5) iff (rst_n && acc)
      { bins error = {0}; bins lr = {1}; bins sc = {2}; bins amo = {3}; bins write = {4}; bins read = {5}; }
    cp_err: coverpoint (c_dec ? 2'd0 : c_prv ? 2'd1 : 2'd2) iff (rst_n && acc && c_bad)
      { bins dec = {0}; bins prot = {1}; bins atop = {2}; }
    cp_amo: coverpoint op iff (rst_n && acc && c_amo && !c_bad)
      { bins swap = {5'h01}; bins add = {5'h00}; bins xor_ = {5'h04}; bins and_ = {5'h0C}; bins or_ = {5'h08};
        bins min = {5'h10}; bins max = {5'h14}; bins minu = {5'h18}; bins maxu = {5'h1C}; }
    cp_sc: coverpoint c_scok iff (rst_n && acc && c_sc && !c_bad) { bins fail = {0}; bins ok = {1}; }
    cp_be: coverpoint be iff (rst_n && acc && we && !atop[5] && !c_bad)
      { bins none = {4'h0}; bins b0 = {4'h1}; bins b1 = {4'h2}; bins b2 = {4'h4}; bins b3 = {4'h8};
        bins lo = {4'h3}; bins hi = {4'hC}; bins all = {4'hF}; bins other = default; }
    cp_priv: coverpoint prot[2:1] iff (rst_n && acc && addr[31:10] == 0 && addr[9:0] >= PROT_BASE)
      { bins user = {2'b00}; bins sup = {2'b01}; bins res = {2'b10}; bins mach = {2'b11}; }
    cp_depth: coverpoint m_n iff (rst_n && acc) { bins d[] = {[0:NOUT-1]}; }
    x_kind_depth: cross cp_kind, cp_depth;
    cp_wdata: coverpoint dcls(wdata) iff (rst_n && acc && we && !c_bad)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_req u_cg_req = new;
  covergroup cg_rsp @(posedge clk);
    option.per_instance = 1;
    cp_rdata: coverpoint dcls(rdata) iff (rst_n && pop && !err)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_stall: coverpoint rready iff (rst_n && rvalid) { bins stall = {0}; bins take = {1}; }
  endgroup
  cg_rsp u_cg_rsp = new;

  `FC(full_fifo_req_waits, req && m_n == NOUT)
  `FC(accept_and_pop, acc && pop)
  `FC(back_to_back, acc ##1 acc ##1 acc)
  `FC(stall_then_take, rvalid && !rready ##1 rvalid && rready)
  `FC(sc_after_lr_ok, acc && c_sc && c_scok && !c_bad)
  `FC(lr_broken_by_write, m_rv && acc && we && !atop[5] && !c_bad && m_ra == wi)
  `FC(signed_min_differs, acc && c_amo && op == 5'h10 && !c_bad && o[31] != wdata[31])
  `FC(reqpar_fault, rst_n && reqpar == req)
  `FC(rreadypar_fault, rst_n && rreadypar == rready)
  `FC_RST(reset_with_outstanding, rst_n && m_n != 0 ##1 !rst_n)
endmodule

bind OBI_top OBI_sva #(.NOUT(NOUT), .IDW(IDW), .PROT_BASE(PROT_BASE)) u_sva (.*);
