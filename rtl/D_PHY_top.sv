// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI D-PHY lane-pair (clock lane + data lane) TX with same-lane RX decoder
// Implementation scope:
//   * LP mode line levels on data lane (lp_p/lp_n): LP-11 STOP, LP-01
//     HS-Request, LP-00 Sync/Bridge, LP-10 used by escape entry/exit.
//     Simplification: each LP state / line bit lasts exactly 1 clk cycle.
//   * HS mode: SoT sequence LP-11 -> LP-01 -> LP-00 -> HS-0, sync byte
//     8'hB8 sent LSB-first (wire pattern 00011101), payload bytes LSB-first
//     on differential hs_p/hs_n, EoT = last payload bit inverted for one
//     bit time + one bit of the last level (HS-0/1), then LP-11.
//   * Escape mode: entry LP-10 -> LP-00 -> LP-01 -> LP-00, then 8-bit
//     escape command LSB-first (LP-10 = '1', LP-00 = '0'; the real
//     spaced-one-hot encoding is simplified to 1 bit/clk, see MIPI D-PHY
//     spec 8.4). Commands: LPDT 8'h87 (followed by LPDT data bytes, same
//     1 bit/clk encoding, LP-01 space marks end of data), ULPS 8'h78
//     (lines held LP-00 until esc_release), Trigger-Reset 8'h46 (4-clk
//     Mark-1 LP-00 then exit). Exit: [LP-01 space for LPDT] -> LP-10 ->
//     LP-11.
//   * Clock lane follows the data-lane HS sequence simultaneously (real
//     PHY starts the HS clock earlier; simplified) and toggles a
//     differential HS clock during the HS burst.
//   * RX side decodes the same lane (TB wires TX pads back to RX inputs):
//     HS sync check + payload byte reassembly, escape entry/command/LPDT
//     decode, ULPS detect. Protocol violations (bad HS sync, unknown
//     escape command, illegal LP sequence) raise sticky irq.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module D_PHY_top #(
  parameter int DW = 32,        // retained framework parameter (data width)
  parameter int AW = 32         // retained framework parameter (address width)
)(
  input  logic       clk,
  input  logic       rst_n,
  output logic       irq,         // sticky protocol-error flag (RX decoder)
  input  logic       irq_clear,   // pulse to clear irq

  // ---- HS transmit byte-stream interface ----
  input  logic       hs_req,      // pulse: start an HS burst (SoT)
  input  logic [7:0] hs_tx_data,  // payload byte
  input  logic       hs_tx_valid,
  output logic       hs_tx_ready, // 1-deep skid buffer free
  output logic       hs_tx_done,  // pulse: burst finished, lane back in LP-11

  // ---- escape-mode interface ----
  input  logic       esc_req,     // pulse: enter escape mode with esc_cmd
  input  logic [7:0] esc_cmd,     // 8'h87 LPDT / 8'h78 ULPS / 8'h46 Trigger
  input  logic       esc_release, // pulse: exit ULPS
  input  logic [7:0] lpdt_data,   // LPDT payload byte (after cmd 8'h87)
  input  logic       lpdt_valid,
  input  logic       lpdt_last,   // marks final LPDT byte
  output logic       lpdt_ready,  // byte accepted at LPDT byte boundary
  output logic       esc_done,    // pulse: escape exit complete (LP-11)

  // ---- data lane TX pads ----
  output logic       d_lp_p,
  output logic       d_lp_n,
  output logic       d_hs_p,
  output logic       d_hs_n,
  output logic       d_hs_en,     // HS driver enable (LP levels valid when 0)

  // ---- clock lane pads ----
  output logic       c_lp_p,
  output logic       c_lp_n,
  output logic       c_hs_p,
  output logic       c_hs_n,
  output logic       c_hs_en,

  // ---- same-lane RX inputs (loopback in TB) ----
  input  logic       r_lp_p,
  input  logic       r_lp_n,
  input  logic       r_hs_p,
  input  logic       r_hs_n,
  input  logic       r_hs_en,

  // ---- RX decode outputs ----
  output logic       rx_hs_active,  // HS burst decode in progress
  output logic [7:0] rx_data,       // decoded byte (HS payload or LPDT)
  output logic       rx_data_valid,
  output logic [7:0] rx_esc_cmd,    // decoded escape command
  output logic       rx_esc_valid,
  output logic       rx_ulps        // lane observed in ULPS
);

  // ------------------------------------------------------------------
  // constants
  // ------------------------------------------------------------------
  localparam logic [7:0] HS_SYNC   = 8'hB8; // wire pattern 00011101 LSB-first
  localparam logic [7:0] ESC_LPDT  = 8'h87;
  localparam logic [7:0] ESC_ULPS  = 8'h78;
  localparam logic [7:0] ESC_TRIG  = 8'h46;

  localparam logic [1:0] LP_00 = 2'b00;     // {p,n}
  localparam logic [1:0] LP_01 = 2'b01;
  localparam logic [1:0] LP_10 = 2'b10;
  localparam logic [1:0] LP_11 = 2'b11;

  // ------------------------------------------------------------------
  // TX FSM
  // ------------------------------------------------------------------
  typedef enum logic [4:0] {
    T_STOP,                        // LP-11
    T_HS_REQ,                      // LP-01 HS-Request
    T_HS_SYNC0,                    // LP-00 Sync / bridge
    T_HS_HS0,                      // HS-0 (differential)
    T_HS_SYNC,                     // 8-bit sync 8'hB8 LSB-first
    T_HS_DATA,                     // payload bytes LSB-first
    T_HS_EOT1,                     // last bit inverted
    T_HS_EOT2,                     // last bit held (HS-0/1)
    T_ESC_E1,                      // LP-10
    T_ESC_E2,                      // LP-00
    T_ESC_E3,                      // LP-01
    T_ESC_E4,                      // LP-00
    T_ESC_CMD,                     // 8-bit escape command
    T_LPDT,                        // LPDT data bytes
    T_ULPS,                        // ULPS Mark-1 hold (LP-00)
    T_TRIG,                        // Trigger Mark-1 hold (LP-00)
    T_EX_SP,                       // exit space  LP-01 (LPDT only)
    T_EX_10                        // exit Mark-1 LP-10 -> LP-11
  } tstate_t;

  tstate_t   tstate;
  logic [2:0] tbit_cnt;
  logic [7:0] tshift;
  logic       tlast_bit;
  logic [2:0] trig_cnt;
  logic [7:0] esc_cmd_q;
  logic       buf_valid;           // 1-deep payload skid buffer
  logic [7:0] buf_data;
  logic       buf_last;            // lpdt_last captured with buf_data
  logic       cur_last;            // last-flag of the byte being shifted
  logic       clk_hs;              // HS clock lane toggle

  assign hs_tx_ready = ~buf_valid &
                       ((tstate == T_HS_SYNC) | (tstate == T_HS_DATA));
  // LPDT bytes may be loaded while the escape command is still going out
  // (so the first byte is ready at the LPDT phase boundary).
  assign lpdt_ready  = ~buf_valid &
                       ((tstate == T_LPDT) |
                        ((tstate == T_ESC_CMD) & (esc_cmd_q == ESC_LPDT)));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate     <= T_STOP;
      tbit_cnt   <= 3'd0;
      tshift     <= 8'd0;
      tlast_bit  <= 1'b0;
      trig_cnt   <= 3'd0;
      esc_cmd_q  <= 8'd0;
      buf_valid  <= 1'b0;
      buf_data   <= 8'd0;
      buf_last   <= 1'b0;
      cur_last   <= 1'b0;
      clk_hs     <= 1'b0;
      hs_tx_done <= 1'b0;
      esc_done   <= 1'b0;
    end else begin
      hs_tx_done <= 1'b0;
      esc_done   <= 1'b0;

      // payload skid buffer fill (HS byte stream / LPDT byte)
      if (hs_tx_valid && hs_tx_ready) begin
        buf_valid <= 1'b1;
        buf_data  <= hs_tx_data;
      end else if (lpdt_valid && lpdt_ready) begin
        buf_valid <= 1'b1;
        buf_data  <= lpdt_data;
        buf_last  <= lpdt_last;
      end

      // HS clock lane toggle while in HS burst
      if (tstate == T_HS_HS0 || tstate == T_HS_SYNC ||
          tstate == T_HS_DATA || tstate == T_HS_EOT1 ||
          tstate == T_HS_EOT2)
        clk_hs <= ~clk_hs;
      else
        clk_hs <= 1'b0;

      case (tstate)
        // ---------------- idle / request ----------------
        T_STOP: begin
          if (hs_req)       tstate <= T_HS_REQ;
          else if (esc_req) begin
            tstate    <= T_ESC_E1;
            esc_cmd_q <= esc_cmd;
          end
        end

        // ---------------- HS burst ----------------
        T_HS_REQ:   tstate <= T_HS_SYNC0;
        T_HS_SYNC0: tstate <= T_HS_HS0;
        T_HS_HS0: begin
          tstate   <= T_HS_SYNC;
          tbit_cnt <= 3'd0;
          tshift   <= HS_SYNC;
        end
        T_HS_SYNC: begin
          tlast_bit <= tshift[0];
          tshift    <= {1'b0, tshift[7:1]};
          if (tbit_cnt == 3'd7) begin
            tbit_cnt <= 3'd0;
            if (buf_valid) begin
              tstate    <= T_HS_DATA;
              tshift    <= buf_data;
              buf_valid <= 1'b0;
            end else begin
              tstate <= T_HS_EOT1;   // empty payload: straight to EoT
            end
          end else begin
            tbit_cnt <= tbit_cnt + 3'd1;
          end
        end
        T_HS_DATA: begin
          tlast_bit <= tshift[0];
          tshift    <= {1'b0, tshift[7:1]};
          if (tbit_cnt == 3'd7) begin
            tbit_cnt <= 3'd0;
            if (buf_valid) begin
              tshift    <= buf_data;  // next payload byte
              buf_valid <= 1'b0;
            end else begin
              tstate <= T_HS_EOT1;    // host done -> EoT
            end
          end else begin
            tbit_cnt <= tbit_cnt + 3'd1;
          end
        end
        T_HS_EOT1: tstate <= T_HS_EOT2;
        T_HS_EOT2: begin
          tstate     <= T_STOP;
          hs_tx_done <= 1'b1;
        end

        // ---------------- escape entry ----------------
        T_ESC_E1: tstate <= T_ESC_E2;
        T_ESC_E2: tstate <= T_ESC_E3;
        T_ESC_E3: tstate <= T_ESC_E4;
        T_ESC_E4: begin
          tstate   <= T_ESC_CMD;
          tbit_cnt <= 3'd0;
          tshift   <= esc_cmd_q;
        end
        T_ESC_CMD: begin
          tshift <= {1'b0, tshift[7:1]};
          if (tbit_cnt == 3'd7) begin
            tbit_cnt <= 3'd0;
            case (esc_cmd_q)
              ESC_LPDT: tstate <= T_LPDT;
              ESC_ULPS: tstate <= T_ULPS;
              ESC_TRIG: begin
                tstate   <= T_TRIG;
                trig_cnt <= 3'd0;
              end
              default:  tstate <= T_EX_10; // host sent unknown cmd: just exit
            endcase
          end else begin
            tbit_cnt <= tbit_cnt + 3'd1;
          end
        end

        // ---------------- LPDT ----------------
        T_LPDT: begin
          if (tbit_cnt == 3'd0) begin
            // byte boundary: bit 0 of the buffered byte goes out this cycle
            if (buf_valid) begin
              tshift    <= {1'b0, buf_data[7:1]};
              cur_last  <= buf_last;
              buf_valid <= 1'b0;
              tbit_cnt  <= 3'd1;
            end else begin
              // host underrun: this cycle already drives the LP-01 exit
              // space on the pads, so skip T_EX_SP and go straight to LP-10
              tstate <= T_EX_10;
            end
          end else begin
            tshift <= {1'b0, tshift[7:1]};
            if (tbit_cnt == 3'd7) begin
              tbit_cnt <= 3'd0;
              if (cur_last) tstate <= T_EX_SP;  // final byte done -> exit
            end else begin
              tbit_cnt <= tbit_cnt + 3'd1;
            end
          end
        end

        // ---------------- ULPS / Trigger hold ----------------
        T_ULPS: if (esc_release) tstate <= T_EX_10;
        T_TRIG: begin
          if (trig_cnt == 3'd3) tstate <= T_EX_10;
          else                  trig_cnt <= trig_cnt + 3'd1;
        end

        // ---------------- escape exit ----------------
        T_EX_SP: tstate <= T_EX_10;
        T_EX_10: begin
          tstate   <= T_STOP;
          esc_done <= 1'b1;
        end

        default: tstate <= T_STOP;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // TX pad drivers
  // ------------------------------------------------------------------
  always_comb begin
    // defaults: LP-11 stop, HS drivers off
    d_lp_p  = 1'b1;
    d_lp_n  = 1'b1;
    d_hs_p  = 1'b0;
    d_hs_n  = 1'b1;
    d_hs_en = 1'b0;
    c_lp_p  = 1'b1;
    c_lp_n  = 1'b1;
    c_hs_p  = clk_hs;
    c_hs_n  = ~clk_hs;
    c_hs_en = 1'b0;
    case (tstate)
      T_HS_REQ:   {d_lp_p, d_lp_n} = LP_01;
      T_HS_SYNC0: {d_lp_p, d_lp_n} = LP_00;
      T_HS_HS0: begin
        d_hs_en = 1'b1;
        d_hs_p  = 1'b0;             // HS-0
        d_hs_n  = 1'b1;
        c_hs_en = 1'b1;
      end
      T_HS_SYNC, T_HS_DATA: begin
        d_hs_en = 1'b1;
        d_hs_p  = tshift[0];
        d_hs_n  = ~tshift[0];
        c_hs_en = 1'b1;
      end
      T_HS_EOT1: begin
        d_hs_en = 1'b1;
        d_hs_p  = ~tlast_bit;       // last bit inverted
        d_hs_n  = tlast_bit;
        c_hs_en = 1'b1;
      end
      T_HS_EOT2: begin
        d_hs_en = 1'b1;
        d_hs_p  = tlast_bit;        // HS-0/1 hold
        d_hs_n  = ~tlast_bit;
        c_hs_en = 1'b1;
      end
      T_ESC_E1: {d_lp_p, d_lp_n} = LP_10;
      T_ESC_E2: {d_lp_p, d_lp_n} = LP_00;
      T_ESC_E3: {d_lp_p, d_lp_n} = LP_01;
      T_ESC_E4: {d_lp_p, d_lp_n} = LP_00;
      T_ESC_CMD:
        {d_lp_p, d_lp_n} = tshift[0] ? LP_10 : LP_00;
      T_LPDT:
        // bit 0 of a freshly loaded byte is driven in the load cycle;
        // an empty buffer at a byte boundary drives the LP-01 exit space
        if (lpdt_exit) {d_lp_p, d_lp_n} = LP_01;
        else           {d_lp_p, d_lp_n} = lpdt_bit0 ? LP_10 : LP_00;
      T_ULPS, T_TRIG: {d_lp_p, d_lp_n} = LP_00;
      T_EX_SP: {d_lp_p, d_lp_n} = LP_01;
      T_EX_10: {d_lp_p, d_lp_n} = LP_10;
      default: ;
    endcase
  end

  // ------------------------------------------------------------------
  // RX decoder (same-lane loopback)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    R_STOP,
    R_HS1,        // seen LP-01, expect LP-00
    R_HS2,        // seen LP-00, expect HS-0 + hs_en
    R_HS_SYNC,    // 8-bit sync
    R_HS_DATA,    // payload
    R_ESC1,       // seen LP-10, expect LP-00
    R_ESC2,       // seen LP-00, expect LP-01
    R_ESC3,       // seen LP-01, expect LP-00
    R_ESC_CMD,    // 8-bit command
    R_LPDT,       // LPDT bytes
    R_ULPS,       // ULPS hold
    R_TRIG,       // trigger Mark-1 hold
    R_EX1,        // LPDT exit: expect LP-10
    R_EX2,        // exit: expect LP-11
    R_ERR         // resync: wait for LP-11
  } rstate_t;

  rstate_t   rstate;
  logic [2:0] rbit_cnt;
  logic [7:0] rshift;
  logic       err_sticky;

  // current LPDT line level: bit 0 of a freshly loaded byte in the load
  // cycle; an empty buffer at a byte boundary drives the LP-01 exit space
  wire lpdt_bit0 = (tbit_cnt == 3'd0) ? buf_data[0] : tshift[0];
  wire lpdt_exit = (tstate == T_LPDT) & (tbit_cnt == 3'd0) & ~buf_valid;

  wire [1:0] rlp = {r_lp_p, r_lp_n};

  assign irq          = err_sticky;
  assign rx_hs_active = (rstate == R_HS_SYNC) | (rstate == R_HS_DATA);
  assign rx_ulps      = (rstate == R_ULPS);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate        <= R_STOP;
      rbit_cnt      <= 3'd0;
      rshift        <= 8'd0;
      err_sticky    <= 1'b0;
      rx_data       <= 8'd0;
      rx_data_valid <= 1'b0;
      rx_esc_cmd    <= 8'd0;
      rx_esc_valid  <= 1'b0;
    end else begin
      rx_data_valid <= 1'b0;
      rx_esc_valid  <= 1'b0;
      if (irq_clear) err_sticky <= 1'b0;

      case (rstate)
        // ---------------- stop / start detection ----------------
        R_STOP: begin
          if (rlp == LP_01)      rstate <= R_HS1;    // HS request
          else if (rlp == LP_10) rstate <= R_ESC1;   // escape entry
          else if (rlp == LP_00) begin               // illegal from STOP
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end

        // ---------------- HS SoT ----------------
        R_HS1: begin
          if (rlp == LP_00) rstate <= R_HS2;
          else if (rlp != LP_01) begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end
        R_HS2: begin
          if (r_hs_en && r_hs_p == 1'b0 && r_hs_n == 1'b1) begin
            rstate   <= R_HS_SYNC;    // HS-0 consumed
            rbit_cnt <= 3'd0;
          end else begin
            err_sticky <= 1'b1;       // LP-00 not followed by HS-0
            rstate     <= R_ERR;
          end
        end
        R_HS_SYNC: begin
          if (!r_hs_en) begin
            err_sticky <= 1'b1;       // HS aborted during sync
            rstate     <= R_ERR;
          end else begin
            rshift <= {r_hs_p, rshift[7:1]};
            if (rbit_cnt == 3'd7) begin
              rbit_cnt <= 3'd0;
              if ({r_hs_p, rshift[7:1]} == HS_SYNC) begin
                rstate <= R_HS_DATA;
              end else begin
                err_sticky <= 1'b1;   // bad sync byte
                rstate     <= R_ERR;
              end
            end else begin
              rbit_cnt <= rbit_cnt + 3'd1;
            end
          end
        end
        R_HS_DATA: begin
          if (!r_hs_en) begin
            rstate <= R_STOP;         // EoT: partial bits (toggle+hold) dropped
          end else begin
            rshift <= {r_hs_p, rshift[7:1]};
            if (rbit_cnt == 3'd7) begin
              rbit_cnt      <= 3'd0;
              rx_data       <= {r_hs_p, rshift[7:1]};
              rx_data_valid <= 1'b1;
            end else begin
              rbit_cnt <= rbit_cnt + 3'd1;
            end
          end
        end

        // ---------------- escape entry ----------------
        R_ESC1: begin
          if (rlp == LP_00) rstate <= R_ESC2;
          else begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end
        R_ESC2: begin
          if (rlp == LP_01) rstate <= R_ESC3;
          else begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end
        R_ESC3: begin
          if (rlp == LP_00) begin
            rstate   <= R_ESC_CMD;
            rbit_cnt <= 3'd0;
          end else begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end
        R_ESC_CMD: begin
          if (rlp == LP_10 || rlp == LP_00) begin
            rshift <= {r_lp_p, rshift[7:1]};   // LP-10='1', LP-00='0'
            if (rbit_cnt == 3'd7) begin
              rbit_cnt     <= 3'd0;
              rx_esc_cmd   <= {r_lp_p, rshift[7:1]};
              rx_esc_valid <= 1'b1;
              case ({r_lp_p, rshift[7:1]})
                ESC_LPDT: rstate <= R_LPDT;
                ESC_ULPS: rstate <= R_ULPS;
                ESC_TRIG: rstate <= R_TRIG;
                default: begin                 // unknown escape command
                  err_sticky <= 1'b1;
                  rstate     <= R_ERR;
                end
              endcase
            end else begin
              rbit_cnt <= rbit_cnt + 3'd1;
            end
          end else begin
            err_sticky <= 1'b1;                // LP-01/LP-11 inside command
            rstate     <= R_ERR;
          end
        end

        // ---------------- LPDT data ----------------
        R_LPDT: begin
          if (rbit_cnt == 3'd0 && rlp == LP_01) begin
            rstate <= R_EX1;                   // exit space
          end else if (rlp == LP_10 || rlp == LP_00) begin
            rshift <= {r_lp_p, rshift[7:1]};
            if (rbit_cnt == 3'd7) begin
              rbit_cnt      <= 3'd0;
              rx_data       <= {r_lp_p, rshift[7:1]};
              rx_data_valid <= 1'b1;
            end else begin
              rbit_cnt <= rbit_cnt + 3'd1;
            end
          end else begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end

        // ---------------- ULPS / Trigger ----------------
        R_ULPS: begin
          if (rlp == LP_10)      rstate <= R_EX2;
          else if (rlp != LP_00) begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end
        R_TRIG: begin
          if (rlp == LP_10)      rstate <= R_EX2;
          else if (rlp != LP_00) begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end

        // ---------------- escape exit ----------------
        R_EX1: begin
          if (rlp == LP_10) rstate <= R_EX2;
          else begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end
        R_EX2: begin
          if (rlp == LP_11) rstate <= R_STOP;
          else begin
            err_sticky <= 1'b1;
            rstate     <= R_ERR;
          end
        end

        // ---------------- error resync ----------------
        R_ERR: if (rlp == LP_11 && !r_hs_en) rstate <= R_STOP;

        default: rstate <= R_STOP;
      endcase
    end
  end

endmodule
