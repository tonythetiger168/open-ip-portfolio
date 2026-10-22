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
//   - Bank state: ACT opens a bank (row = dfi_address; the array keeps
//     row[1:0]), PRE closes it (dfi_address[10] = 1: all banks), RD / WR
//     take the column from dfi_address[2:0] of an open bank. ACT to an
//     open bank, RD / WR to a closed bank, REF / MRS with a bank open are
//     ignored and raise irq.
//   - Write path (tphy_wrlat): the MC must assert dfi_wrdata_en, with
//     dfi_wrdata / dfi_wrdata_mask (1 = byte masked off), exactly
//     T_PHY_WRLAT cycles after each WR command.
//   - Read path (trddata_en, tphy_rdlat): the MC must assert dfi_rddata_en
//     exactly T_RDDATA_EN cycles after each RD command; the array is read
//     on that beat and T_PHY_RDLAT cycles later the PHY returns one
//     dfi_rddata_valid beat (dfi_rddata is 0 when not valid). A write beat
//     and a read beat of the same word on the same cycle read the old data.
//     A missing or unexpected dfi_wrdata_en / dfi_rddata_en raises irq;
//     the beat is dropped (no write, no read data).
//   - Initialisation: a rising dfi_init_start runs a 32-cycle init
//     sequence, then dfi_init_complete is held while dfi_init_start stays
//     asserted (DFI handshake); the initialised state persists after
//     release, a new dfi_init_start revokes it and closes all banks.
//   - Low power: dfi_lp_ctrl request is acknowledged with dfi_lp_ctrl_ack
//     after a 2-cycle handshake and released 2 cycles after the request
//     drops. Any command other than NOP / DES before initialisation, in
//     low power or with dfi_cke low is ignored and raises irq.
//   - Backing store: 8 banks x 4 rows x 8 columns x 32-bit DRAM array.
//   - irq is sticky until reset. dfi_odt is sampled (termination) but has
//     no data-path side effect.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module DFI_5_0__MC_PHY_Interface__top #(
  parameter int T_PHY_WRLAT = 4,      // WR command -> dfi_wrdata_en (dfi cycles)
  parameter int T_RDDATA_EN = 3,      // RD command -> dfi_rddata_en
  parameter int T_PHY_RDLAT = 5,      // dfi_rddata_en -> dfi_rddata_valid
  parameter int INIT_CYCLES = 32      // init sequence length
)(
  input  logic        clk,            // dfi_clk (1:1 ratio)
  input  logic        rst_n,
  // command channel (MC -> PHY); odt and the address bits beyond the array
  // are accepted for interface compatibility only
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [16:0] dfi_address,
  input  logic [2:0]  dfi_bank,
  input  logic        dfi_ras_n,
  input  logic        dfi_cas_n,
  input  logic        dfi_we_n,
  input  logic        dfi_cs_n,
  input  logic        dfi_cke,
  input  logic        dfi_odt,
  /* verilator lint_on UNUSEDSIGNAL */
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
  localparam logic [2:0] CMD_ACT = 3'b011;
  localparam logic [2:0] CMD_RD  = 3'b101;
  localparam logic [2:0] CMD_WR  = 3'b100;
  localparam logic [2:0] CMD_PRE = 3'b010;
  localparam logic [2:0] CMD_NOP = 3'b111;

  wire [2:0] cmd     = {dfi_ras_n, dfi_cas_n, dfi_we_n};
  wire       cmd_v   = !dfi_cs_n && (cmd != CMD_NOP);     // a real command

  // ------------------------------------------------------------------
  // init sequencer
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {INIT_IDLE, INIT_RUN, INIT_DONE} init_t;
  init_t       init_st;
  logic [4:0]  init_cnt;
  logic        init_start_q;
  logic        initialized;     // persists after the handshake completes

  // ------------------------------------------------------------------
  // low-power handshake
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {LP_RUN, LP_REQ, LP_SLEEP, LP_EXIT} lp_t;
  lp_t         lp_st;
  logic        lp_cnt;

  wire lp_active = (lp_st == LP_SLEEP) || (lp_st == LP_REQ);
  wire dfi_up    = initialized && !lp_active && dfi_cke;

  // ------------------------------------------------------------------
  // bank state and command checks
  // ------------------------------------------------------------------
  logic [7:0]  bank_open;
  logic [1:0]  bank_row [0:7];
  wire         b_open  = bank_open[dfi_bank];
  wire  [7:0]  cur_addr = {dfi_bank, bank_row[dfi_bank], dfi_address[2:0]};

  wire do_act = cmd_v && dfi_up && (cmd == CMD_ACT) && !b_open;
  wire do_rd  = cmd_v && dfi_up && (cmd == CMD_RD)  &&  b_open;
  wire do_wr  = cmd_v && dfi_up && (cmd == CMD_WR)  &&  b_open;
  wire do_pre = cmd_v && dfi_up && (cmd == CMD_PRE);
  // REF (001) / MRS (000): need all banks closed
  wire do_ref = cmd_v && dfi_up && !cmd[2] && !cmd[1] && (bank_open == 8'd0);
  wire cmd_ill = cmd_v && !(do_act || do_rd || do_wr || do_pre || do_ref);

  // ------------------------------------------------------------------
  // timing pipelines: {valid, word address} per cycle
  // ------------------------------------------------------------------
  logic [T_PHY_WRLAT-1:0] wr_v;
  logic [7:0]             wr_a [0:T_PHY_WRLAT-1];
  logic [T_RDDATA_EN-1:0] re_v;
  logic [7:0]             re_a [0:T_RDDATA_EN-1];
  logic [T_PHY_RDLAT-1:0] rl_v;
  logic [31:0]            rl_d [0:T_PHY_RDLAT-1];   // data read at dfi_rddata_en

  wire wr_due = wr_v[T_PHY_WRLAT-1];
  wire re_due = re_v[T_RDDATA_EN-1];
  wire wr_go  = wr_due && dfi_wrdata_en;
  wire re_go  = re_due && dfi_rddata_en;
  wire beat_bad = (wr_due != dfi_wrdata_en) || (re_due != dfi_rddata_en);

  (* ram_style = "block" *) logic [31:0] mem [0:255];

  // ------------------------------------------------------------------
  // sequential logic
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      init_st           <= INIT_IDLE;
      init_cnt          <= 5'd0;
      init_start_q      <= 1'b0;
      dfi_init_complete <= 1'b0;
      initialized       <= 1'b0;
      lp_st             <= LP_RUN;
      lp_cnt            <= 1'b0;
      dfi_lp_ctrl_ack   <= 1'b0;
      bank_open         <= 8'd0;
      for (int b = 0; b < 8; b++) bank_row[b] <= 2'd0;
      wr_v              <= '0;
      re_v              <= '0;
      rl_v              <= '0;
      for (int i = 0; i < T_PHY_WRLAT; i++) wr_a[i] <= 8'd0;
      for (int i = 0; i < T_RDDATA_EN; i++) re_a[i] <= 8'd0;
      for (int i = 0; i < T_PHY_RDLAT; i++) rl_d[i] <= 32'd0;
      dfi_rddata_valid  <= 1'b0;
      dfi_rddata        <= 32'd0;
      irq               <= 1'b0;
    end else begin
      // ---- init sequencer ---------------------------------------
      init_start_q <= dfi_init_start;
      case (init_st)
        INIT_IDLE: begin
          if (dfi_init_start && !init_start_q) begin
            init_st     <= INIT_RUN;
            init_cnt    <= 5'(INIT_CYCLES - 1);
            initialized <= 1'b0;        // re-init revokes the state
          end
        end
        INIT_RUN: begin
          if (init_cnt == 5'd0) begin
            init_st           <= INIT_DONE;
            dfi_init_complete <= 1'b1;
            initialized       <= 1'b1;
          end else begin
            init_cnt <= init_cnt - 5'd1;
          end
        end
        default: begin                  // INIT_DONE
          if (!dfi_init_start) begin    // handshake release
            init_st           <= INIT_IDLE;
            dfi_init_complete <= 1'b0;
          end
        end
      endcase

      // ---- low-power handshake ----------------------------------
      case (lp_st)
        LP_RUN: if (dfi_lp_ctrl) begin
          lp_st  <= LP_REQ;
          lp_cnt <= 1'b1;               // 2-cycle ack delay
        end
        LP_REQ: begin
          if (!lp_cnt) begin
            lp_st           <= LP_SLEEP;
            dfi_lp_ctrl_ack <= 1'b1;
          end else lp_cnt <= 1'b0;
        end
        LP_SLEEP: if (!dfi_lp_ctrl) begin
          lp_st  <= LP_EXIT;
          lp_cnt <= 1'b1;
        end
        default: begin                  // LP_EXIT
          if (!lp_cnt) begin
            lp_st           <= LP_RUN;
            dfi_lp_ctrl_ack <= 1'b0;
          end else lp_cnt <= 1'b0;
        end
      endcase

      // ---- bank state --------------------------------------------
      if (do_act) begin
        bank_open[dfi_bank] <= 1'b1;
        bank_row[dfi_bank]  <= dfi_address[1:0];
      end
      if (do_pre) begin
        if (dfi_address[10]) bank_open <= 8'd0;
        else bank_open[dfi_bank] <= 1'b0;
      end
      if (init_st == INIT_IDLE && dfi_init_start && !init_start_q) bank_open <= 8'd0;

      // ---- timing pipelines --------------------------------------
      wr_v <= {wr_v[T_PHY_WRLAT-2:0], do_wr};
      re_v <= {re_v[T_RDDATA_EN-2:0], do_rd};
      rl_v <= {rl_v[T_PHY_RDLAT-2:0], re_go};
      wr_a[0] <= cur_addr;
      re_a[0] <= cur_addr;
      rl_d[0] <= mem[re_a[T_RDDATA_EN-1]];
      for (int i = 1; i < T_PHY_WRLAT; i++) wr_a[i] <= wr_a[i-1];
      for (int i = 1; i < T_RDDATA_EN; i++) re_a[i] <= re_a[i-1];
      for (int i = 1; i < T_PHY_RDLAT; i++) rl_d[i] <= rl_d[i-1];

      if (wr_go) begin
        if (!dfi_wrdata_mask[0]) mem[wr_a[T_PHY_WRLAT-1]][7:0]   <= dfi_wrdata[7:0];
        if (!dfi_wrdata_mask[1]) mem[wr_a[T_PHY_WRLAT-1]][15:8]  <= dfi_wrdata[15:8];
        if (!dfi_wrdata_mask[2]) mem[wr_a[T_PHY_WRLAT-1]][23:16] <= dfi_wrdata[23:16];
        if (!dfi_wrdata_mask[3]) mem[wr_a[T_PHY_WRLAT-1]][31:24] <= dfi_wrdata[31:24];
      end

      dfi_rddata_valid <= rl_v[T_PHY_RDLAT-1];
      dfi_rddata       <= rl_v[T_PHY_RDLAT-1] ? rl_d[T_PHY_RDLAT-1] : 32'd0;

      if (cmd_ill || beat_bad) irq <= 1'b1;
    end
  end

endmodule
