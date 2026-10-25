// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Toggle Mode NAND protocol IP -- NAND flash target
// Implementation scope (subset of toggle-mode / ONFI NV-DDR style NAND; clk
// oversamples the bus):
//   - Commands and addresses are SDR: latched on the rising edge of we_n
//     while ce_n = 0, with cle = 1 (command) or ale = 1 (address).
//   - Data is DDR on dq[7:0]:
//       input : the host drives dqs; every dqs edge (rising and falling)
//               latches one byte during page-program data input.
//       output: the host toggles re_n; the target drives dq and echoes
//               re_n on dqs. The first byte follows the first re_n falling
//               edge and every further re_n edge presents the next byte;
//               cle or ale high releases dq / dqs at once.
//   - Command set:
//       90h + 1 addr            : Read ID, 5-byte ID
//       00h + 5 addr + 30h      : Page Read (col[5:0] = byte, row[3:0] = page)
//       80h + 5 addr + data + 10h: Page Program (1 -> 0 only)
//       60h + 3 addr + D0h      : Block Erase (4 pages per block)
//       70h                     : Read Status, accepted at any time, also
//                                 while busy: {WP_n=1, RDY, ARDY, 0000, FAIL}
//       00h (no address)        : after a page read, return from status to
//                                 the page data (restarts at the column)
//                                 (FAIL reports the last program / erase;
//                                 a page read clears it)
//       FFh                     : Reset, accepted at any time; aborts the
//                                 operation in flight, clears irq and FAIL
//   - Array: 16 pages x 64 bytes; block = 4 pages. Block 3 (pages 12..15)
//     is protected: program / erase leave it untouched and set FAIL.
//   - rb_n busy time (clk cycles): read T_R, program T_PROG, erase T_ERASE,
//     reset T_RST.
//   - irq (sticky until FFh or rst_n): unknown command, a command out of
//     sequence, an address cycle outside an address phase, or any command
//     but 70h / FFh while busy. The offending command is ignored.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module Toggle_Mode_NAND_top #(
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
  input  logic       re_n,              // read strobe (DDR data out)
  inout  wire [7:0]  dq,                // tri-state data bus
  inout  wire        dqs,               // data strobe (host on input, target on output)
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

  // 5-byte Read ID (vendor 2C, device code)
  localparam logic [39:0] DEV_ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};

  typedef enum logic [2:0] {
    ST_CMD,       // awaiting a command
    ST_RID_A,     // Read ID: awaiting 1 address byte
    ST_ADDR,      // read/program: 5 address bytes
    ST_WAIT30,    // read: awaiting 30h
    ST_DIN,       // program: data input, awaiting 10h
    ST_EADDR,     // erase: 3 address bytes
    ST_WAITD0     // erase: awaiting D0h
  } state_t;
  typedef enum logic [1:0] {O_NONE, O_ID, O_STAT, O_DATA} omode_t;
  typedef enum logic [1:0] {OP_RD, OP_PROG, OP_ERASE, OP_RST} op_t;

  state_t state;
  omode_t omode;
  op_t    op;

  (* ram_style = "block" *) logic [7:0] mem  [0:1023];
  logic [7:0] pbuf [0:63];

  // ------------------------------------------------------------------
  // synchronizers (clk oversamples the bus); dq is delayed to line up
  // with the dqs edge detector
  // ------------------------------------------------------------------
  logic [2:0] we_s, re_s, dqs_s;
  logic [1:0] ce_s, cle_s, ale_s;
  logic [7:0] dq_s0, dq_s1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      we_s  <= 3'b111;
      re_s  <= 3'b111;
      dqs_s <= 3'b000;
      ce_s  <= 2'b11;
      cle_s <= 2'b00;
      ale_s <= 2'b00;
      dq_s0 <= 8'h00;
      dq_s1 <= 8'h00;
    end else begin
      we_s  <= {we_s[1:0],  we_n};
      re_s  <= {re_s[1:0],  re_n};
      dqs_s <= {dqs_s[1:0], dqs};
      ce_s  <= {ce_s[0],    ce_n};
      cle_s <= {cle_s[0],   cle};
      ale_s <= {ale_s[0],   ale};
      dq_s0 <= dq;
      dq_s1 <= dq_s0;
    end
  end

  wire sel        = !ce_s[1];
  wire we_rise    = (we_s[2:1] == 2'b01) && sel;
  wire latch_cmd  = we_rise &&  cle_s[1];
  wire latch_addr = we_rise && !cle_s[1] && ale_s[1];
  wire [7:0] cmd_in = dq_s1;

  // ------------------------------------------------------------------
  // datapath
  // ------------------------------------------------------------------
  logic        busy;
  logic [9:0]  busy_cnt;
  logic [2:0]  addr_cnt;
  logic [5:0]  col_q;             // column address (byte in page)
  logic [3:0]  page_q;            // row address (page)
  logic [5:0]  ptr;               // output / input pointer
  logic        rd_mode;           // ST_ADDR belongs to a read
  logic        fail;
  logic        started;           // first re_n falling edge seen
  logic        rd_avail;          // a page read has completed into pbuf

  // after 00h returned to the data of a completed read, no address has
  // followed yet: the target is idle and takes any command
  wire cmd_idle = (state == ST_CMD) || (state == ST_ADDR && addr_cnt == 3'd0 && rd_avail);
  wire protected_op = (page_q[3:2] == 2'd3);      // block 3
  function automatic logic [7:0] status_byte(input logic b, input logic f);
    status_byte = {1'b1, !b, !b, 4'b0000, f};
  endfunction

  // the output stage lets go as soon as the host starts a command or
  // address cycle (cle / ale act on the drivers directly, unsynchronized)
  wire drive_en = (omode != O_NONE) && started && sel && !cle && !ale;
  wire re_edge  = (re_s[2] != re_s[1]) && sel && (omode != O_NONE);
  wire dqs_edge = (dqs_s[2] != dqs_s[1]) && sel && (state == ST_DIN) && !drive_en;

  wire [7:0] id_byte = (ptr[2:0] == 3'd0) ? DEV_ID[39:32] :
                       (ptr[2:0] == 3'd1) ? DEV_ID[31:24] :
                       (ptr[2:0] == 3'd2) ? DEV_ID[23:16] :
                       (ptr[2:0] == 3'd3) ? DEV_ID[15:8]  : DEV_ID[7:0];
  wire [7:0] out_byte = (omode == O_ID)   ? id_byte :
                        (omode == O_STAT) ? status_byte(busy, fail) : pbuf[ptr];

  assign rb_n = !busy;
  assign dq  = drive_en ? out_byte : 8'hzz;
  assign dqs = drive_en ? re_s[1]  : 1'bz;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_CMD;
      omode    <= O_NONE;
      op       <= OP_RST;
      busy     <= 1'b0;
      busy_cnt <= 10'd0;
      addr_cnt <= 3'd0;
      col_q    <= 6'd0;
      page_q   <= 4'd0;
      ptr      <= 6'd0;
      rd_mode  <= 1'b0;
      fail     <= 1'b0;
      started  <= 1'b0;
      rd_avail <= 1'b0;
      irq      <= 1'b0;
      for (int i = 0; i < 64; i++) pbuf[i] <= 8'hFF;
      for (int i = 0; i < 1024; i++) mem[i] <= 8'hFF;   // array powers up erased
    end else begin
      // ---------------- DDR output strobes ----------------
      if (re_edge) begin
        if (!started) started <= !re_s[1];             // first falling edge
        else if (omode == O_ID)   ptr <= (ptr == 6'd4) ? 6'd0 : ptr + 6'd1;
        else if (omode == O_DATA) ptr <= ptr + 6'd1;   // wraps at 64
      end
      // ---------------- DDR data input ----------------
      if (dqs_edge) begin
        pbuf[ptr] <= dq_s1;
        ptr       <= ptr + 6'd1;                       // wraps at 64
      end

      // ---------------- operation in flight ----------------
      if (busy) begin
        if (busy_cnt != 10'd0) busy_cnt <= busy_cnt - 10'd1;
        else begin
          busy <= 1'b0;
          case (op)
            OP_RD: begin                                // data out, unless polling status
              rd_avail <= 1'b1;
              if (omode != O_STAT) begin omode <= O_DATA; ptr <= col_q; started <= 1'b0; end
            end
            OP_PROG:
              if (protected_op) fail <= 1'b1;            // array untouched
              else for (int i = 0; i < 64; i++)          // 1 -> 0 only
                mem[{page_q, i[5:0]}] <= mem[{page_q, i[5:0]}] & pbuf[i];
            OP_ERASE:
              if (protected_op) fail <= 1'b1;
              else for (int i = 0; i < 256; i++) mem[{page_q[3:2], i[7:0]}] <= 8'hFF;
            default: ;                                  // reset done
          endcase
        end
      end

      // ---------------- commands ----------------
      if (latch_cmd) begin
        if (cmd_in == CMD_RESET) begin
          state <= ST_CMD; omode <= O_NONE; busy <= 1'b1; op <= OP_RST; rd_avail <= 1'b0;
          busy_cnt <= T_RST[9:0] - 10'd1; irq <= 1'b0; fail <= 1'b0;
        end else if (cmd_in == CMD_STATUS) begin
          if (!cmd_idle) irq <= 1'b1;                  // breaks a sequence
          state <= ST_CMD; omode <= O_STAT; started <= 1'b0;
        end else if (busy) begin
          irq <= 1'b1;                                 // only 70h / FFh
        end else begin
          omode <= O_NONE;
          state <= ST_CMD;
          if (cmd_in != CMD_READ) rd_avail <= 1'b0;
          case (cmd_idle ? ST_CMD : state)
            ST_CMD:
              case (cmd_in)
                CMD_READ_ID: state <= ST_RID_A;
                CMD_READ:    begin
                  // 00h then address cycles starts a page read; 00h then
                  // re_n strobes returns to the data of the last read
                  state <= ST_ADDR; rd_mode <= 1'b1; addr_cnt <= 3'd0;
                  if (rd_avail) begin omode <= O_DATA; ptr <= col_q; started <= 1'b0; end
                end
                CMD_PROG:    begin
                  state <= ST_ADDR; rd_mode <= 1'b0; addr_cnt <= 3'd0; fail <= 1'b0;
                  for (int i = 0; i < 64; i++) pbuf[i] <= 8'hFF;
                end
                CMD_ERASE:   begin state <= ST_EADDR; addr_cnt <= 3'd0; fail <= 1'b0; end
                default:     irq <= 1'b1;               // unknown command
              endcase
            ST_WAIT30:
              if (cmd_in == CMD_READ_END) begin
                busy <= 1'b1; op <= OP_RD; busy_cnt <= T_R[9:0] - 10'd1; fail <= 1'b0;
                for (int i = 0; i < 64; i++) pbuf[i] <= mem[{page_q, i[5:0]}];
              end else irq <= 1'b1;
            ST_DIN:
              if (cmd_in == CMD_PROG_END) begin
                busy <= 1'b1; op <= OP_PROG; busy_cnt <= T_PROG[9:0] - 10'd1;
              end else irq <= 1'b1;
            ST_WAITD0:
              if (cmd_in == CMD_ERASE_END) begin
                busy <= 1'b1; op <= OP_ERASE; busy_cnt <= T_ERASE[9:0] - 10'd1;
              end else irq <= 1'b1;
            default: irq <= 1'b1;                       // inside an address phase
          endcase
        end
      end else if (latch_addr) begin
        case (state)
          ST_RID_A: begin
            state <= ST_CMD; omode <= O_ID; ptr <= 6'd0; started <= 1'b0;
          end
          ST_ADDR: begin
            omode    <= O_NONE;
            rd_avail <= 1'b0;
            if (addr_cnt == 3'd0) col_q  <= cmd_in[5:0];
            if (addr_cnt == 3'd2) page_q <= cmd_in[3:0];
            addr_cnt <= addr_cnt + 3'd1;
            if (addr_cnt == 3'd4) begin
              state <= rd_mode ? ST_WAIT30 : ST_DIN;
              ptr   <= col_q;
            end
          end
          ST_EADDR: begin
            if (addr_cnt == 3'd0) page_q <= cmd_in[3:0];
            addr_cnt <= addr_cnt + 3'd1;
            if (addr_cnt == 3'd2) state <= ST_WAITD0;
          end
          default: irq <= 1'b1;                         // address out of place
        endcase
      end
    end
  end

endmodule
