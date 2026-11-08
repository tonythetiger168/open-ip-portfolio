// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// OBI 1.6 subordinate (OpenHW Open Bus Interface): a 256 x 32-bit memory
// behind a pipelined A channel (req / gnt) and an in-order R channel
// (rvalid / rready) with up to NOUT transactions outstanding.
//   * A phase: a request is taken on req && gnt; gnt is only given to a
//     request (gnt implies req) and drops while NOUT responses wait.
//   * R phase: one response per granted request, in order, held stable
//     while rvalid && !rready; rid echoes the request's aid.
//   * Byte enables on writes; reads return the whole word.
//   * Errors (err = 1, write dropped, rdata 0): an address at or above
//     0x400 (decode), a user-mode access (prot[2:1] != 2'b11) to the
//     machine-only window from PROT_BASE up (protection), and an atop
//     code with atop[5] = 0 or an undefined AMO (unsupported).
//   * Atomics (atop[5] = 1, RISC-V A extension encoding in atop[4:0]):
//     AMOSWAP / ADD / XOR / AND / OR / MIN / MAX / MINU / MAXU read the
//     old word (returned in rdata) and write the result in the same
//     cycle; LR.W (we = 0) sets the reservation, SC.W (we = 1) writes
//     only if it holds and returns 0 on success, 1 on failure. Any other
//     write to the reserved word, and every SC, clears the reservation.
//   * Integrity handshake (OBI 1.6 parity signals): gntpar = ~gnt and
//     rvalidpar = ~rvalid; reqpar must be ~req and rreadypar ~rready,
//     a mismatch pulses irq_par.
// irq_dec / irq_prot / irq_atop pulse with the err response of the
// failing request (a decode error takes precedence).
// The memory is not cleared by reset (sim zeroes it once).
// ============================================================================
module OBI_top #(
  parameter int NOUT = 4,                 // outstanding responses (FIFO depth)
  parameter int IDW  = 4,                 // aid / rid width
  parameter logic [9:0] PROT_BASE = 10'h300   // machine-only window start
)(
  input  logic            clk,
  input  logic            rst_n,
  // A channel
  input  logic            req,
  output logic            gnt,
  input  logic [31:0]     addr,
  input  logic            we,
  input  logic [3:0]      be,
  input  logic [31:0]     wdata,
  input  logic [IDW-1:0]  aid,
  input  logic [2:0]      prot,           // [2:1] privilege (11 = machine), [0] data
  input  logic [5:0]      atop,
  input  logic            reqpar,
  output logic            gntpar,
  // R channel
  output logic            rvalid,
  input  logic            rready,
  output logic [31:0]     rdata,
  output logic            err,
  output logic [IDW-1:0]  rid,
  output logic            rvalidpar,
  input  logic            rreadypar,
  // events
  output logic            irq_dec,
  output logic            irq_prot,
  output logic            irq_atop,
  output logic            irq_par
);
  localparam int CW = $clog2(NOUT + 1);
  localparam int PW = (NOUT > 1) ? $clog2(NOUT) : 1;

  logic [31:0] mem [0:255];
`ifndef SYNTHESIS
  initial for (int i = 0; i < 256; i++) mem[i] = '0;
`endif

  // ---------------- response FIFO ----------------
  logic [31:0]    f_data [0:NOUT-1];
  logic           f_err  [0:NOUT-1];
  logic [IDW-1:0] f_id   [0:NOUT-1];
  logic [PW-1:0]  rd_p, wr_p;
  logic [CW-1:0]  count;

  assign gnt       = req && (count != CW'(NOUT));
  assign gntpar    = ~gnt;
  assign rvalid    = (count != 0);
  assign rvalidpar = ~rvalid;
  assign rdata     = f_data[rd_p];
  assign err       = f_err[rd_p];
  assign rid       = f_id[rd_p];

  wire acc = req && gnt;
  wire pop = rvalid && rready;

  // ---------------- request decode ----------------
  wire [7:0] widx    = addr[9:2];
  wire       dec_bad = (addr[31:10] != 0);
  wire       prv_bad = !dec_bad && (addr[9:0] >= PROT_BASE) && (prot[2:1] != 2'b11);
  wire [4:0] op      = atop[4:0];
  wire       is_atop = atop[5];
  wire       op_lr   = (op == 5'b00010);
  wire       op_sc   = (op == 5'b00011);
  wire       op_amo  = (op == 5'b00001) || (op == 5'b00000) || (op == 5'b00100) ||
                       (op == 5'b01100) || (op == 5'b01000) || (op == 5'b10000) ||
                       (op == 5'b10100) || (op == 5'b11000) || (op == 5'b11100);
  // atop[5] = 0 must come with atop = 0; LR is a read, SC and AMOs writes
  wire       atp_bad = is_atop ? !((op_lr && !we) || ((op_sc || op_amo) && we))
                               : (op != 0);
  wire       bad     = dec_bad || prv_bad || atp_bad;

  logic       rsv_v;                       // LR reservation
  logic [7:0] rsv_a;
  wire        sc_ok = rsv_v && (rsv_a == widx);

  wire [31:0] old = mem[widx];
  // byte-enable merge of a plain write
  logic [31:0] merged;
  always_comb
    for (int b = 0; b < 4; b++)
      merged[8*b +: 8] = be[b] ? wdata[8*b +: 8] : old[8*b +: 8];
  // AMO result
  logic [31:0] amo;
  always_comb
    case (op)
      5'b00001: amo = wdata;
      5'b00000: amo = old + wdata;
      5'b00100: amo = old ^ wdata;
      5'b01100: amo = old & wdata;
      5'b01000: amo = old | wdata;
      5'b10000: amo = ($signed(old) < $signed(wdata)) ? old : wdata;
      5'b10100: amo = ($signed(old) < $signed(wdata)) ? wdata : old;
      5'b11000: amo = (old < wdata) ? old : wdata;
      default:  amo = (old < wdata) ? wdata : old;    // 5'b11100 AMOMAXU
    endcase
  // word written and response data
  wire        do_wr  = !bad && we && (!is_atop || op_amo || (op_sc && sc_ok));
  wire [31:0] wr_val = is_atop ? (op_sc ? wdata : amo) : merged;
  wire [31:0] r_val  = bad ? 32'h0 : (is_atop && op_sc) ? {31'h0, !sc_ok} :
                       (we && !is_atop) ? 32'h0 : old;

  always_ff @(posedge clk) if (acc && do_wr) mem[widx] <= wr_val;
  // prot[0] (data / instruction) does not change how the memory answers
  wire _unused = &{1'b0, prot[0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_p <= '0; wr_p <= '0; count <= '0;
      rsv_v <= 1'b0; rsv_a <= '0;
      irq_dec <= 1'b0; irq_prot <= 1'b0; irq_atop <= 1'b0; irq_par <= 1'b0;
      for (int i = 0; i < NOUT; i++) begin f_data[i] <= '0; f_err[i] <= 1'b0; f_id[i] <= '0; end
    end else begin
      irq_dec  <= acc && dec_bad;
      irq_prot <= acc && prv_bad;
      irq_atop <= acc && !dec_bad && !prv_bad && atp_bad;
      irq_par  <= (reqpar == req) || (rreadypar == rready);
      if (acc) begin
        f_data[wr_p] <= r_val; f_err[wr_p] <= bad; f_id[wr_p] <= aid;
        wr_p <= (wr_p == PW'(NOUT - 1)) ? '0 : wr_p + 1'b1;
        if (!bad) begin
          if (is_atop && op_lr) begin rsv_v <= 1'b1; rsv_a <= widx; end
          else if (is_atop && op_sc) rsv_v <= 1'b0;
          else if (we && rsv_a == widx) rsv_v <= 1'b0;
        end
      end
      if (pop) rd_p <= (rd_p == PW'(NOUT - 1)) ? '0 : rd_p + 1'b1;
      count <= count + CW'(acc) - CW'(pop);
    end
  end
endmodule
