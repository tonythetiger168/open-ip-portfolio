// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI RFFE protocol IP -- RFFE slave controller
// Implementation scope (documented simplified subset of MIPI RFFE v2.x):
//   - SSC detection: SDATA held high >= 20 clk while SCLK low (longer than any
//     in-frame low-phase, so data traffic can never alias to an SSC)
//   - Command frame, 13 bits: SA[3:0] | C[2:0] | A[4:0] | P (even parity)
//       C=3'b010 : register write      -> data frame D[7:0]|P
//       C=3'b011 : register read       -> BP cycle, slave drives D[7:0]|P
//       C=3'b110 : extended reg write  -> A[3:0]=BC(1..8), address frame
//                                         A[7:0]|P then BC data frames
//   - 16x8 register file, auto-increment on extended writes
//   - parity error / unknown USID / illegal command -> no response + irq
//     (sticky until the next SSC)
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module MIPI_RFFE_top #(
  parameter int DW = 32,              // framework data width (kept)
  parameter int AW = 32,              // framework address width (kept)
  parameter logic [3:0] USID = 4'h5   // unique slave ID
)(
  input  logic clk,
  input  logic rst_n,
  input  logic sclk,                  // RFFE clock (driven by the master)
  inout  wire  sdata,                 // RFFE data (master parked low / tri-state)
  output logic irq                    // sticky protocol-error flag
);

  localparam int SSC_MIN = 20;         // clk cycles of SDATA high = valid SSC

  localparam logic [2:0] CMD_REG_W = 3'b010;
  localparam logic [2:0] CMD_REG_R = 3'b011;
  localparam logic [2:0] CMD_EXT_W = 3'b110;

  typedef enum logic [2:0] {
    S_IDLE,      // parked, wait for SSC
    S_CMD,       // shift in 13-bit command frame
    S_WDATA,     // register write: 9-bit data frame
    S_BP,        // register read: bus-park turnaround cycle
    S_RDATA,     // register read: drive 9-bit data frame
    S_XADDR,     // extended write: 9-bit address frame
    S_XDATA      // extended write: BC x 9-bit data frames
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
  logic [11:0] sh;                          // command shift register
  wire  [12:0] cmd_full  = {sh, sdat_d[1]}; // 13-bit command frame
  wire  [8:0]  dat_full  = {sh[7:0], sdat_d[1]}; // 9-bit data frame
  logic [3:0]  bcnt;
  logic [5:0]  ssc_cnt;
  logic        ssc_seen;
  logic [3:0]  addr;                        // register address
  logic [3:0]  xaddr;                       // extended-write pointer
  logic [3:0]  bc;                          // extended-write byte count
  logic [7:0]  rdata;                       // latched read data
  logic [7:0]  mem [0:15];
  logic        err_sticky;

  assign irq = err_sticky;

  // command frame fields
  wire [3:0] f_sa   = cmd_full[12:9];
  wire [2:0] f_cmd  = cmd_full[8:6];
  wire [4:0] f_addr = cmd_full[5:1];
  wire       f_par_ok = (^cmd_full == 1'b0);   // even parity over 13 bits
  wire       d_par_ok = (^dat_full == 1'b0);   // even parity over 9 bits

  // ------------------------------------------------------------------
  // sequential FSM + datapath
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      sh         <= 12'h000;
      bcnt       <= 4'd0;
      ssc_cnt    <= 6'd0;
      ssc_seen   <= 1'b0;
      addr       <= 4'd0;
      xaddr      <= 4'd0;
      bc         <= 4'd0;
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
            sh         <= {11'h000, sdat_d[1]};
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
            sh <= cmd_full[11:0];
            if (bcnt == 4'd12) begin   // all 13 bits received
              bcnt <= 4'd0;
              if (!f_par_ok) begin
                err_sticky <= 1'b1;    // parity error: no response + irq
                state      <= S_IDLE;
              end else if (f_sa != USID) begin
                err_sticky <= 1'b1;    // unknown USID: no response + irq
                state      <= S_IDLE;
              end else begin
                case (f_cmd)
                  CMD_REG_W: begin
                    addr  <= f_addr[3:0];
                    state <= S_WDATA;
                  end
                  CMD_REG_R: begin
                    addr  <= f_addr[3:0];
                    rdata <= mem[f_addr[3:0]];
                    state <= S_BP;
                  end
                  CMD_EXT_W: begin
                    if (f_addr[3:0] == 4'd0 || f_addr[3:0] > 4'd8) begin
                      err_sticky <= 1'b1;      // illegal byte count
                      state      <= S_IDLE;
                    end else begin
                      bc    <= f_addr[3:0];
                      state <= S_XADDR;
                    end
                  end
                  default: begin
                    err_sticky <= 1'b1;        // illegal command
                    state      <= S_IDLE;
                  end
                endcase
              end
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        // --------------------------------------------------- write data
        S_WDATA: begin
          if (ev_clk_r) begin
            sh <= {4'h0, dat_full[7:0]};
            if (bcnt == 4'd8) begin
              bcnt <= 4'd0;
              if (d_par_ok) begin
                mem[addr] <= dat_full[8:1];
              end else begin
                err_sticky <= 1'b1;    // data parity error: drop write + irq
              end
              state <= S_IDLE;
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        // --------------------------------------------------- read turnaround
        S_BP: begin
          if (ev_clk_r) begin          // master bus-park cycle done
            bcnt  <= 4'd0;
            state <= S_RDATA;
          end
        end

        S_RDATA: begin
          if (ev_clk_f) begin
            if (bcnt < 4'd9) begin
              drv_en  <= 1'b1;
              drv_val <= (bcnt < 4'd8) ? rdata[3'd7 - bcnt[2:0]] : (^rdata);
              bcnt    <= bcnt + 4'd1;
            end else begin
              drv_en <= 1'b0;          // release after parity bit
              bcnt   <= 4'd0;
              state  <= S_IDLE;
            end
          end
        end

        // --------------------------------------------------- extended write
        S_XADDR: begin
          if (ev_clk_r) begin
            sh <= {4'h0, dat_full[7:0]};
            if (bcnt == 4'd8) begin
              bcnt <= 4'd0;
              if (d_par_ok) begin
                xaddr <= dat_full[4:1]; // start address (reg-file is 16 deep)
                state <= S_XDATA;
              end else begin
                err_sticky <= 1'b1;
                state      <= S_IDLE;
              end
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        S_XDATA: begin
          if (ev_clk_r) begin
            sh <= {4'h0, dat_full[7:0]};
            if (bcnt == 4'd8) begin
              bcnt <= 4'd0;
              if (d_par_ok) begin
                mem[xaddr] <= dat_full[8:1];
                xaddr      <= xaddr + 4'd1;
                if (bc == 4'd1) begin
                  state <= S_IDLE;     // all BC bytes written
                end else begin
                  bc <= bc - 4'd1;
                end
              end else begin
                err_sticky <= 1'b1;    // drop remaining bytes + irq
                state      <= S_IDLE;
              end
            end else begin
              bcnt <= bcnt + 4'd1;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
