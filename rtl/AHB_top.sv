// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// AHB-Lite slave -- address/data phase pipelined, BUSY/IDLE, wait states,
// two-cycle ERROR response, 256x32 register file
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
// Address map (byte addresses):
//   0x000-0x3FF : fast region, zero wait state   (256 x 32 register file)
//   0x400-0x7FF : slow region, one wait state    (same register file)
//   0x800+      : reserved  -> two-cycle ERROR response + irq event
// ============================================================================
module AHB_top #(
  parameter int DW    = 32,   // data width
  parameter int AW    = 32,   // address width
  parameter int DEPTH = 256   // register-file depth (words)
)(
  input  logic           clk,
  input  logic           rst_n,
  // AHB-Lite slave interface
  input  logic           hsel,        // slave select
  input  logic [1:0]     htrans,      // 00 IDLE, 01 BUSY, 10 NONSEQ, 11 SEQ
  input  logic [AW-1:0]  haddr,
  input  logic           hwrite,
  input  logic [2:0]     hsize,       // only 32-bit word (3'b010) supported
  input  logic [DW-1:0]  hwdata,
  output logic [DW-1:0]  hrdata,
  input  logic           hready,      // bus ready (previous data phase done)
  output logic           hreadyout,   // this slave's data-phase completion
  output logic           hresp,       // 0 = OKAY, 1 = ERROR (AHB-Lite)
  output logic           irq          // protocol/address error event
);

  localparam logic [1:0] HTRANS_IDLE   = 2'b00;
  localparam logic [1:0] HTRANS_BUSY   = 2'b01;
  localparam logic [1:0] HTRANS_NONSEQ = 2'b10;
  localparam logic [1:0] HTRANS_SEQ    = 2'b11;

  // data-phase FSM
  typedef enum logic [1:0] {
    S_NORM,   // first (or only) data-phase cycle; may complete immediately
    S_SLOW,   // completing cycle of a slow-region transfer (wait inserted)
    S_ERR2    // second cycle of the two-cycle ERROR response
  } state_t;
  state_t state;

  (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];

  // pipelined address-phase registers (captured while hready & hsel & htrans[1])
  logic          valid_q;   // a real transfer occupies the data phase
  logic          write_q;
  logic [AW-1:0] addr_q;
  logic          slow_q;    // target in slow region
  logic          err_q;     // target in reserved region

  // ------------------------------------------------------------------
  // address-phase capture (overlaps the previous data phase: pipelining)
  // ------------------------------------------------------------------
  wire cap = hsel & hready & htrans[1];   // NONSEQ or SEQ accepted this cycle

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      write_q <= 1'b0;
      addr_q  <= '0;
      slow_q  <= 1'b0;
      err_q   <= 1'b0;
    end else if (hreadyout && cap) begin
      // sample next transfer exactly when the current data phase completes
      valid_q <= 1'b1;
      write_q <= hwrite;
      addr_q  <= haddr;
      slow_q  <= (haddr[11:10] == 2'b01);
      err_q   <=  haddr[11];              // 0x800.. reserved
    end else if (hreadyout) begin
      valid_q <= 1'b0;                    // BUSY / IDLE / no new transfer
    end
  end

  // ------------------------------------------------------------------
  // data-phase FSM
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S_NORM;
    else
      case (state)
        S_NORM : state <= (valid_q && err_q)            ? S_ERR2 :
                          (valid_q && slow_q)           ? S_SLOW : S_NORM;
        S_SLOW : state <= S_NORM;
        S_ERR2 : state <= S_NORM;
        default: state <= S_NORM;
      endcase
  end

  // ------------------------------------------------------------------
  // register-file write at data-phase completion
  // ------------------------------------------------------------------
  wire complete = hreadyout & valid_q & ~err_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else if (complete && write_q) begin
      mem[addr_q[9:2]] <= hwdata;
    end
  end

  // ------------------------------------------------------------------
  // outputs
  // ------------------------------------------------------------------
  always_comb begin
    unique case (state)
      S_NORM : begin
        hresp     = valid_q && err_q;                 // first ERROR cycle
        hreadyout = ~(valid_q && (err_q || slow_q));  // wait / error cycle 1
      end
      S_SLOW : begin
        hresp     = 1'b0;
        hreadyout = 1'b1;                             // slow transfer completes
      end
      S_ERR2 : begin
        hresp     = 1'b1;                             // second ERROR cycle
        hreadyout = 1'b1;
      end
      default: begin
        hresp     = 1'b0;
        hreadyout = 1'b1;
      end
    endcase
  end

  // read data: combinational from register file, stable through wait states
  assign hrdata = (valid_q && !write_q && !err_q) ? mem[addr_q[9:2]] : '0;

  // protocol/address error event (first cycle of ERROR response)
  assign irq = (state == S_NORM) && valid_q && err_q;

  // hsize: word transfers assumed; hsize[2:0] retained for interface fidelity
  wire unused = &{1'b0, hsize, HTRANS_IDLE, HTRANS_BUSY, HTRANS_NONSEQ,
                  HTRANS_SEQ, addr_q[AW-1:12], 1'b0};

endmodule
