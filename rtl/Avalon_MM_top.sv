// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// ============================================================================
// Avalon-MM slave -- real protocol IP design
// Scope : Avalon-MM slave with waitrequest backpressure (slow window =
//         1 wait state), read & write bursts (burstcount <= 16, INCR),
//         in-order readdatavalid return, byteenable partial-write merge,
//         out-of-range burst truncation (writes dropped / read data cut)
//         + sticky irq, 256x32 regfile.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module Avalon_MM_top #(
  parameter int DW    = 32,   // data width
  parameter int AW    = 32,   // address width
  parameter int DEPTH = 256   // internal register-file depth (words)
)(
  input  logic          clk,
  input  logic          rst_n,
  // Avalon-MM slave interface
  input  logic [AW-1:0] av_address,       // byte address
  input  logic          av_read,
  input  logic          av_write,
  input  logic [DW-1:0] av_writedata,
  input  logic [3:0]    av_byteenable,
  input  logic [7:0]    av_burstcount,
  output logic [DW-1:0] av_readdata,
  output logic          av_readdatavalid,
  output logic          av_waitrequest,
  output logic          irq
);

  // ------------------------------------------------------------------
  // address map
  //   0x000-0x1FF : fast window (no wait state)
  //   0x200-0x3FF : slow window (1 wait state / 1-cycle read bubble)
  //   0x400+      : out of range -> burst truncation + irq
  // ------------------------------------------------------------------
  localparam logic [31:0] VALID_END = 32'h0000_0400;
  localparam logic [31:0] SLOW_START= 32'h0000_0200;

  (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];

  typedef enum logic [1:0] {AV_IDLE, AV_WRB, AV_RDD} avs_t;
  avs_t state;

  logic [31:0] cur_addr;    // running burst address
  logic [8:0]  beats_left;  // remaining beats (after command beat)
  logic        ws_q;        // slow-window wait state elapsed
  logic        rd_gap;      // slow-window read bubble inserted

  function automatic logic in_valid(input logic [31:0] a);
    in_valid = (a < VALID_END);
  endfunction
  function automatic logic in_slow(input logic [31:0] a);
    in_slow = (a >= SLOW_START) && (a < VALID_END);
  endfunction

  // burstcount clamp: legal max is 16; larger values are clamped + irq
  wire [8:0] cmd_beats = (av_burstcount == 8'd0)  ? 9'd1  :
                         (av_burstcount >  8'd16) ? 9'd16 :
                                                    {1'b0, av_burstcount};
  wire cmd_over  = (av_burstcount > 8'd16);
  wire cmd       = av_read | av_write;

  // ------------------------------------------------------------------
  // waitrequest : slow window costs 1 wait state; read-data return and
  // write bursts block new commands
  // ------------------------------------------------------------------
  wire slow_cmd  = (state == AV_IDLE) & cmd      & in_slow(av_address);
  wire slow_beat = (state == AV_WRB)  & av_write & in_slow(cur_addr);

  always_comb begin
    case (state)
      AV_IDLE : av_waitrequest = slow_cmd & ~ws_q;
      AV_WRB  : av_waitrequest = slow_beat & ~ws_q;
      default : av_waitrequest = 1'b1;   // AV_RDD : drain read data first
    endcase
  end

  wire cmd_acc  = (state == AV_IDLE) & cmd & ~av_waitrequest;
  wire beat_acc = (state == AV_WRB) & av_write & ~av_waitrequest;

  // ------------------------------------------------------------------
  // read data channel : in-order, one beat per cycle (bubble on slow)
  // ------------------------------------------------------------------
  wire rd_emit = (state == AV_RDD) & in_valid(cur_addr) &
                 ~(in_slow(cur_addr) & ~rd_gap);
  assign av_readdatavalid = rd_emit;
  assign av_readdata      = mem[cur_addr[9:2]];

  // ------------------------------------------------------------------
  // sequential
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= AV_IDLE;
      cur_addr   <= 32'd0;
      beats_left <= 9'd0;
      ws_q       <= 1'b0;
      rd_gap     <= 1'b0;
      irq        <= 1'b0;
    end else begin
      // slow-window wait-state tracking
      if (state != AV_RDD)
        ws_q <= av_waitrequest & (slow_cmd | slow_beat);
      else
        ws_q <= 1'b0;

      case (state)
        // ------------------------------------------------ command beat
        AV_IDLE : if (cmd_acc) begin
          if (av_read & av_write) irq <= 1'b1;   // illegal simultaneous r/w
          if (cmd_over)           irq <= 1'b1;   // burstcount > 16
          if (av_write) begin
            // first write beat transfers with the command
            if (in_valid(av_address)) begin
              for (int b = 0; b < 4; b++)
                if (av_byteenable[b])
                  mem[av_address[9:2]][b*8 +: 8] <= av_writedata[b*8 +: 8];
            end else irq <= 1'b1;                // out of range : drop
            if (cmd_beats > 9'd1) begin
              cur_addr   <= av_address + 32'd4;
              beats_left <= cmd_beats - 9'd1;
              state      <= AV_WRB;
            end
          end else begin
            // read command : data return starts next cycle
            if (!in_valid(av_address)) begin
              irq <= 1'b1;                       // out of range : no data
            end else begin
              cur_addr   <= av_address;
              beats_left <= cmd_beats;
              rd_gap     <= 1'b0;
              state      <= AV_RDD;
            end
          end
        end

        // ------------------------------------------------ write burst
        AV_WRB : if (beat_acc) begin
          if (in_valid(cur_addr)) begin
            for (int b = 0; b < 4; b++)
              if (av_byteenable[b])
                mem[cur_addr[9:2]][b*8 +: 8] <= av_writedata[b*8 +: 8];
          end else irq <= 1'b1;                  // truncated : drop beat
          cur_addr   <= cur_addr + 32'd4;
          beats_left <= beats_left - 9'd1;
          if (beats_left == 9'd1) state <= AV_IDLE;
        end

        // ------------------------------------------------ read burst
        AV_RDD : begin
          if (!in_valid(cur_addr)) begin
            // out-of-range burst : truncate remaining beats
            irq   <= 1'b1;
            state <= AV_IDLE;
          end else if (in_slow(cur_addr) && !rd_gap) begin
            rd_gap <= 1'b1;                      // 1-cycle bubble
          end else begin
            rd_gap     <= 1'b0;
            cur_addr   <= cur_addr + 32'd4;
            beats_left <= beats_left - 9'd1;
            if (beats_left == 9'd1) state <= AV_IDLE;
          end
        end

        default : state <= AV_IDLE;
      endcase
    end
  end

endmodule
