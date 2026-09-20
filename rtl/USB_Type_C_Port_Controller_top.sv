// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB Type-C Port Controller (TCPC) -- DRP port controller
//
// Implementation scope:
//   * cc1/cc2 3-level analog-line inputs, encoded as 2-bit enum:
//       CC_OPEN = 2'b00 (nothing connected / line open)
//       CC_RD   = 2'b01 (sink pull-down Rd present)
//       CC_RA   = 2'b10 (powered-cable / audio accessory Ra present)
//       2'b11   = abnormal level (fault injection, raises irq)
//   * Attach-detect FSM: UNATTACHED -> ATTACHWAIT (100 clk debounce)
//     -> ATTACHED; orientation resolved from which CC pin saw Rd
//     (cc1 -> orientation=0, cc2 -> orientation=1). Ra-only or Rd on
//     both pins is not a sink attach and is ignored.
//   * Detach detect: active CC pin back to OPEN for 10 consecutive clks.
//   * vbus_en: asserted in ATTACHED when configured role is source (DFP);
//     stays low for sink role.
//   * 8 x 8-bit register port (I2C-style register file over a simplified
//     parallel command interface: reg_addr/reg_wdata/reg_rdata/reg_rd/reg_wr):
//       0 CC_STATUS  RO  {attached, orientation, fsm[1:0], cc2[1:0], cc1[1:0]}
//       1 ROLE_CTRL  RW  bit0: 1 = source/DFP (default), 0 = sink/UFP
//       2 FAULT_STAT RW1C bit0: abnormal CC level seen (sticky)
//       3 INT_STAT   RW1C bit0 attach, bit1 detach, bit2 fault (sticky)
//       4 DEBOUNCE   RO  attach debounce value (8'd100)
//       5 ORIENT     RO  bit0 = orientation
//       6 VBUS_STAT  RO  bit0 = vbus_en
//       7 DEVICE_ID  RO  8'hC7
//   * irq: asserted while an abnormal CC level is present or while any
//     sticky INT_STAT bit is set (cleared via RW1C write).
//
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module USB_Type_C_Port_Controller_top #(
  parameter int DW = 32,          // kept for framework compatibility
  parameter int AW = 32           // kept for framework compatibility
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic [1:0] cc1,         // CC1 line level (2-bit enum, see above)
  input  logic [1:0] cc2,         // CC2 line level
  output logic       attached,    // sink attached (debounced)
  output logic       orientation, // 0 = cc1 is the wired CC, 1 = cc2
  output logic       vbus_en,     // VBUS source enable (attached && source)
  input  logic [2:0] reg_addr,    // register command port
  input  logic [7:0] reg_wdata,
  output logic [7:0] reg_rdata,
  input  logic       reg_rd,
  input  logic       reg_wr,
  output logic       irq
);

  localparam logic [1:0] CC_OPEN = 2'b00;
  localparam logic [1:0] CC_RD   = 2'b01;
  localparam logic [1:0] CC_RA   = 2'b10;

  localparam int DEBOUNCE_ATTACH = 100;  // clk
  localparam int DEBOUNCE_DETACH = 10;   // clk

  // ------------------------------------------------------------------
  // attach / detach FSM
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {ST_UNATTACHED, ST_ATTACHWAIT, ST_ATTACHED} st_t;
  st_t       state;
  logic [6:0] deb_cnt;              // attach debounce counter
  logic [3:0] rel_cnt;              // detach debounce counter
  logic       orient_q;
  logic       role_src_q;           // 1 = source/DFP, 0 = sink/UFP
  logic       fault_sticky;
  logic [2:0] int_sticky;           // {fault, detach, attach}

  // exactly one CC pin pulled down by a sink -> candidate attach
  wire cc1_rd   = (cc1 == CC_RD);
  wire cc2_rd   = (cc2 == CC_RD);
  wire attach_c = cc1_rd ^ cc2_rd;
  // active CC pin released -> candidate detach
  wire active_open = orient_q ? (cc2 == CC_OPEN) : (cc1 == CC_OPEN);
  // abnormal level on either pin -> fault
  wire fault_det = (cc1 == 2'b11) || (cc2 == 2'b11);

  wire entering_attached = (state == ST_ATTACHWAIT) &&
                           (deb_cnt == DEBOUNCE_ATTACH-1) && attach_c;
  wire leaving_attached  = (state == ST_ATTACHED) &&
                           (rel_cnt == DEBOUNCE_DETACH-1) && active_open;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= ST_UNATTACHED;
      deb_cnt      <= '0;
      rel_cnt      <= '0;
      orient_q     <= 1'b0;
      role_src_q   <= 1'b1;         // default role: source/DFP
      fault_sticky <= 1'b0;
      int_sticky   <= '0;
    end else begin
      // ---- FSM --------------------------------------------------
      case (state)
        ST_UNATTACHED: begin
          rel_cnt <= '0;
          if (attach_c && !fault_det) begin
            state    <= ST_ATTACHWAIT;
            deb_cnt  <= '0;
            orient_q <= cc2_rd;     // cc2 wired -> flipped plug
          end
        end
        ST_ATTACHWAIT: begin
          if (!attach_c) begin
            state <= ST_UNATTACHED; // glitch rejected by debounce
          end else if (deb_cnt == DEBOUNCE_ATTACH-1) begin
            state <= ST_ATTACHED;
          end else begin
            deb_cnt <= deb_cnt + 7'd1;
          end
        end
        ST_ATTACHED: begin
          if (active_open) begin
            if (rel_cnt == DEBOUNCE_DETACH-1) begin
              state   <= ST_UNATTACHED;
              rel_cnt <= '0;
            end else begin
              rel_cnt <= rel_cnt + 4'd1;
            end
          end else begin
            rel_cnt <= '0;
          end
        end
        default: state <= ST_UNATTACHED;
      endcase
      // ---- sticky events ----------------------------------------
      if (entering_attached) int_sticky[0] <= 1'b1;
      if (leaving_attached)  int_sticky[1] <= 1'b1;
      if (fault_det) begin
        fault_sticky  <= 1'b1;
        int_sticky[2] <= 1'b1;
      end
      // ---- register writes --------------------------------------
      if (reg_wr) begin
        case (reg_addr)
          3'd1: role_src_q   <= reg_wdata[0];              // ROLE_CTRL
          3'd2: if (reg_wdata[0]) fault_sticky <= 1'b0;    // FAULT_STAT W1C
          3'd3: int_sticky   <= int_sticky & ~reg_wdata[2:0]; // INT_STAT W1C
          default: ;                                       // RO regs ignored
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // outputs
  // ------------------------------------------------------------------
  wire attached_w = (state == ST_ATTACHED);
  assign attached    = attached_w;
  assign orientation = orient_q;
  assign vbus_en     = attached_w && role_src_q;
  assign irq         = fault_det | (|int_sticky);

  // ------------------------------------------------------------------
  // register read port (combinational, valid while reg_rd=1)
  // ------------------------------------------------------------------
  always @* begin
    case (reg_addr)
      3'd0:    reg_rdata = {attached_w, orient_q, state, cc2, cc1};
      3'd1:    reg_rdata = {7'b0, role_src_q};
      3'd2:    reg_rdata = {7'b0, fault_sticky};
      3'd3:    reg_rdata = {5'b0, int_sticky};
      3'd4:    reg_rdata = DEBOUNCE_ATTACH[7:0];
      3'd5:    reg_rdata = {7'b0, orient_q};
      3'd6:    reg_rdata = {7'b0, vbus_en};
      3'd7:    reg_rdata = 8'hC7;
      default: reg_rdata = 8'h00;
    endcase
  end

  // keep framework parameters visibly used (no functional effect)
  wire unused = &{1'b0, DW[0], AW[0], reg_rd};

endmodule
