// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// ============================================================================
// Wishbone B4 pipelined slave -- real protocol IP design
// Scope : WB B4 slave, pipelined mode (stall_o backpressure, in-order ack_o)
//         + classic cycle compatibility (cti_i = 3'b000), SEL partial-write
//         merge, reserved region (adr >= 0x800) -> err_o, 256x32 regfile.
//         rty_o tied off (this slave never requests retry).
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module Wishbone_top #(
  parameter int DW    = 32,   // data width
  parameter int AW    = 32,   // address width
  parameter int DEPTH = 256   // internal register-file depth (words)
)(
  input  logic          clk,
  input  logic          rst_n,
  // Wishbone B4 slave interface
  input  logic          cyc_i,
  input  logic          stb_i,
  input  logic          we_i,
  input  logic [AW-1:0] adr_i,
  input  logic [DW-1:0] dat_i,
  input  logic [3:0]    sel_i,
  input  logic [2:0]    cti_i,   // cycle type identifier (000 = classic)
  output logic [DW-1:0] dat_o,
  output logic          ack_o,
  output logic          stall_o,
  output logic          err_o,
  output logic          rty_o,
  output logic          irq
);

  // ------------------------------------------------------------------
  // address map
  //   0x000-0x1FF : fast window  (word idx 0..127, 1-cycle service)
  //   0x200-0x3FF : slow window  (word idx 128..255, 1 extra wait state)
  //   0x400-0x7FF : hole         (ack, reads return 0, writes dropped)
  //   0x800+      : reserved     -> err_o response + sticky irq
  // ------------------------------------------------------------------
  localparam logic [31:0] VALID_END = 32'h0000_0400;
  localparam logic [31:0] RSV_START = 32'h0000_0800;

  (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];

  // ------------------------------------------------------------------
  // outstanding-request queue (2 deep) : pipelined acceptance
  // ------------------------------------------------------------------
  logic        q_we   [0:1];
  logic [7:0]  q_idx  [0:1];
  logic [3:0]  q_sel  [0:1];
  logic [31:0] q_data [0:1];
  logic        q_ok   [0:1];   // inside valid regfile window
  logic        q_rsv  [0:1];   // reserved window -> error response
  logic        q_slow [0:1];   // slow window -> extra wait state
  logic [1:0]  q_count;

  // service FSM
  typedef enum logic [1:0] {S_IDLE, S_WAIT, S_RESP} svc_t;
  svc_t state;

  // classic-cycle guard : a cti_i=000 master holds stb_i until ack_o, so the
  // held strobe must not be re-accepted as a new request; block acceptance
  // until stb_i is observed low again.  Pipelined cycles (cti_i/=000) are
  // accepted every cycle while stall_o is low.
  logic        cls_blk;

  wire in_valid = (adr_i < VALID_END);
  wire in_rsv   = (adr_i >= RSV_START);
  wire acc      = cyc_i & stb_i & ~stall_o & ~cls_blk;

  // response issued for the queue head this cycle
  wire head_fast = (state == S_IDLE) && (q_count != 2'd0) && !q_slow[0];
  wire head_resp = head_fast || (state == S_RESP);
  wire pop       = head_resp;

  assign stall_o = (q_count == 2'd2);
  assign rty_o   = 1'b0;                    // never retry
  assign ack_o   = head_resp & ~q_rsv[0];
  assign err_o   = head_resp &  q_rsv[0];
  assign dat_o   = (q_ok[0] && !q_we[0]) ? mem[q_idx[0]] : {DW{1'b0}};

  // ------------------------------------------------------------------
  // sequential : queue, service FSM, regfile write, sticky irq
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      q_count   <= 2'd0;
      irq       <= 1'b0;
      q_we[0]   <= 1'b0;  q_we[1]   <= 1'b0;
      q_idx[0]  <= 8'd0;  q_idx[1]  <= 8'd0;
      q_sel[0]  <= 4'd0;  q_sel[1]  <= 4'd0;
      q_data[0] <= 32'd0; q_data[1] <= 32'd0;
      q_ok[0]   <= 1'b0;  q_ok[1]   <= 1'b0;
      q_rsv[0]  <= 1'b0;  q_rsv[1]  <= 1'b0;
      q_slow[0] <= 1'b0;  q_slow[1] <= 1'b0;
      cls_blk   <= 1'b0;
    end else begin
      // classic-cycle guard bookkeeping
      if (acc && (cti_i == 3'b000)) cls_blk <= 1'b1;
      else if (!stb_i)              cls_blk <= 1'b0;

      // service FSM
      case (state)
        S_IDLE : if ((q_count != 2'd0) && q_slow[0]) state <= S_WAIT;
        S_WAIT : state <= S_RESP;
        S_RESP : state <= S_IDLE;
        default: state <= S_IDLE;
      endcase

      // pop : shift entry 1 down to head
      if (pop) begin
        q_we[0]   <= q_we[1];
        q_idx[0]  <= q_idx[1];
        q_sel[0]  <= q_sel[1];
        q_data[0] <= q_data[1];
        q_ok[0]   <= q_ok[1];
        q_rsv[0]  <= q_rsv[1];
        q_slow[0] <= q_slow[1];
      end

      // push : lands at position (q_count - pop)
      if (acc) begin
        if (q_count == {1'b0, pop}) begin
          q_we[0]   <= we_i;
          q_idx[0]  <= adr_i[9:2];
          q_sel[0]  <= sel_i;
          q_data[0] <= dat_i;
          q_ok[0]   <= in_valid;
          q_rsv[0]  <= in_rsv;
          q_slow[0] <= in_valid & adr_i[9];
        end else begin
          q_we[1]   <= we_i;
          q_idx[1]  <= adr_i[9:2];
          q_sel[1]  <= sel_i;
          q_data[1] <= dat_i;
          q_ok[1]   <= in_valid;
          q_rsv[1]  <= in_rsv;
          q_slow[1] <= in_valid & adr_i[9];
        end
      end
      q_count <= q_count + {1'b0, acc} - {1'b0, pop};

      // regfile write with SEL byte-lane merge (in service order)
      if (pop && q_ok[0] && q_we[0]) begin
        for (int b = 0; b < 4; b++)
          if (q_sel[0][b])
            mem[q_idx[0]][b*8 +: 8] <= q_data[0][b*8 +: 8];
      end

      // sticky interrupt on reserved-region error response
      if (head_resp && q_rsv[0])
        irq <= 1'b1;
    end
  end

  // cti_i is sampled for B4 compliance; classic (000) and pipelined
  // cycles share the same acceptance path, so no extra handling needed.

endmodule
