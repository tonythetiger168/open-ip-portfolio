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
  // classes computed at the clock edge, sampled half a clock later (-1: idle)
  function automatic int dcls(input logic [31:0] d);
    return d == 0 ? 0 : d == 32'hFFFF_FFFF ? 1 : (d == 32'h5555_5555 || d == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  int k_kind, k_err, k_amo, k_sc, k_be, k_priv, k_kd, k_wd, k_rd, k_stall;
  always @(posedge clk) begin
    k_kind = -1; k_err = -1; k_amo = -1; k_sc = -1; k_be = -1; k_priv = -1; k_kd = -1;
    k_wd = -1; k_rd = -1; k_stall = -1;
    if (rst_n && acc) begin
      k_kind = c_bad ? 0 : c_lr ? 1 : c_sc ? 2 : c_amo ? 3 : we ? 4 : 5;
      // request class x responses already waiting
      k_kd = 4 * (c_bad ? 0 : atop[5] ? 1 : we ? 2 : 3) + m_n;
      if (c_bad) k_err = c_dec ? 0 : c_prv ? 1 : 2;
      if (c_amo && !c_bad) k_amo = op;
      if (c_sc && !c_bad) k_sc = c_scok;
      if (we && !atop[5] && !c_bad) k_be = be;
      if (addr[31:10] == 0 && addr[9:0] >= PROT_BASE) k_priv = prot[2:1];
      if (we && !c_bad) k_wd = dcls(wdata);
    end
    if (rst_n && pop && !err) k_rd = dcls(rdata);
    if (rst_n && rvalid) k_stall = rready;
  end
  covergroup cg_req @(negedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint k_kind { bins error = {0}; bins lr = {1}; bins sc = {2}; bins amo = {3}; bins write = {4}; bins read = {5}; }
    cp_err: coverpoint k_err { bins dec = {0}; bins prot = {1}; bins atop = {2}; }
    cp_amo: coverpoint k_amo
      { bins swap = {1}; bins add = {0}; bins xor_ = {4}; bins and_ = {12}; bins or_ = {8};
        bins min = {16}; bins max = {20}; bins minu = {24}; bins maxu = {28}; }
    cp_sc: coverpoint k_sc { bins fail = {0}; bins ok = {1}; }
    cp_be: coverpoint k_be
      { bins none = {0}; bins b0 = {1}; bins b1 = {2}; bins b2 = {4}; bins b3 = {8};
        bins lo = {3}; bins hi = {12}; bins all = {15}; bins other = {5, 6, 7, 9, 10, 11, 13, 14}; }
    cp_priv: coverpoint k_priv { bins user = {0}; bins sup = {1}; bins res = {2}; bins mach = {3}; }
    cp_kind_depth: coverpoint k_kd { bins kd[] = {[0:4*NOUT-1]}; }
    cp_wdata: coverpoint k_wd { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint k_rd { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_stall: coverpoint k_stall { bins stall = {0}; bins take = {1}; }
  endgroup
  cg_req u_cg_req = new;

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
