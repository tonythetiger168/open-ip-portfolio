// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// xSPI (JESD251) 8D-8D-8D memory target: an octal-DDR NOR flash device with
// a 2^MEM_AW byte array, the JESD251 Profile 1.0 command set and DQS read
// strobe. Grown from the QSPI slave (oversampled clock, edge-counted frames)
// to eight data lines and both clock edges.
//   * Frame: CS# low, CK idles low. Every CK edge (rising and falling)
//     carries one byte on DQ[7:0]: edge 0 the command, edge 1 its extension
//     (the inverted command), edges 2..5 the address A[31:24]..A[7:0] for
//     commands that take one, then DUMMY CK cycles (2 x DUMMY edges) for
//     reads, then data, two bytes per CK cycle.
//   * Reads: from the first dummy edge the target drives DQS low (preamble)
//     and from the last one DQ; on each data edge it puts the next byte on
//     DQ and toggles DQS, so the host captures byte 2k on a DQS rise and
//     byte 2k + 1 on a DQS fall.
//     A0 is ignored (8D transfers start on an even address); the array
//     address wraps.
//   * Commands: 06F9 WREN, 04FB WRDI, 05FA RDSR, 9F60 RDID, EE11 8D READ,
//     12ED PAGE PROGRAM, 21DE SECTOR ERASE, 609F CHIP ERASE, 817E WRCR
//     (write configuration: dummy cycles), 857A RDCR, 6699 RESET ENABLE,
//     9966 RESET. Status register: [1] WEL, [0] WIP.
//   * Program / erase need WEL, start at CS# high and run in the
//     background (WIP = 1, one array byte per clock); WEL clears when they
//     finish. Program is NOR-style: bits only go from 1 to 0 (new = old &
//     data); the data wraps inside its PAGE-byte page. While WIP is set
//     only RDSR is accepted.
//   * Frame rules: commands without data must end after exactly their
//     header (WREN / WRDI / CE / RSTEN / RST after 2 edges, SE after 6);
//     PP and WRCR after a whole number of CK cycles with data; and no frame
//     may end with CK high (an odd number of edges). A frame that breaks a
//     rule, or any other error, is ignored to its end.
// irq_cmd pulses at the end of each accepted frame, irq_done when a
// program or erase finishes, irq_err on an error; err_code holds the last
// error: 1 bad extension, 2 unknown command, 3 busy, 4 WEL not set,
// 5 bad frame length / CS# with CK high, 6 dummy setting below 4,
// 7 RESET without RESET ENABLE.
// CK, CS# and DQ are sampled on clk: CK must stay high and low at least
// two clocks each, DQ be stable one clock before a CK edge and one after.
// The array is not cleared by reset (sim starts it at zero).
// ============================================================================
module xSPI_top #(
  parameter int MEM_AW  = 9,            // array: 2^MEM_AW bytes (9..16)
  parameter int PAGE_AW = 5,            // program page: 2^PAGE_AW bytes
  parameter int SECT_AW = 7,            // erase sector: 2^SECT_AW bytes
  parameter logic [4:0] DUMMY = 5'd8    // read latency after reset (CK cycles)
)(
  input  logic       clk,
  input  logic       rst_n,
  // xSPI pins (pad direction split: DQ / DQS drivers are enabled by *_oe)
  input  logic       ck,
  input  logic       csn,
  input  logic [7:0] dq_i,
  output logic [7:0] dq_o,
  output logic       dq_oe,
  output logic       dqs_o,
  output logic       dqs_oe,
  // device state
  output logic [1:0] sr,                // status register bits {WEL, WIP} (7:2 read 0)
  output logic [4:0] dummy,             // configured read latency
  output logic [2:0] err_code,
  output logic       irq_cmd,
  output logic       irq_done,
  output logic       irq_err
);
  localparam int MEM = 1 << MEM_AW, PAGE = 1 << PAGE_AW;

  typedef enum logic [2:0] { S_CMD, S_ADDR, S_DUMMY, S_DATA, S_END, S_IGN } st_t;
  st_t st;
  // decoded operation
  localparam logic [3:0] O_WREN = 4'd0, O_WRDI = 4'd1, O_RDSR = 4'd2, O_RDID = 4'd3,
                         O_READ = 4'd4, O_PP = 4'd5, O_SE = 4'd6, O_CE = 4'd7,
                         O_WRCR = 4'd8, O_RDCR = 4'd9, O_RSTEN = 4'd10, O_RST = 4'd11;

  logic [7:0] mem [0:MEM-1];
  initial for (int i = 0; i < MEM; i++) mem[i] = '0;
  logic [7:0] pb [0:PAGE-1];            // page buffer
  logic [PAGE-1:0] pv;                  // page buffer bytes written

  logic       ck_d, csn_d;
  logic [7:0] cmd;
  logic [3:0] op;
  logic [5:0] cnt;                      // edges within the phase
  logic       odd;                      // an odd number of edges so far
  logic       got;                      // a write frame carried data
  logic [MEM_AW-1:0] adr;               // array address (reads, program)
  logic [4:0] crv;                      // WRCR value (bits 7:5 are reserved)
  logic       wel, wip, rsten;
  logic [1:0] idx;                      // RDID byte index
  // background program / erase
  logic       b_pp;
  logic [MEM_AW-1:0] bptr, blim;

  wire edge_ = !csn && (ck != ck_d);
  wire fin   = csn && !csn_d;           // end of frame
  assign sr  = {wel, wip};

  // command decode: {op, needs address, is a read, needs WEL, valid}
  logic [7:0] dec;
  always_comb
    case (cmd)
      8'h06: dec = {O_WREN,  4'b0001};
      8'h04: dec = {O_WRDI,  4'b0001};
      8'h05: dec = {O_RDSR,  4'b1101};
      8'h9F: dec = {O_RDID,  4'b1101};
      8'hEE: dec = {O_READ,  4'b1101};
      8'h12: dec = {O_PP,    4'b1011};
      8'h21: dec = {O_SE,    4'b1011};
      8'h60: dec = {O_CE,    4'b0011};
      8'h81: dec = {O_WRCR,  4'b1011};
      8'h85: dec = {O_RDCR,  4'b1101};
      8'h66: dec = {O_RSTEN, 4'b0001};
      8'h99: dec = {O_RST,   4'b0001};
      default: dec = 8'h00;
    endcase
  // the byte a read sends next; RDID: manufacturer 'O', type 'X', capacity log2, 0
  logic [7:0] rbyte;
  always_comb
    case (op)
      O_RDSR:  rbyte = {6'b0, sr};
      O_RDCR:  rbyte = {3'b000, dummy};
      O_RDID:
        case (idx)
          2'd0:    rbyte = 8'h4F;
          2'd1:    rbyte = 8'h58;
          2'd2:    rbyte = 8'(MEM_AW);
          default: rbyte = 8'h00;
        endcase
      default: rbyte = mem[adr];
    endcase

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ck_d <= 1'b0; csn_d <= 1'b1; st <= S_CMD; cmd <= '0; op <= '0; cnt <= '0; odd <= 1'b0;
      got <= 1'b0; adr <= '0; crv <= '0; wel <= 1'b0; wip <= 1'b0; rsten <= 1'b0; idx <= '0;
      b_pp <= 1'b0; bptr <= '0; blim <= '0; pv <= '0; dummy <= DUMMY; err_code <= '0;
      dq_o <= '0; dq_oe <= 1'b0; dqs_o <= 1'b0; dqs_oe <= 1'b0;
      irq_cmd <= 1'b0; irq_done <= 1'b0; irq_err <= 1'b0;
    end else begin
      ck_d <= ck; csn_d <= csn;
      irq_cmd <= 1'b0; irq_done <= 1'b0; irq_err <= 1'b0;

      // background program / erase, one byte per clock
      if (wip) begin
        if (!b_pp) mem[bptr] <= 8'hFF;
        else if (pv[bptr[PAGE_AW-1:0]]) mem[bptr] <= mem[bptr] & pb[bptr[PAGE_AW-1:0]];
        bptr <= bptr + 1'b1;
        if (bptr == blim) begin wip <= 1'b0; wel <= 1'b0; irq_done <= 1'b1; end
      end

      if (edge_) begin
        odd <= !odd;
        case (st)
          S_CMD:
            if (cnt == 6'd0) begin cmd <= dq_i; cnt <= 6'd1; end
            else begin
              cnt <= '0;
              if (dq_i != ~cmd) begin st <= S_IGN; err_code <= 3'd1; irq_err <= 1'b1; end
              else if (!dec[0]) begin st <= S_IGN; err_code <= 3'd2; irq_err <= 1'b1; end
              else if (wip && dec[7:4] != O_RDSR) begin st <= S_IGN; err_code <= 3'd3; irq_err <= 1'b1; end
              else if (dec[1] && !wel) begin st <= S_IGN; err_code <= 3'd4; irq_err <= 1'b1; end
              else if (dec[7:4] == O_RST && !rsten) begin st <= S_IGN; err_code <= 3'd7; irq_err <= 1'b1; end
              else begin
                op <= dec[7:4]; idx <= '0; got <= 1'b0;
                if (dec[7:4] == O_PP) pv <= '0;
                if (dec[3]) st <= S_ADDR; else st <= S_END;
              end
            end
          S_ADDR: begin
            // only the array bits of A[15:0] are kept; A0 is forced to 0
            if (cnt == 6'd2) adr <= MEM_AW'({dq_i, 8'h00});
            if (cnt == 6'd3) begin
              adr <= {adr[MEM_AW-1:8], dq_i[7:1], 1'b0};
              cnt <= '0;
              if (op == O_SE) st <= S_END;
              else if (dec[2]) begin st <= S_DUMMY; dqs_oe <= 1'b1; dqs_o <= 1'b0; end
              else st <= S_DATA;
            end else cnt <= cnt + 1'b1;
          end
          S_DUMMY:
            if (cnt == {dummy, 1'b0} - 6'd1) begin
              st <= S_DATA; cnt <= '0; dq_oe <= 1'b1;       // the host has released DQ
            end else cnt <= cnt + 1'b1;
          S_DATA:
            if (dec[2]) begin                            // read: next byte, toggle DQS
              dq_o <= rbyte; dqs_o <= !dqs_o;
              adr <= adr + 1'b1; idx <= idx + 1'b1;
            end else begin                               // write data
              got <= 1'b1;
              if (op == O_WRCR) begin if (!got) crv <= dq_i[4:0]; end
              else begin
                pb[adr[PAGE_AW-1:0]] <= dq_i; pv[adr[PAGE_AW-1:0]] <= 1'b1;
                adr <= {adr[MEM_AW-1:PAGE_AW], adr[PAGE_AW-1:0] + 1'b1};
              end
            end
          S_END: begin st <= S_IGN; err_code <= 3'd5; irq_err <= 1'b1; end
          default: ;
        endcase
      end

      if (fin) begin
        st <= S_CMD; cnt <= '0; odd <= 1'b0;
        dq_oe <= 1'b0; dqs_oe <= 1'b0;
        if (st != S_IGN) begin
          if (odd || st == S_ADDR || (st == S_DATA && (op == O_PP || op == O_WRCR) && !got)) begin
            err_code <= 3'd5; irq_err <= 1'b1;
          end else if (st == S_CMD) begin
            ;                                            // CS# pulse without a command
          end else if (op == O_WRCR && crv < 5'd4) begin
            err_code <= 3'd6; irq_err <= 1'b1;
          end else begin
            irq_cmd <= 1'b1;
            rsten <= op == O_RSTEN;
            case (op)
              O_WREN: wel <= 1'b1;
              O_WRDI: wel <= 1'b0;
              O_WRCR: begin dummy <= crv; wel <= 1'b0; end
              O_RST:  begin dummy <= DUMMY; wel <= 1'b0; end
              O_PP: begin
                wip <= 1'b1; b_pp <= 1'b1;
                bptr <= {adr[MEM_AW-1:PAGE_AW], {PAGE_AW{1'b0}}};
                blim <= {adr[MEM_AW-1:PAGE_AW], {PAGE_AW{1'b1}}};
              end
              O_SE: begin
                wip <= 1'b1; b_pp <= 1'b0;
                bptr <= {adr[MEM_AW-1:SECT_AW], {SECT_AW{1'b0}}};
                blim <= {adr[MEM_AW-1:SECT_AW], {SECT_AW{1'b1}}};
              end
              O_CE: begin wip <= 1'b1; b_pp <= 1'b0; bptr <= '0; blim <= '1; end
              default: ;
            endcase
          end
        end
      end
    end
  end
endmodule
