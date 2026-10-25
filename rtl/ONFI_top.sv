// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ONFI_top v2.0: ONFI NAND flash host controller for one target on the
// asynchronous (SDR) data interface
// ----------------------------------------------------------------------------
//  - Host side: a command (cmd_valid / cmd_ready; cmd_op, row address,
//    column address, length), a write byte stream (wr_*) for Program Page
//    and Set Features, a read byte stream (rd_*) for Read ID, Read Page and
//    Get Features. done pulses when a command is over; status holds the
//    last status byte read; ev_fail pulses with done when a Program or
//    Erase reports FAIL (status bit 0); ev_timeout pulses with done when
//    R/B# stayed low for TBUSY clocks (the command is abandoned).
//  - Commands (cmd_op): 0 Reset FFh; 1 Read ID 90h (address = col[7:0],
//    cmd_len bytes); 2 Read Status 70h (into status); 3 Read Page 00h, two
//    column and three row cycles, 30h, wait for ready, cmd_len bytes;
//    4 Program Page 80h, five address cycles, cmd_len bytes, 10h, wait for
//    ready, then Read Status; 5 Erase Block 60h, three row cycles, D0h,
//    wait for ready, then Read Status; 6 Get Features EEh (feature address
//    = col[7:0]), wait for ready, 4 bytes; 7 Set Features EFh, 4 bytes,
//    wait for ready.
//  - Pins: ce_n is low from the first cycle of a command to its end. A
//    command, address or data-in cycle sets CLE / ALE / DQ, holds WE# low
//    for TP clocks and high for TP clocks (the target latches on the rising
//    edge); a data-out cycle holds RE# low for TP clocks and takes DQ on
//    the clock RE# rises, then RE# high for TP clocks. dq_oe drives DQ for
//    write cycles only. Between phases the controller waits tWB (TWB clocks
//    after the last command cycle, before R/B# is looked at), tWHR (TWHR
//    clocks before the first data-out cycle after a command or address),
//    tADL (TADL clocks from the last address cycle to data in) and tRR (TRR
//    clocks from ready to data out). rb_n goes through a two-flop
//    synchronizer.
//  - The data streams can stall the bus: a data-in cycle starts when a
//    byte is offered, a data-out cycle when the read register is empty.
//  Not implemented: the NV-DDR interfaces and their timing modes, more
//  than one target or LUN, cache and multi-plane operations, Change Read
//  Column, Read Parameter Page, Read Status Enhanced, ECC, write protect.
//  Opcodes and cycle order follow ONFI 4.2 as we read them; they have not
//  been checked against a device.
// ============================================================================
module ONFI_top #(
  parameter int TP    = 2,              // WE# / RE# low and high time, clocks
  parameter int TWB   = 6,              // tWB, clocks
  parameter int TWHR  = 8,              // tWHR, clocks
  parameter int TADL  = 10,             // tADL, clocks
  parameter int TRR   = 3,              // tRR, clocks
  parameter int TBUSY = 2048,           // R/B# low timeout, clocks (power of 2, above the waits)
  parameter int LW    = 12              // transfer length width
)(
  input  logic          clk,
  input  logic          rst_n,
  // host
  input  logic          cmd_valid,
  output logic          cmd_ready,
  input  logic [2:0]    cmd_op,
  input  logic [23:0]   cmd_row,
  input  logic [15:0]   cmd_col,
  input  logic [LW-1:0] cmd_len,
  input  logic          wr_valid,
  output logic          wr_ready,
  input  logic [7:0]    wr_data,
  output logic          rd_valid,
  input  logic          rd_ready,
  output logic [7:0]    rd_data,
  output logic          done,
  output logic [7:0]    status,
  output logic          ev_fail,
  output logic          ev_timeout,
  // NAND target
  output logic          ce_n,
  output logic          cle,
  output logic          ale,
  output logic          we_n,
  output logic          re_n,
  output logic [7:0]    dq_o,
  output logic          dq_oe,
  input  logic [7:0]    dq_i,
  input  logic          rb_n
);
  localparam int PW = $clog2(2 * TP);
  localparam int TW = $clog2(TBUSY);

  // micro-operations: {kind, argument}
  localparam logic [2:0] U_CMD = 3'd0, U_ADDR = 3'd1, U_WAIT = 3'd2, U_BUSY = 3'd3,
                         U_DIN = 3'd4, U_DOUT = 3'd5, U_STAT = 3'd6, U_END = 3'd7;
  function logic [10:0] uop(input logic [2:0] op, input logic [3:0] s);
    uop = {U_END, 8'h00};
    case (op)
      3'd0:                               // Reset
        case (s)
          4'd0: uop = {U_CMD, 8'hFF};
          4'd1: uop = {U_WAIT, 8'd0};
          4'd2: uop = {U_BUSY, 8'd0};
          default: ;
        endcase
      3'd1:                               // Read ID
        case (s)
          4'd0: uop = {U_CMD, 8'h90};
          4'd1: uop = {U_ADDR, 8'd0};
          4'd2: uop = {U_WAIT, 8'd1};
          4'd3: uop = {U_DOUT, 8'd0};
          default: ;
        endcase
      3'd2:                               // Read Status
        case (s)
          4'd0: uop = {U_CMD, 8'h70};
          4'd1: uop = {U_WAIT, 8'd1};
          4'd2: uop = {U_STAT, 8'd0};
          default: ;
        endcase
      3'd3:                               // Read Page
        case (s)
          4'd0: uop = {U_CMD, 8'h00};
          4'd1, 4'd2, 4'd3, 4'd4, 4'd5: uop = {U_ADDR, 4'd0, s - 4'd1};
          4'd6: uop = {U_CMD, 8'h30};
          4'd7: uop = {U_WAIT, 8'd0};
          4'd8: uop = {U_BUSY, 8'd0};
          4'd9: uop = {U_WAIT, 8'd3};
          4'd10: uop = {U_DOUT, 8'd0};
          default: ;
        endcase
      3'd4:                               // Program Page
        case (s)
          4'd0: uop = {U_CMD, 8'h80};
          4'd1, 4'd2, 4'd3, 4'd4, 4'd5: uop = {U_ADDR, 4'd0, s - 4'd1};
          4'd6: uop = {U_WAIT, 8'd2};
          4'd7: uop = {U_DIN, 8'd0};
          4'd8: uop = {U_CMD, 8'h10};
          4'd9: uop = {U_WAIT, 8'd0};
          4'd10: uop = {U_BUSY, 8'd0};
          4'd11: uop = {U_CMD, 8'h70};
          4'd12: uop = {U_WAIT, 8'd1};
          4'd13: uop = {U_STAT, 8'd0};
          default: ;
        endcase
      3'd5:                               // Erase Block
        case (s)
          4'd0: uop = {U_CMD, 8'h60};
          4'd1, 4'd2, 4'd3: uop = {U_ADDR, 4'd0, s + 4'd1};
          4'd4: uop = {U_CMD, 8'hD0};
          4'd5: uop = {U_WAIT, 8'd0};
          4'd6: uop = {U_BUSY, 8'd0};
          4'd7: uop = {U_CMD, 8'h70};
          4'd8: uop = {U_WAIT, 8'd1};
          4'd9: uop = {U_STAT, 8'd0};
          default: ;
        endcase
      3'd6:                               // Get Features
        case (s)
          4'd0: uop = {U_CMD, 8'hEE};
          4'd1: uop = {U_ADDR, 8'd0};
          4'd2: uop = {U_WAIT, 8'd0};
          4'd3: uop = {U_BUSY, 8'd0};
          4'd4: uop = {U_WAIT, 8'd3};
          4'd5: uop = {U_DOUT, 8'd0};
          default: ;
        endcase
      default:                            // Set Features
        case (s)
          4'd0: uop = {U_CMD, 8'hEF};
          4'd1: uop = {U_ADDR, 8'd0};
          4'd2: uop = {U_WAIT, 8'd2};
          4'd3: uop = {U_DIN, 8'd0};
          4'd4: uop = {U_WAIT, 8'd0};
          4'd5: uop = {U_BUSY, 8'd0};
          default: ;
        endcase
    endcase
  endfunction

  typedef enum logic [2:0] {S_IDLE, S_STEP, S_WE, S_RE, S_WAIT, S_BUSY} st_t;
  st_t st;

  logic [2:0]    op;
  logic [23:0]   row;
  logic [15:0]   col;
  logic [LW-1:0] len, bi;               // bytes to move, moved
  logic [3:0]    step;
  logic [PW-1:0] pc;                    // clock within a WE# / RE# cycle
  logic [TW-1:0] tc;                    // wait / busy clocks
  logic [1:0]    rb_s;
  logic          to_stat;               // the data-out cycle reads the status

  wire  [10:0]   u = uop(op, step);
  wire  [2:0]    uk = u[10:8];
  wire  [LW-1:0] n = op[2:1] == 2'b11 ? LW'(4) : len;   // Get / Set Features: 4 bytes
  assign cmd_ready = st == S_IDLE;
  assign wr_ready = st == S_STEP && uk == U_DIN && bi != n;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st <= S_IDLE; op <= '0; row <= '0; col <= '0; len <= '0; bi <= '0; step <= '0; pc <= '0; tc <= '0;
      rb_s <= 2'b00; to_stat <= 1'b0;
      rd_valid <= 1'b0; rd_data <= '0; done <= 1'b0; status <= '0; ev_fail <= 1'b0; ev_timeout <= 1'b0;
      ce_n <= 1'b1; cle <= 1'b0; ale <= 1'b0; we_n <= 1'b1; re_n <= 1'b1; dq_o <= '0; dq_oe <= 1'b0;
    end else begin
      rb_s <= {rb_s[0], rb_n};
      done <= 1'b0; ev_fail <= 1'b0; ev_timeout <= 1'b0;
      if (rd_ready) rd_valid <= 1'b0;
      case (st)
        S_IDLE:
          if (cmd_valid) begin
            op <= cmd_op; row <= cmd_row; col <= cmd_col; len <= cmd_len;
            step <= '0; bi <= '0; ce_n <= 1'b0; st <= S_STEP;
          end
        S_STEP:
          case (uk)
            U_CMD, U_ADDR: begin
              cle <= uk == U_CMD; ale <= uk == U_ADDR; we_n <= 1'b0; dq_oe <= 1'b1; pc <= '0; st <= S_WE;
              dq_o <= uk == U_CMD ? u[7:0] :
                      u[2:0] == 3'd0 ? col[7:0] : u[2:0] == 3'd1 ? col[15:8] : u[2:0] == 3'd2 ? row[7:0] :
                      u[2:0] == 3'd3 ? row[15:8] : row[23:16];
            end
            U_WAIT: begin
              tc <= TW'(u[1:0] == 2'd0 ? TWB - 1 : u[1:0] == 2'd1 ? TWHR - 1 : u[1:0] == 2'd2 ? TADL - 1 : TRR - 1);
              st <= S_WAIT;
            end
            U_BUSY: begin tc <= '0; st <= S_BUSY; end
            U_DIN:
              if (bi == n) step <= step + 1'b1;
              else if (wr_valid) begin
                dq_o <= wr_data; we_n <= 1'b0; dq_oe <= 1'b1; pc <= '0; bi <= bi + 1'b1; st <= S_WE;
              end
            U_DOUT:
              if (bi == n) step <= step + 1'b1;
              else if (!rd_valid) begin re_n <= 1'b0; dq_oe <= 1'b0; pc <= '0; to_stat <= 1'b0; st <= S_RE; end
            U_STAT: begin re_n <= 1'b0; dq_oe <= 1'b0; pc <= '0; to_stat <= 1'b1; st <= S_RE; end
            default: begin                  // U_END
              st <= S_IDLE; ce_n <= 1'b1; dq_oe <= 1'b0; done <= 1'b1;
              ev_fail <= status[0] && (op == 3'd4 || op == 3'd5);
            end
          endcase
        S_WE: begin
          pc <= pc + 1'b1;
          if (pc == PW'(TP - 1)) we_n <= 1'b1;
          if (pc == PW'(2 * TP - 1)) begin
            cle <= 1'b0; ale <= 1'b0; st <= S_STEP;
            if (uk != U_DIN) step <= step + 1'b1;
          end
        end
        S_RE: begin
          pc <= pc + 1'b1;
          if (pc == PW'(TP - 1)) begin
            re_n <= 1'b1;
            if (to_stat) status <= dq_i;
            else begin
              rd_valid <= 1'b1; rd_data <= dq_i; bi <= bi + 1'b1;
            end
          end
          if (pc == PW'(2 * TP - 1)) begin
            st <= S_STEP;
            if (to_stat) step <= step + 1'b1;
          end
        end
        S_WAIT:
          if (tc == '0) begin step <= step + 1'b1; st <= S_STEP; end
          else tc <= tc - 1'b1;
        default:                            // S_BUSY
          if (rb_s[1]) begin step <= step + 1'b1; st <= S_STEP; end
          else if (tc == TW'(TBUSY - 1)) begin
            st <= S_IDLE; ce_n <= 1'b1; dq_oe <= 1'b0; done <= 1'b1; ev_timeout <= 1'b1;
          end else tc <= tc + 1'b1;
      endcase
    end
endmodule
