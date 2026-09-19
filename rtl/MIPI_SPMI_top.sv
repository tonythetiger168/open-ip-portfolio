// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI SPMI protocol IP -- SPMI slave controller
// Implementation scope (documented simplified subset of MIPI SPMI v2.x):
//   - SSC detection: SDATA held high >= 20 clk while SCLK low (longer than
//     any in-frame low-phase, so data traffic can never alias to an SSC)
//   - Command frame, 12 bits: SA[3:0] | C[3:0] | A[3:0]
//       C=4'h0 : register 0 write  (SPMI 0x00 class) -> data frame D[7:0]|P
//       C=4'h2 : register 0 read   (SPMI 0x20 class) -> slave drives D[7:0]|P
//       C=4'h3 : extended reg write(SPMI 0x30 class) -> A=BC(1..8), address
//                frame A[7:0]|P then BC data frames
//       C=4'h8 : extended reg read (SPMI 0x38 class) -> A=BC(1..8), address
//                frame then slave drives BC data frames
//   - A-bit arbitration on the 13th clock: master drives the A-bit; A=1 keeps
//     the bus (writes require A=1), A=0 grants the bus to the slave (reads).
//     A read requested with A=1 is yielded to the master (slave stays silent,
//     priority arbitration simplified to monitoring the A-bit).
//   - NACK (no-response) on illegal command / illegal BC / unknown SA + irq
//   - bus park: one SCLK cycle with SDATA driven low ends every transaction;
//     the slave recognises it and returns to idle
//   - 16x8 register file, auto-increment on extended accesses
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module MIPI_SPMI_top #(
  parameter int DW = 32,              // framework data width (kept)
  parameter int AW = 32,              // framework address width (kept)
  parameter logic [3:0] USID = 4'h5   // unique slave ID
)(
  input  logic clk,
  input  logic rst_n,
  input  logic sclk,                  // SPMI clock (driven by the master)
  inout  wire  sdata,                 // SPMI data (master parked low / tri-state)
  output logic irq                    // sticky protocol-error flag
);

  localparam int SSC_MIN = 20;        // clk cycles of SDATA high = valid SSC

  localparam logic [3:0] CMD_R0_W = 4'h0;
  localparam logic [3:0] CMD_R0_R = 4'h2;
  localparam logic [3:0] CMD_EXT_W = 4'h3;
  localparam logic [3:0] CMD_EXT_R = 4'h8;

  typedef enum logic [2:0] {
    S_IDLE,      // parked, wait for SSC
    S_CMD,       // shift in 12-bit command frame
    S_ABIT,      // sample the arbitration bit
    S_WDATA,     // register 0 write: 9-bit data frame
    S_XADDR,     // extended access: 9-bit address frame
    S_XDATA,     // extended write: BC x 9-bit data frames
    S_RDATA,     // read: drive BC x 9-bit data frames
    S_PARK       // bus park recognition
  } state_t;

  state_t state;

  // ------------------------------------------------------------------
  // input synchronizers (clk oversamples the bus)
  // ------------------------------------------------------------------
  logic [2:0] sclk_d, sdat_d;
  wire sdat_in = sdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_d <= 3'b000;
      sdat_d <= 3'b000;
    end else begin
      sclk_d <= {sclk_d[1:0], sclk};
      sdat_d <= {sdat_d[1:0], sdat_in};
    end
  end

  wire ev_clk_r = (sclk_d[2:1] == 2'b01);
  wire ev_clk_f = (sclk_d[2:1] == 2'b10);

  // ------------------------------------------------------------------
  // SDATA pad: slave drives only during read data frames
  // ------------------------------------------------------------------
  logic drv_en, drv_val;
  assign sdata = drv_en ? drv_val : 1'bz;

  // ------------------------------------------------------------------
  // datapath
  // ------------------------------------------------------------------
  logic [10:0] sh;                            // command shift register
  wire  [11:0] cmd_full = {sh, sdat_d[1]};    // 12-bit command frame
  wire  [8:0]  dat_full = {sh[7:0], sdat_d[1]}; // 9-bit data frame
  logic [3:0]  bcnt;
  logic [5:0]  ssc_cnt;
  logic        ssc_seen;
  logic [3:0]  cmd_q;                         // decoded command
  logic [3:0]  bc;                            // remaining byte count
  logic [3:0]  xaddr;                         // extended-access pointer
  logic [7:0]  rdata;                         // current read byte
  logic [7:0]  mem [0:15];
  logic        err_sticky;

  assign irq = err_sticky;

  wire [3:0] f_sa   = cmd_full[11:8];
  wire [3:0] f_cmd  = cmd_full[7:4];
  wire [3:0] f_addr = cmd_full[3:0];
  wire       d_par_ok = (^dat_full == 1'b0);  // even parity over 9 bits

  wire cmd_legal = (f_cmd == CMD_R0_W) || (f_cmd == CMD_R0_R) ||
                   (f_cmd == CMD_EXT_W) || (f_cmd == CMD_EXT_R);
  wire bc_legal  = (f_addr != 4'd0) && (f_addr <= 4'd8);

  // ------------------------------------------------------------------
  // sequential FSM + datapath
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      sh         <= 11'h000;
      bcnt       <= 4'd0;
      ssc_cnt    <= 6'd0;
      ssc_seen   <= 1'b0;
      cmd_q      <= 4'h0;
      bc         <= 4'd0;
      xaddr      <= 4'd0;
      rdata      <= 8'h00;
      drv_en     <= 1'b0;
      drv_val    <= 1'b0;
      err_sticky <= 1'b0;
      for (int i = 0; i < 16; i++) mem[i] <= 8'h00; // fixed bound: 16 regs
    end else begin
      case (state)
        // --------------------------------------------------- idle / SSC
        S_IDLE: begin
          drv_en <= 1'b0;
          // count SDATA-high cycles while SCLK is low
          if (!sclk_d[1] && sdat_d[1]) begin
            if (ssc_cnt != 6'h3F) ssc_cnt <= ssc_cnt + 6'd1;
            if (ssc_cnt >= SSC_MIN[5:0]) ssc_seen <= 1'b1;
          end else begin
            ssc_cnt <= 6'd0;
          end
          // first SCLK rising after a valid SSC = first command bit
          if (ssc_seen && ev_clk_r) begin
            sh         <= {10'h000, sdat_d[1]};
            bcnt       <= 4'd1;
            ssc_seen   <= 1'b0;
            ssc_cnt    <= 6'd0;
            err_sticky <= 1'b0;      // new transaction clears the flag
            state      <= S_CMD;
          end
        end

        // --------------------------------------------------- command frame
        S_CMD: begin
          if (ev_clk_r) begin
            sh <= cmd_full[10:0];
            if (bcnt == 4'd11) begin   // all 12 bits received
              bcnt  <= 4'd0;
              cmd_q <= f_cmd;
              if ((f_sa != USID) || !cmd_legal ||
                  ((f_cmd == CMD_EXT_W || f_cmd == CMD_EXT_R) && !bc_legal)) begin
                err_sticky <= 1'b1;    // NACK: no response + irq
                state      <= S_PARK;
              end else begin
                bc <= f_addr;          // BC for extended commands
                state <= S_ABIT;
              end
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        // --------------------------------------------------- A-bit arbitration
        S_ABIT: begin
          if (ev_clk_r) begin
            bcnt <= 4'd0;
            case (cmd_q)
              CMD_R0_W: begin
                // write: master must keep the bus (A=1)
                state <= sdat_d[1] ? S_WDATA : S_PARK;
              end
              CMD_R0_R: begin
                if (sdat_d[1]) begin
                  state <= S_PARK;     // master priority: slave yields
                end else begin
                  rdata <= mem[4'd0];
                  xaddr <= 4'd1;
                  state <= S_RDATA;    // bc==1 from command A field=0? fixed 1
                  bc    <= 4'd1;
                end
              end
              CMD_EXT_W: begin
                state <= sdat_d[1] ? S_XADDR : S_PARK;
              end
              CMD_EXT_R: begin
                if (sdat_d[1]) begin
                  state <= S_PARK;     // master priority: slave yields
                end else begin
                  state <= S_XADDR;
                end
              end
              default: state <= S_PARK;
            endcase
          end
        end

        // --------------------------------------------------- reg0 write data
        S_WDATA: begin
          if (ev_clk_r) begin
            sh <= {3'h0, dat_full[7:0]};
            if (bcnt == 4'd8) begin
              bcnt <= 4'd0;
              if (d_par_ok) begin
                mem[4'd0] <= dat_full[8:1];
              end else begin
                err_sticky <= 1'b1;    // data parity error: drop + irq
              end
              state <= S_PARK;
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        // --------------------------------------------------- extended address
        S_XADDR: begin
          if (ev_clk_r) begin
            sh <= {3'h0, dat_full[7:0]};
            if (bcnt == 4'd8) begin
              bcnt <= 4'd0;
              if (d_par_ok) begin
                xaddr <= dat_full[4:1]; // start address (reg-file 16 deep)
                if (cmd_q == CMD_EXT_R) begin
                  rdata <= mem[dat_full[4:1]];
                  xaddr <= dat_full[4:1] + 4'd1;
                  state <= S_RDATA;
                end else begin
                  state <= S_XDATA;
                end
              end else begin
                err_sticky <= 1'b1;
                state      <= S_PARK;
              end
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        // --------------------------------------------------- extended write data
        S_XDATA: begin
          if (ev_clk_r) begin
            sh <= {3'h0, dat_full[7:0]};
            if (bcnt == 4'd8) begin
              bcnt <= 4'd0;
              if (d_par_ok) begin
                mem[xaddr] <= dat_full[8:1];
                xaddr      <= xaddr + 4'd1;
                if (bc == 4'd1) begin
                  state <= S_PARK;     // all BC bytes written
                end else begin
                  bc <= bc - 4'd1;
                end
              end else begin
                err_sticky <= 1'b1;    // drop remaining bytes + irq
                state      <= S_PARK;
              end
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        // --------------------------------------------------- read data drive
        S_RDATA: begin
          if (ev_clk_f) begin
            if (bcnt < 4'd9) begin
              drv_en  <= 1'b1;
              drv_val <= (bcnt < 4'd8) ? rdata[3'd7 - bcnt[2:0]] : (^rdata);
              bcnt    <= bcnt + 4'd1;
            end else if (bc > 4'd1) begin
              // next byte of an extended read: drive its MSB right now
              bc      <= bc - 4'd1;
              rdata   <= mem[xaddr];
              xaddr   <= xaddr + 4'd1;
              bcnt    <= 4'd1;
              drv_en  <= 1'b1;
              drv_val <= mem[xaddr][7];
            end else begin
              drv_en <= 1'b0;          // release after last parity bit
              bcnt   <= 4'd0;
              state  <= S_PARK;
            end
          end
        end

        // --------------------------------------------------- bus park
        S_PARK: begin
          drv_en <= 1'b0;
          if (ev_clk_r) begin          // master bus-park cycle recognised
            bcnt  <= 4'd0;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
