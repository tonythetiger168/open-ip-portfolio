// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DFI 5.0 (MC-PHY Interface) protocol IP -- PHY-side DFI model
// Implementation scope (documented simplified subset of DFI 5.0):
//   - Single 1:1 frequency ratio slice: dfi_clk == clk (no 1:2/1:4 phase
//     alignment, documented simplification).
//   - Command channel sampled from the MC: dfi_address/dfi_bank/
//     dfi_ras_n/dfi_cas_n/dfi_we_n/dfi_cs_n/dfi_cke/dfi_odt.
//     DDR-style command decode {ras_n,cas_n,we_n} while cs_n=0:
//       ACT=3'b011  RD=3'b101  WR=3'b100  PRE=3'b010  REF=3'b001
//       NOP=3'b111  MRS=3'b000 (accepted, no mode-register side effects)
//   - Write data path: dfi_wrdata_en starts an internal PHY write delay
//     line; exactly t_phy_wrlat(=4) cycles later dfi_wrdata +
//     dfi_wrdata_mask (1 = byte masked off) are committed to the DRAM
//     array model.
//   - Read data path: dfi_rddata_en starts an internal PHY read delay
//     line; exactly t_phy_rdlat(=5) cycles later dfi_rddata_valid pulses
//     for one cycle with dfi_rddata (gated to 0 when not valid).
//   - Initialisation: dfi_init_start runs a 32-cycle init sequence, then
//     dfi_init_complete is held while dfi_init_start stays asserted
//     (DFI handshake); the initialised state persists after release.
//     Any non-NOP/DES command before initialisation is ignored + irq.
//   - Low power: dfi_lp_ctrl request is acknowledged with dfi_lp_ctrl_ack
//     after a 2-cycle handshake; commands while in LP are ignored + irq.
//   - Backing store: 8 banks x 32 rows x 32-bit DRAM array model.
//   - dfi_odt is sampled (termination) but has no data-path side effect.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module DFI_5_0__MC_PHY_Interface__top #(
  parameter int DW = 32,              // framework data width (kept)
  parameter int AW = 32,              // framework address width (kept)
  parameter int T_PHY_WRLAT = 4,      // PHY write latency (dfi cycles)
  parameter int T_PHY_RDLAT = 5,      // PHY read latency (dfi cycles)
  parameter int INIT_CYCLES = 32      // init sequence length
)(
  input  logic        clk,            // dfi_clk (1:1 ratio)
  input  logic        rst_n,
  // command channel (MC -> PHY)
  input  logic [16:0] dfi_address,
  input  logic [2:0]  dfi_bank,
  input  logic        dfi_ras_n,
  input  logic        dfi_cas_n,
  input  logic        dfi_we_n,
  input  logic        dfi_cs_n,
  input  logic        dfi_cke,
  input  logic        dfi_odt,
  // write data channel (MC -> PHY)
  input  logic        dfi_wrdata_en,
  input  logic [31:0] dfi_wrdata,
  input  logic [3:0]  dfi_wrdata_mask,
  // read data channel (PHY -> MC)
  input  logic        dfi_rddata_en,
  output logic        dfi_rddata_valid,
  output logic [31:0] dfi_rddata,
  // initialisation / low power
  input  logic        dfi_init_start,
  output logic        dfi_init_complete,
  input  logic        dfi_lp_ctrl,
  output logic        dfi_lp_ctrl_ack,
  output logic        irq             // sticky protocol-error flag
);

  // ------------------------------------------------------------------
  // command decode (DDR-style truth table, cs_n = 0)
  // ------------------------------------------------------------------
  localparam logic [2:0] CMD_RD  = 3'b101;
  localparam logic [2:0] CMD_WR  = 3'b100;
  localparam logic [2:0] CMD_NOP = 3'b111;

  wire [2:0] cmd     = {dfi_ras_n, dfi_cas_n, dfi_we_n};
  wire       cmd_des = dfi_cs_n;
  wire       cmd_nop = !cmd_des && (cmd == CMD_NOP);
  wire       cmd_rd  = !cmd_des && (cmd == CMD_RD);
  wire       cmd_wr  = !cmd_des && (cmd == CMD_WR);
  wire       cmd_oth = !cmd_des && !cmd_nop && !cmd_rd && !cmd_wr;

  // ------------------------------------------------------------------
  // DRAM array model: 8 banks x 32 rows of 32-bit words
  // ------------------------------------------------------------------
  (* ram_style = "block" *) logic [31:0] mem [0:255];
  wire  [7:0]  cur_addr = {dfi_bank, dfi_address[4:0]};
  logic [7:0]  wr_addr_q, rd_addr_q;

  // ------------------------------------------------------------------
  // init sequencer
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {INIT_IDLE, INIT_RUN, INIT_DONE} init_t;
  init_t       init_st;
  logic [7:0]  init_cnt;
  logic        init_start_q;
  logic        initialized;     // persists after the handshake completes

  // ------------------------------------------------------------------
  // low-power handshake
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {LP_RUN, LP_REQ, LP_SLEEP, LP_EXIT} lp_t;
  lp_t         lp_st;
  logic [1:0]  lp_cnt;
  logic        lp_ctrl_ack_q;

  // ------------------------------------------------------------------
  // PHY delay lines (shift registers, 1 bit per dfi cycle)
  // ------------------------------------------------------------------
  logic [T_PHY_WRLAT-1:0] wr_dly;   // dfi_wrdata_en delay line
  logic [T_PHY_RDLAT-1:0] rd_dly;   // dfi_rddata_en delay line

  wire wr_commit = wr_dly[T_PHY_WRLAT-1];
  wire rd_commit = rd_dly[T_PHY_RDLAT-1];

  wire lp_active = (lp_st == LP_SLEEP) || (lp_st == LP_REQ);
  wire dfi_up    = initialized && !lp_active && dfi_cke;

  // illegal command: any non-NOP/DES command before init, in LP, or
  // with cke low -> command is ignored and sticky irq is raised
  wire cmd_ill = (cmd_rd || cmd_wr || cmd_oth) && !dfi_up;

  // ------------------------------------------------------------------
  // sequential logic
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      init_st          <= INIT_IDLE;
      init_cnt         <= 8'd0;
      init_start_q     <= 1'b0;
      dfi_init_complete <= 1'b0;
      initialized      <= 1'b0;
      lp_st            <= LP_RUN;
      lp_cnt           <= 2'd0;
      lp_ctrl_ack_q    <= 1'b0;
      wr_dly           <= '0;
      rd_dly           <= '0;
      wr_addr_q        <= 8'd0;
      rd_addr_q        <= 8'd0;
      dfi_rddata_valid <= 1'b0;
      dfi_rddata       <= 32'd0;
      irq              <= 1'b0;
    end else begin
      // ---- init sequencer ---------------------------------------
      init_start_q <= dfi_init_start;
      case (init_st)
        INIT_IDLE: begin
          dfi_init_complete <= 1'b0;
          if (dfi_init_start && !init_start_q) begin
            init_st     <= INIT_RUN;
            init_cnt    <= INIT_CYCLES[7:0] - 8'd1;
            initialized <= 1'b0;        // re-init revokes the state
          end
        end
        INIT_RUN: begin
          if (init_cnt == 8'd0) begin
            init_st           <= INIT_DONE;
            dfi_init_complete <= 1'b1;
            initialized       <= 1'b1;
          end else begin
            init_cnt <= init_cnt - 8'd1;
          end
        end
        INIT_DONE: begin
          if (!dfi_init_start) begin      // handshake release
            init_st           <= INIT_IDLE;
            dfi_init_complete <= 1'b0;
          end else begin
            dfi_init_complete <= 1'b1;
          end
        end
        default: init_st <= INIT_IDLE;
      endcase

      // ---- low-power handshake ----------------------------------
      case (lp_st)
        LP_RUN: begin
          lp_ctrl_ack_q <= 1'b0;
          if (dfi_lp_ctrl) begin
            lp_st  <= LP_REQ;
            lp_cnt <= 2'd1;             // 2-cycle ack delay
          end
        end
        LP_REQ: begin
          if (lp_cnt == 2'd0) begin
            lp_st         <= LP_SLEEP;
            lp_ctrl_ack_q <= 1'b1;
          end else begin
            lp_cnt <= lp_cnt - 2'd1;
          end
        end
        LP_SLEEP: begin
          lp_ctrl_ack_q <= 1'b1;
          if (!dfi_lp_ctrl) begin
            lp_st  <= LP_EXIT;
            lp_cnt <= 2'd1;
          end
        end
        LP_EXIT: begin
          if (lp_cnt == 2'd0) begin
            lp_st         <= LP_RUN;
            lp_ctrl_ack_q <= 1'b0;
          end else begin
            lp_cnt <= lp_cnt - 2'd1;
          end
        end
        default: lp_st <= LP_RUN;
      endcase

      // ---- command capture ---------------------------------------
      if (dfi_up) begin
        if (cmd_wr) wr_addr_q <= cur_addr;
        if (cmd_rd) rd_addr_q <= cur_addr;
      end
      if (cmd_ill) irq <= 1'b1;         // illegal command: ignore + irq

      // ---- PHY write delay line ----------------------------------
      // MC asserts dfi_wrdata_en and presents dfi_wrdata exactly
      // t_phy_wrlat cycles later; the delay line times the capture.
      // The line is gated while the PHY is not initialised / in LP.
      if (dfi_up) wr_dly <= {wr_dly[T_PHY_WRLAT-2:0], dfi_wrdata_en};
      else        wr_dly <= '0;
      if (wr_commit) begin
        if (!dfi_wrdata_mask[0]) mem[wr_addr_q][7:0]   <= dfi_wrdata[7:0];
        if (!dfi_wrdata_mask[1]) mem[wr_addr_q][15:8]  <= dfi_wrdata[15:8];
        if (!dfi_wrdata_mask[2]) mem[wr_addr_q][23:16] <= dfi_wrdata[23:16];
        if (!dfi_wrdata_mask[3]) mem[wr_addr_q][31:24] <= dfi_wrdata[31:24];
      end

      // ---- PHY read delay line + rddata gate ---------------------
      if (dfi_up) rd_dly <= {rd_dly[T_PHY_RDLAT-2:0], dfi_rddata_en};
      else        rd_dly <= '0;
      if (rd_commit) begin
        dfi_rddata_valid <= 1'b1;
        dfi_rddata       <= mem[rd_addr_q];
      end else begin
        dfi_rddata_valid <= 1'b0;
        dfi_rddata       <= 32'd0;      // gated when not valid
      end
    end
  end

  assign dfi_lp_ctrl_ack = lp_ctrl_ack_q;

  // odt/address upper bits intentionally unused in this slice
  wire unused = &{1'b0, dfi_odt, dfi_address[16:5]};

endmodule
