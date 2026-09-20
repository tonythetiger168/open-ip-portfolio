// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Toggle Mode NAND protocol IP -- NAND flash target (educational slice)
// Implementation scope (documented simplified subset of ONFI/toggle NAND):
//   - 8-bit async command/address/data interface: ce_n/cle/ale/we_n/re_n,
//     dq[7:0] tri-state, rb_n ready/busy open-drain style output.
//     dqs echoes the re_n strobe during data output (toggle-mode flavour;
//     single-ended legacy timing is used for the transfers themselves).
//   - Command latch on rising edge of we_n while ce_n=0 & cle=1;
//     address latch while ale=1; data-in latch while cle=0 & ale=0.
//   - Command set:
//       0x90 + 1 addr byte        : Read ID, 5-byte ID on re_n strobes
//       0x00 + 5 addr + 0x30      : Page Read (col2+row3 address cycles,
//                                   col[5:0] = byte, row[3:0] = page)
//       0x80 + 5 addr + data + 0x10: Page Program (1->0 semantics)
//       0x60 + 3 addr + 0xD0      : Block Erase (4 pages per block)
//       0x70                      : Read Status (bit6 ready, bit0 fail)
//       0xFF                      : Reset (aborts anything, clears irq)
//   - Array model: 16 pages x 64 bytes; block = 4 pages. Block 3
//     (pages 12..15) is protected: program/erase set status fail bit.
//   - rb_n busy timing (clk cycles): read 25, program 200, erase 1000.
//   - Illegal command / out-of-sequence command -> ignored + sticky irq
//     (cleared by 0xFF reset or rst_n).
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module Toggle_Mode_NAND_top #(
  parameter int DW = 32,                // framework data width (kept)
  parameter int AW = 32,                // framework address width (kept)
  parameter int T_R     = 25,           // page-read busy cycles
  parameter int T_PROG  = 200,          // page-program busy cycles
  parameter int T_ERASE = 1000,         // block-erase busy cycles
  parameter int T_RST   = 5             // reset busy cycles
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       ce_n,              // chip enable
  input  logic       cle,               // command latch enable
  input  logic       ale,               // address latch enable
  input  logic       we_n,              // write strobe (latch on rise)
  input  logic       re_n,              // read strobe (data out while low)
  inout  wire [7:0]  dq,                // tri-state data bus
  inout  wire        dqs,               // data strobe echo (educational)
  output logic       rb_n,              // ready(1)/busy(0)
  output logic       irq                // sticky protocol-error flag
);

  localparam logic [7:0] CMD_READ_ID   = 8'h90;
  localparam logic [7:0] CMD_READ      = 8'h00;
  localparam logic [7:0] CMD_READ_END  = 8'h30;
  localparam logic [7:0] CMD_PROG      = 8'h80;
  localparam logic [7:0] CMD_PROG_END  = 8'h10;
  localparam logic [7:0] CMD_ERASE     = 8'h60;
  localparam logic [7:0] CMD_ERASE_END = 8'hD0;
  localparam logic [7:0] CMD_STATUS    = 8'h70;
  localparam logic [7:0] CMD_RESET     = 8'hFF;

  // 5-byte Read ID (vendor 2C, educational device code)
  localparam logic [39:0] DEV_ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};

  typedef enum logic [3:0] {
    ST_CMD,       // idle, awaiting command byte
    ST_RID_A,     // Read ID: awaiting 1 address byte
    ST_RID_OUT,   // Read ID: data output
    ST_ADDR,      // read/program: latching 5 address bytes
    ST_WAIT30,    // read: awaiting 0x30 confirm
    ST_DIN,       // program: latching data bytes
    ST_EADDR,     // erase: latching 3 address bytes
    ST_WAITD0,    // erase: awaiting 0xD0 confirm
    ST_BUSY,      // rb_n low, operation in flight
    ST_STOUT      // status output
  } state_t;

  typedef enum logic [1:0] {OP_RD, OP_PROG, OP_ERASE, OP_RST} op_t;

  state_t state;
  op_t    busy_op;

  // ------------------------------------------------------------------
  // storage: 16 pages x 64 bytes + page buffer
  // ------------------------------------------------------------------
  (* ram_style = "block" *) logic [7:0] mem  [0:1023];
  logic [7:0] pbuf [0:63];

  // ------------------------------------------------------------------
  // input synchronizers + strobe edge detect (clk oversamples the bus)
  // ------------------------------------------------------------------
  logic [2:0] we_s, re_s;
  logic [1:0] ce_s, cle_s, ale_s;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      we_s  <= 3'b111;
      re_s  <= 3'b111;
      ce_s  <= 2'b11;
      cle_s <= 2'b00;
      ale_s <= 2'b00;
    end else begin
      we_s  <= {we_s[1:0],  we_n};
      re_s  <= {re_s[1:0],  re_n};
      ce_s  <= {ce_s[0],    ce_n};
      cle_s <= {cle_s[0],   cle};
      ale_s <= {ale_s[0],   ale};
    end
  end

  wire we_rise = (we_s[2:1] == 2'b01) && !ce_s[1];
  wire re_rise = (re_s[2:1] == 2'b01) && !ce_s[1];

  wire latch_cmd  = we_rise &&  cle_s[1];
  wire latch_addr = we_rise && !cle_s[1] &&  ale_s[1];
  wire latch_data = we_rise && !cle_s[1] && !ale_s[1];
  wire [7:0] dq_in = dq;

  // ------------------------------------------------------------------
  // datapath registers
  // ------------------------------------------------------------------
  logic [9:0]  busy_cnt;
  logic [2:0]  addr_cnt;          // address-cycle counter
  logic [5:0]  col_q;             // column address (byte in page)
  logic [3:0]  page_q;            // row address (page)
  logic [5:0]  ptr;               // output / input pointer
  logic        rd_mode;           // ST_ADDR belongs to read (vs program)
  logic        fail;              // status fail bit
  logic [1:0]  blk_q;             // erase block

  wire protected_op = (busy_op == OP_PROG) ? (page_q[3:2] == 2'd3)
                                           : (blk_q == 2'd3);

  wire [7:0] status_byte = {1'b0, rb_n, 5'b00000, fail};

  // ------------------------------------------------------------------
  // dq / dqs pads: drive only during data-output states while re_n low
  // ------------------------------------------------------------------
  wire out_mode = (state == ST_RID_OUT) || (state == ST_STOUT);
  wire rd_out   = (state == ST_BUSY) && (busy_op == OP_RD) &&
                  (busy_cnt == 10'd0); // read data phase after tR
  wire drive_en = (out_mode || rd_out) && !ce_s[1] && !re_s[1];

  wire [7:0] id_byte = (ptr == 6'd0) ? DEV_ID[39:32] :
                       (ptr == 6'd1) ? DEV_ID[31:24] :
                       (ptr == 6'd2) ? DEV_ID[23:16] :
                       (ptr == 6'd3) ? DEV_ID[15:8]  : DEV_ID[7:0];

  wire [7:0] out_byte = (state == ST_RID_OUT) ? id_byte :
                        (state == ST_STOUT)   ? status_byte :
                                                pbuf[ptr];

  assign dq  = drive_en ? out_byte : 8'hzz;
  assign dqs = drive_en ? re_s[1]  : 1'bz;

  // ------------------------------------------------------------------
  // main FSM
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_CMD;
      busy_op  <= OP_RST;
      busy_cnt <= 10'd0;
      addr_cnt <= 3'd0;
      col_q    <= 6'd0;
      page_q   <= 4'd0;
      blk_q    <= 2'd0;
      ptr      <= 6'd0;
      rd_mode  <= 1'b0;
      fail     <= 1'b0;
      rb_n     <= 1'b1;
      irq      <= 1'b0;
      for (int i = 0; i < 1024; i++)      // array powers up erased
        mem[i] <= 8'hFF;
    end else begin
      // -------- output pointer advance on re_n rising edge ---------
      if (re_rise) begin
        if (state == ST_RID_OUT)
          ptr <= (ptr == 6'd4) ? 6'd0 : ptr + 6'd1;   // 5-byte ID cycle
        else if (rd_out)
          ptr <= ptr + 6'd1;                          // wraps at 64
      end

      case (state)
        // ----------------------------------------------------------
        ST_CMD: begin
          rb_n <= 1'b1;
          if (latch_cmd) begin
            case (dq_in)
              CMD_READ_ID: begin state <= ST_RID_A;  end
              CMD_READ:    begin state <= ST_ADDR; rd_mode <= 1'b1;
                                 addr_cnt <= 3'd0;   end
              CMD_PROG:    begin state <= ST_ADDR; rd_mode <= 1'b0;
                                 addr_cnt <= 3'd0; fail <= 1'b0;
                                 for (int i = 0; i < 64; i++)
                                   pbuf[i] <= 8'hFF; end
              CMD_ERASE:   begin state <= ST_EADDR; addr_cnt <= 3'd0;
                                 fail <= 1'b0;       end
              CMD_STATUS:  begin state <= ST_STOUT;  end
              CMD_RESET:   begin state <= ST_BUSY; busy_op <= OP_RST;
                                 busy_cnt <= T_RST[9:0] - 10'd1;
                                 rb_n <= 1'b0; irq <= 1'b0; fail <= 1'b0; end
              default:     begin irq <= 1'b1; end   // unknown command
            endcase
          end
        end
        // ----------------------------------------------------------
        ST_RID_A: begin
          if (latch_addr) begin
            state <= ST_RID_OUT;
            ptr   <= 6'd0;
          end else if (latch_cmd) begin
            if (dq_in == CMD_RESET) begin
              state <= ST_BUSY; busy_op <= OP_RST;
              busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
              irq <= 1'b0; fail <= 1'b0;
            end else begin
              irq   <= 1'b1;                        // expected addr cycle
              state <= ST_CMD;
            end
          end
        end
        // ----------------------------------------------------------
        ST_RID_OUT, ST_STOUT: begin
          if (latch_cmd) begin                      // any new command
            if (dq_in == CMD_RESET) begin
              state <= ST_BUSY; busy_op <= OP_RST;
              busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
              irq <= 1'b0; fail <= 1'b0;
            end else begin
              state <= ST_CMD;                      // re-enter via ST_CMD
              if (dq_in == CMD_READ_ID)      state <= ST_RID_A;
              else if (dq_in == CMD_READ)    begin state <= ST_ADDR;
                                                   rd_mode <= 1'b1;
                                                   addr_cnt <= 3'd0; end
              else if (dq_in == CMD_PROG)    begin state <= ST_ADDR;
                                                   rd_mode <= 1'b0;
                                                   addr_cnt <= 3'd0;
                                                   fail <= 1'b0;
                                                   for (int i = 0; i < 64; i++)
                                                     pbuf[i] <= 8'hFF; end
              else if (dq_in == CMD_ERASE)   begin state <= ST_EADDR;
                                                   addr_cnt <= 3'd0;
                                                   fail <= 1'b0; end
              else if (dq_in == CMD_STATUS)  state <= ST_STOUT;
              else irq <= 1'b1;
            end
          end
        end
        // ----------------------------------------------------------
        ST_ADDR: begin                              // 5 address cycles
          if (latch_addr) begin
            case (addr_cnt)
              3'd0: col_q  <= dq_in[5:0];           // col low
              3'd2: page_q <= dq_in[3:0];           // row low
              default: ;                            // col hi / row hi unused
            endcase
            if (addr_cnt == 3'd4) begin
              addr_cnt <= 3'd0;
              if (rd_mode) state <= ST_WAIT30;
              else begin
                state <= ST_DIN;
                ptr   <= col_q;         // col latched at address cycle 0
              end
            end else begin
              addr_cnt <= addr_cnt + 3'd1;
            end
          end else if (latch_cmd && (dq_in != CMD_RESET)) begin
            irq   <= 1'b1;                          // aborted by command
            state <= ST_CMD;
          end else if (latch_cmd) begin
            state <= ST_BUSY; busy_op <= OP_RST;
            busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
            irq <= 1'b0; fail <= 1'b0;
          end
        end
        // ----------------------------------------------------------
        ST_WAIT30: begin
          if (latch_cmd) begin
            if (dq_in == CMD_READ_END) begin
              state    <= ST_BUSY;
              busy_op  <= OP_RD;
              busy_cnt <= T_R[9:0] - 10'd1;
              rb_n     <= 1'b0;
              ptr      <= col_q;
              for (int i = 0; i < 64; i++)          // page -> page buffer
                pbuf[i] <= mem[{page_q, i[5:0]}];
            end else if (dq_in == CMD_RESET) begin
              state <= ST_BUSY; busy_op <= OP_RST;
              busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
              irq <= 1'b0; fail <= 1'b0;
            end else begin
              irq   <= 1'b1;                        // 0x30 expected
              state <= ST_CMD;
            end
          end
        end
        // ----------------------------------------------------------
        ST_DIN: begin
          if (latch_data) begin
            pbuf[ptr] <= dq_in;
            ptr       <= ptr + 6'd1;                // wraps at page end
          end else if (latch_cmd) begin
            if (dq_in == CMD_PROG_END) begin
              state    <= ST_BUSY;
              busy_op  <= OP_PROG;
              busy_cnt <= T_PROG[9:0] - 10'd1;
              rb_n     <= 1'b0;
            end else if (dq_in == CMD_RESET) begin
              state <= ST_BUSY; busy_op <= OP_RST;
              busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
              irq <= 1'b0; fail <= 1'b0;
            end else begin
              irq   <= 1'b1;                        // 0x10 expected
              state <= ST_CMD;
            end
          end
        end
        // ----------------------------------------------------------
        ST_EADDR: begin                             // 3 row address cycles
          if (latch_addr) begin
            if (addr_cnt == 3'd0) begin
              page_q <= dq_in[3:0];
              blk_q  <= dq_in[3:2];
            end
            if (addr_cnt == 3'd2) begin
              addr_cnt <= 3'd0;
              state    <= ST_WAITD0;
            end else begin
              addr_cnt <= addr_cnt + 3'd1;
            end
          end else if (latch_cmd && (dq_in != CMD_RESET)) begin
            irq   <= 1'b1;
            state <= ST_CMD;
          end else if (latch_cmd) begin
            state <= ST_BUSY; busy_op <= OP_RST;
            busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
            irq <= 1'b0; fail <= 1'b0;
          end
        end
        // ----------------------------------------------------------
        ST_WAITD0: begin
          if (latch_cmd) begin
            if (dq_in == CMD_ERASE_END) begin
              state    <= ST_BUSY;
              busy_op  <= OP_ERASE;
              busy_cnt <= T_ERASE[9:0] - 10'd1;
              rb_n     <= 1'b0;
            end else if (dq_in == CMD_RESET) begin
              state <= ST_BUSY; busy_op <= OP_RST;
              busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
              irq <= 1'b0; fail <= 1'b0;
            end else begin
              irq   <= 1'b1;                        // 0xD0 expected
              state <= ST_CMD;
            end
          end
        end
        // ----------------------------------------------------------
        ST_BUSY: begin
          rb_n <= 1'b0;
          if (busy_cnt != 10'd0) begin
            busy_cnt <= busy_cnt - 10'd1;
          end else begin
            rb_n <= 1'b1;
            case (busy_op)
              OP_RD: begin
                // stay in read-data-output phase until a new command;
                // modelled by returning to ST_CMD with ptr kept: the
                // TB issues all re_n strobes while rd_out is active.
                state <= ST_BUSY;                   // rd_out handles data
                busy_op <= OP_RD;
              end
              OP_PROG: begin
                if (protected_op) begin
                  fail <= 1'b1;                     // array untouched
                end else begin
                  for (int i = 0; i < 64; i++)      // 1->0 program only
                    mem[{page_q, i[5:0]}] <= mem[{page_q, i[5:0]}] & pbuf[i];
                end
                state <= ST_CMD;
              end
              OP_ERASE: begin
                if (protected_op) begin
                  fail <= 1'b1;
                end else begin
                  for (int i = 0; i < 256; i++)
                    mem[{blk_q, i[7:0]}] <= 8'hFF;
                end
                state <= ST_CMD;
              end
              default: state <= ST_CMD;             // OP_RST
            endcase
          end
        end
        default: state <= ST_CMD;
      endcase

      // -------- read data phase exit: a new command ends rd_out ----
      if (rd_out && latch_cmd) begin
        state <= ST_CMD;
        if (dq_in == CMD_RESET) begin
          state <= ST_BUSY; busy_op <= OP_RST;
          busy_cnt <= T_RST[9:0] - 10'd1; rb_n <= 1'b0;
          irq <= 1'b0; fail <= 1'b0;
        end else if (dq_in == CMD_READ_ID)      state <= ST_RID_A;
        else if (dq_in == CMD_READ)    begin state <= ST_ADDR;
                                             rd_mode <= 1'b1;
                                             addr_cnt <= 3'd0; end
        else if (dq_in == CMD_PROG)    begin state <= ST_ADDR;
                                             rd_mode <= 1'b0;
                                             addr_cnt <= 3'd0;
                                             fail <= 1'b0;
                                             for (int i = 0; i < 64; i++)
                                               pbuf[i] <= 8'hFF; end
        else if (dq_in == CMD_ERASE)   begin state <= ST_EADDR;
                                             addr_cnt <= 3'd0;
                                             fail <= 1'b0; end
        else if (dq_in == CMD_STATUS)  state <= ST_STOUT;
        else irq <= 1'b1;
      end
    end
  end

endmodule
