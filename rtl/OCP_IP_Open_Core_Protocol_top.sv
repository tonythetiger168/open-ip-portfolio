// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// ============================================================================
// OCP-IP master -- real protocol IP design
// Scope : OCP-IP master (initiator) side.  MCmd encoding : 0=IDLE, 1=WR,
//         2=RD, 5=WRNP; WR=1 is the posted write (no
//         response), WRNP=5 the non-posted write (answered).  Bursts : INCR
//         (MBurstSeq=0), MBurstLength 1..8, address given once, write data
//         beats handshaken per-beat with SCmdAccept.  SCmdAccept backpressure
//         is obeyed (request held stable); 64 clk without SCmdAccept aborts
//         the transaction -> resp_err + sticky irq.  SResp : 0=NULL,
//         1=DVA, 2=FAIL, 3=ERR; FAIL or ERR -> resp_err on that beat +
//         sticky irq, and a read burst still consumes its remaining beats.
//         irq is cleared only by reset.  CPU-side transaction port:
//         req_valid/req_ready + req_rw/req_posted/req_addr/req_len/req_wdata
//         (write-burst data words are streamed after the descriptor while
//         req_ready is high) -> resp_valid/resp_rdata/resp_err.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module OCP_IP_Open_Core_Protocol_top #(
  parameter int DW = 32,   // data width
  parameter int AW = 32    // address width
)(
  input  logic          clk,
  input  logic          rst_n,
  // CPU-side transaction port
  input  logic          req_valid,
  output logic          req_ready,
  input  logic          req_rw,      // 1 = write, 0 = read
  input  logic          req_posted,  // 1 = posted write (MCmd WR, no response)
  input  logic [AW-1:0] req_addr,
  input  logic [4:0]    req_len,     // burst length 1..8 (0 -> 1, >8 clamped)
  input  logic [DW-1:0] req_wdata,
  output logic          resp_valid,
  output logic [DW-1:0] resp_rdata,
  output logic          resp_err,
  // OCP master interface
  output logic [2:0]    MCmd,
  output logic [AW-1:0] MAddr,
  output logic [DW-1:0] MData,
  output logic [3:0]    MByteEn,
  output logic [4:0]    MBurstLength,
  output logic [2:0]    MBurstSeq,
  input  logic          SCmdAccept,
  input  logic [1:0]    SResp,
  input  logic [DW-1:0] SData,
  input  logic          SRespLast,
  output logic          irq
);

  localparam logic [2:0] CMD_IDLE = 3'd0;
  localparam logic [2:0] CMD_WR   = 3'd1;
  localparam logic [2:0] CMD_RD   = 3'd2;
  localparam logic [2:0] CMD_WRNP = 3'd5;

  localparam int TIMEOUT = 64;   // clk cycles without SCmdAccept

  typedef enum logic [2:0] {O_IDLE, O_WCOL, O_ISSUE, O_RDATA, O_WRESP, O_DONE}
    ocp_t;
  ocp_t state;

  // descriptor registers
  logic        rw_q, posted_q;
  logic [31:0] addr_q;
  logic [3:0]  len_q;     // 1..8
  // write data buffer (max burst 8)
  logic [31:0] wbuf [0:7];
  logic [3:0]  wcnt;      // words collected
  logic [2:0]  beat;      // write beat being issued
  logic [3:0]  rcnt;      // read response beats seen
  logic [6:0]  to_cnt;    // SCmdAccept timeout counter
  logic        done_err;  // error flag for O_DONE pulse

  // burst length clamp : 0 -> 1, >8 -> 8 (+ irq)
  wire       len_over  = (req_len > 5'd8);
  wire [3:0] req_len_c = (req_len == 5'd0) ? 4'd1 :
                         len_over ? 4'd8 : req_len[3:0];

  assign req_ready = (state == O_IDLE) || (state == O_WCOL);

  // OCP request channel (held stable while waiting for SCmdAccept)
  assign MCmd         = (state == O_ISSUE) ?
                        (rw_q ? (posted_q ? CMD_WR : CMD_WRNP) : CMD_RD)
                        : CMD_IDLE;
  assign MAddr        = addr_q;
  assign MData        = wbuf[beat];
  assign MByteEn      = 4'hF;
  assign MBurstLength = {1'b0, len_q};
  assign MBurstSeq    = 3'b000;   // INCR

  // CPU response channel
  wire rsp_beat = ((state == O_RDATA) || (state == O_WRESP)) && (SResp != 2'd0);
  wire rsp_bad  = SResp[1];                        // FAIL (2) or ERR (3)
  wire rd_last  = SRespLast || (rcnt == len_q - 4'd1);
  assign resp_valid = rsp_beat || (state == O_DONE);
  assign resp_rdata = (state == O_RDATA) ? SData : {DW{1'b0}};
  assign resp_err   = (rsp_beat && rsp_bad) ||
                      ((state == O_DONE) && done_err);

  // ------------------------------------------------------------------
  // sequential
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= O_IDLE;
      rw_q     <= 1'b0;
      posted_q <= 1'b0;
      addr_q   <= 32'd0;
      len_q    <= 4'd1;
      wcnt     <= 4'd0;
      beat     <= 3'd0;
      rcnt     <= 4'd0;
      to_cnt   <= 7'd0;
      done_err <= 1'b0;
      irq      <= 1'b0;
    end else begin
      case (state)
        // ------------------------------------------- descriptor accept
        O_IDLE : if (req_valid) begin
          rw_q     <= req_rw;
          posted_q <= req_posted;
          addr_q   <= req_addr;
          len_q    <= req_len_c;
          beat     <= 3'd0;
          rcnt     <= 4'd0;
          to_cnt   <= 7'd0;
          if (len_over) irq <= 1'b1;               // illegal burst length
          if (req_rw) begin
            wbuf[0] <= req_wdata;                  // first word with descriptor
            wcnt    <= 4'd1;
            state   <= (req_len_c > 4'd1) ? O_WCOL : O_ISSUE;
          end else begin
            state <= O_ISSUE;
          end
        end

        // ------------------------------ write-burst data word collect
        O_WCOL : if (req_valid) begin
          wbuf[wcnt[2:0]] <= req_wdata;
          if (wcnt == len_q - 4'd1) begin
            state <= O_ISSUE;
          end
          wcnt <= wcnt + 4'd1;
        end

        // ------------------------------------ request / write-beat issue
        O_ISSUE : begin
          if (SCmdAccept) begin
            to_cnt <= 7'd0;
            if (!rw_q) begin
              state <= O_RDATA;                    // read : wait data beats
            end else if ({1'b0, beat} == len_q - 4'd1) begin
              if (posted_q) begin
                done_err <= 1'b0;                  // WRNP : no SResp expected
                state    <= O_DONE;
              end else begin
                state <= O_WRESP;                  // WR : wait completion
              end
            end else begin
              beat <= beat + 3'd1;                 // next write data beat
            end
          end else begin
            if (to_cnt == 7'(TIMEOUT-1)) begin         // 64 clk without accept
              done_err <= 1'b1;
              irq      <= 1'b1;
              state    <= O_DONE;
            end
            to_cnt <= to_cnt + 7'd1;
          end
        end

        // --------------------------------------------- read data return
        O_RDATA : if (SResp != 2'd0) begin
          if (rsp_bad) irq <= 1'b1;                // error beat : flag, keep
          if (rd_last) state <= O_IDLE;            // draining the burst
          rcnt <= rcnt + 4'd1;
        end

        // ------------------------------------------- write completion
        O_WRESP : if (SResp != 2'd0) begin
          if (rsp_bad) irq <= 1'b1;
          state <= O_IDLE;
        end

        // ------------------------------- local completion / error pulse
        O_DONE : state <= O_IDLE;

        default : state <= O_IDLE;           // unused encodings 6, 7
      endcase
    end
  end

endmodule
