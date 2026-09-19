// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// ============================================================================
// TileLink TL-UL slave -- real protocol IP design
// Scope : TileLink Uncached Lightweight (TL-UL) slave, A/D channels only.
//         NOTE: TL-C (cached, B/C/E channels) is NOT in scope of this IP.
//         PutFull(0)/PutPartial(1)/Get(4), size must be 2 (4B, bus width),
//         4B alignment check, mask/size consistency check, source echo,
//         unsupported opcode/size/range -> d_error + sticky irq,
//         64x32 regfile.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module TileLink__TL_UL_TL_C__top #(
  parameter int DW    = 32,   // data width
  parameter int AW    = 32,   // address width
  parameter int DEPTH = 64    // internal register-file depth (words)
)(
  input  logic          clk,
  input  logic          rst_n,
  // TileLink A channel (request)
  input  logic          a_valid,
  output logic          a_ready,
  input  logic [2:0]    a_opcode,   // 0=PutFull, 1=PutPartial, 4=Get
  input  logic [2:0]    a_param,    // reserved in TL-UL, must be 0
  input  logic [2:0]    a_size,     // log2(bytes); only 2 supported
  input  logic [7:0]    a_source,
  input  logic [AW-1:0] a_address,
  input  logic [3:0]    a_mask,
  input  logic [DW-1:0] a_data,
  // TileLink D channel (response)
  output logic          d_valid,
  input  logic          d_ready,
  output logic [2:0]    d_opcode,   // 0=AccessAck, 1=AccessAckData
  output logic [2:0]    d_size,
  output logic [7:0]    d_source,
  output logic [DW-1:0] d_data,
  output logic          d_error,
  output logic          irq
);

  // ------------------------------------------------------------------
  // address map : 0x00-0xFF -> 64x32 regfile ; 0x100+ -> d_error
  // ------------------------------------------------------------------
  localparam logic [31:0] VALID_END = 32'h0000_0100;

  localparam logic [2:0] OP_PUTFULL    = 3'd0;
  localparam logic [2:0] OP_PUTPARTIAL = 3'd1;
  localparam logic [2:0] OP_GET        = 3'd4;
  localparam logic [2:0] RSP_ACCESSACK     = 3'd0;
  localparam logic [2:0] RSP_ACCESSACKDATA = 3'd1;

  logic [DW-1:0] mem [0:DEPTH-1];

  typedef enum logic [0:0] {S_IDLE, S_RESP} tls_t;
  tls_t state;

  // captured request / response registers
  logic [2:0]  d_opcode_q;
  logic [2:0]  d_size_q;
  logic [7:0]  d_source_q;
  logic [31:0] d_data_q;
  logic        d_error_q;

  // request legality decode (combinational, sampled on accept)
  wire op_ok   = (a_opcode == OP_PUTFULL) || (a_opcode == OP_PUTPARTIAL) ||
                 (a_opcode == OP_GET);
  wire size_ok = (a_size == 3'd2);                 // 4B only
  wire alg_ok  = (a_address[1:0] == 2'b00);        // size=2 alignment
  wire rng_ok  = (a_address < VALID_END);
  // mask/size consistency : full mask for Get & PutFull, non-zero for PutPartial
  wire mask_ok = (a_opcode == OP_PUTPARTIAL) ? (a_mask != 4'h0)
                                             : (a_mask == 4'hF);
  wire req_err = ~(op_ok & size_ok & alg_ok & rng_ok & mask_ok);

  wire accept = a_valid & a_ready;

  assign a_ready  = (state == S_IDLE) || (state == S_RESP && d_ready);
  assign d_valid  = (state == S_RESP);
  assign d_opcode = d_opcode_q;
  assign d_size   = d_size_q;
  assign d_source = d_source_q;
  assign d_data   = d_data_q;
  assign d_error  = d_error_q;

  // ------------------------------------------------------------------
  // sequential
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      d_opcode_q <= RSP_ACCESSACK;
      d_size_q   <= 3'd0;
      d_source_q <= 8'd0;
      d_data_q   <= 32'd0;
      d_error_q  <= 1'b0;
      irq        <= 1'b0;
    end else begin
      case (state)
        S_IDLE : if (accept) state <= S_RESP;
        S_RESP : if (d_ready && !accept) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase

      if (accept) begin
        d_opcode_q <= (a_opcode == OP_GET) ? RSP_ACCESSACKDATA : RSP_ACCESSACK;
        d_size_q   <= a_size;
        d_source_q <= a_source;                       // source echo
        d_error_q  <= req_err;
        d_data_q   <= ((a_opcode == OP_GET) && !req_err) ? mem[a_address[7:2]]
                                                         : 32'd0;
        if (!req_err && (a_opcode != OP_GET)) begin
          for (int b = 0; b < 4; b++)
            if (a_mask[b])
              mem[a_address[7:2]][b*8 +: 8] <= a_data[b*8 +: 8];
        end
        if (req_err)
          irq <= 1'b1;                                // sticky error interrupt
      end
    end
  end

  // a_param is reserved in TL-UL (must be tied 0 by the master); it is
  // sampled here for interface completeness but carries no function.

endmodule
