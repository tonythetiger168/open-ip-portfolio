// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI_DBI__Display_Bus_Interface__top v2.0: MIPI DBI-2 host controller
// (Type A, Type B and Type C options 1 / 3)
// ----------------------------------------------------------------------------
//  - The host issues one transfer per op: a command or data (op_dc = 0 /
//    1), a write or a read (op_rd), 8 or 16 bits. CSX goes low with the
//    first op and high after an op with op_last, for at least one phase.
//  - Type A (Motorola 6800, cfg_type 0): R/WX on wrx, E on rdx. Type B
//    (Intel 8080, cfg_type 1): WRX / RDX low strobes. Both: setup, strobe
//    and hold phases of cfg_tw + 1 PCLK (cfg_tr + 1 for reads); D/CX and
//    the bus (8 or 16 bits, cfg_w16) are valid through all three; read
//    data is taken at the end of the strobe phase.
//  - Type C (serial, SCL idles low, the display samples on the rising
//    edge): option 1 (cfg_type 2) sends the D/CX bit before the 8 data
//    bits, option 3 (cfg_type 3) drives the D/CX pin. Each bit is an SCL
//    low and an SCL high phase of cfg_tw + 1 (cfg_tr + 1 while reading)
//    PCLK. A read clocks in 8 bits (no D/CX bit) on SDA, which the host
//    releases; the first read after a write (or after CSX goes low)
//    first sends cfg_dummy dummy clocks. Read data is sampled as SCL rises.
//  - Read data: rd_valid for one clock with rd_data (8-bit transfers in
//    rd_data[7:0], upper bits 0).
//  Change the configuration only while idle (busy low); the strobe pins
//  take the new type's idle level one clock later.
//  Not implemented: DBI Type C option 2 (8-bit with 16-bit dummy), the
//  Type A clock-synchronous variant, tearing-effect input handling.
// ============================================================================
module MIPI_DBI__Display_Bus_Interface__top (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic [1:0]  cfg_type,        // 0 A, 1 B, 2 C option 1, 3 C option 3
  input  logic        cfg_w16,         // Type A / B 16-bit bus
  input  logic [3:0]  cfg_tw,          // write phase length - 1 (PCLK)
  input  logic [3:0]  cfg_tr,          // read phase length - 1 (PCLK)
  input  logic [1:0]  cfg_dummy,       // Type C dummy clocks before read data
  // ops
  input  logic        op_valid,
  output logic        op_ready,
  input  logic        op_dc,           // 0 command, 1 data / parameter
  input  logic        op_rd,
  input  logic        op_last,         // release CSX after this op
  input  logic [15:0] op_data,
  output logic        rd_valid,
  output logic [15:0] rd_data,
  output logic        busy,
  // Type A / B pins
  output logic        csx,
  output logic        dcx,
  output logic        wrx,             // Type B WRX, Type A R/WX
  output logic        rdx,             // Type B RDX, Type A E
  output logic [15:0] d_o,
  output logic        d_oe,
  input  logic [15:0] d_i,
  // Type C pins
  output logic        scl,
  output logic        sda_o,
  output logic        sda_oe,
  input  logic        sda_i
);
  typedef enum logic [2:0] {S_IDLE, S_SETUP, S_ACT, S_HOLD, S_CLO, S_CHI, S_CSH} st_t;
  st_t         st;
  logic [3:0]  cnt;                      // clocks left in the phase
  logic [3:0]  bits;                     // Type C bits left (dummy included)
  logic [1:0]  dum;                      // Type C dummy clocks left
  logic        o_rd, o_last, prev_rd;      // prev_rd: the last Type C op was a read
  logic [7:0]  sh;                       // Type C bits after the one on SDA
  logic [7:0]  rsh;

  wire        ser = cfg_type[1];
  wire [3:0]  ph = o_rd ? cfg_tr : cfg_tw;
  assign op_ready = st == S_IDLE;
  assign busy = st != S_IDLE || !csx;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st <= S_IDLE; cnt <= '0; bits <= '0; dum <= '0; o_rd <= 1'b0; o_last <= 1'b0;
      prev_rd <= 1'b0; sh <= '0; rsh <= '0; rd_valid <= 1'b0; rd_data <= '0;
      csx <= 1'b1; dcx <= 1'b1; wrx <= 1'b1; rdx <= 1'b1; d_o <= '0; d_oe <= 1'b0;
      scl <= 1'b0; sda_o <= 1'b0; sda_oe <= 1'b0;
    end else begin
      rd_valid <= 1'b0;
      case (st)
        S_IDLE: begin
          // strobe idle levels: Type A E low, Type B RDX high
          rdx <= cfg_type != 2'd0; wrx <= 1'b1;
          if (op_valid) begin
          o_rd <= op_rd; o_last <= op_last;
          csx <= 1'b0;
          cnt <= op_rd ? cfg_tr : cfg_tw;
          if (!ser) begin
            st <= S_SETUP; dcx <= op_dc;
            wrx <= cfg_type == 2'd0 ? op_rd : 1'b1;            // Type A: R/WX
            d_o <= op_rd ? 16'd0 : (cfg_w16 ? op_data : {8'd0, op_data[7:0]});
            d_oe <= !op_rd;
          end else begin
            st <= S_CLO;
            if (cfg_type == 2'd3) dcx <= op_dc;
            // option 1 writes start with the D/CX bit
            sh <= cfg_type == 2'd2 ? op_data[7:0] : {op_data[6:0], 1'b0};
            bits <= cfg_type == 2'd2 && !op_rd ? 4'd9 : 4'd8;
            dum <= op_rd && (!prev_rd || csx) ? cfg_dummy : 2'd0;
            sda_oe <= !op_rd;
            sda_o <= op_rd ? 1'b0 : (cfg_type == 2'd2 ? op_dc : op_data[7]);
          end
          end
        end
        // ---- Type A / B
        S_SETUP: if (cnt != 4'd0) cnt <= cnt - 4'd1;
          else begin
            st <= S_ACT; cnt <= ph;
            if (cfg_type == 2'd0) rdx <= 1'b1;                 // E high
            else if (o_rd) rdx <= 1'b0;
            else wrx <= 1'b0;
          end
        S_ACT: if (cnt != 4'd0) cnt <= cnt - 4'd1;
          else begin
            st <= S_HOLD; cnt <= ph;
            if (cfg_type == 2'd0) rdx <= 1'b0;
            else begin rdx <= 1'b1; wrx <= 1'b1; end
            if (o_rd) begin rd_valid <= 1'b1; rd_data <= cfg_w16 ? d_i : {8'd0, d_i[7:0]}; end
          end
        S_HOLD: if (cnt != 4'd0) cnt <= cnt - 4'd1;
          else begin
            d_oe <= 1'b0;
            if (cfg_type == 2'd0) wrx <= 1'b1;
            if (o_last) begin st <= S_CSH; cnt <= ph; csx <= 1'b1; end
            else st <= S_IDLE;
          end
        // ---- Type C
        S_CLO: if (cnt != 4'd0) cnt <= cnt - 4'd1;
          else begin
            st <= S_CHI; cnt <= ph; scl <= 1'b1;
            if (o_rd) rsh <= {rsh[6:0], sda_i};          // dummy bits shift out
          end
        S_CHI: if (cnt != 4'd0) cnt <= cnt - 4'd1;
          else begin
            scl <= 1'b0; cnt <= ph;
            if (dum != 2'd0) begin dum <= dum - 2'd1; st <= S_CLO; end
            else if (bits != 4'd1) begin
              bits <= bits - 4'd1; st <= S_CLO;
              sh <= {sh[6:0], 1'b0};
              if (!o_rd) sda_o <= sh[7];
            end else begin
              prev_rd <= o_rd; sda_oe <= 1'b0;
              if (o_rd) begin rd_valid <= 1'b1; rd_data <= {8'd0, rsh}; end
              if (o_last) begin st <= S_CSH; csx <= 1'b1; end
              else st <= S_IDLE;
            end
          end
        default: if (cnt != 4'd0) cnt <= cnt - 4'd1;           // S_CSH
          else st <= S_IDLE;
      endcase
    end
endmodule
