// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// APB3 slave -- real two-phase IDLE/SETUP/ACCESS protocol, pready wait
// states (slow region), pslverr on reserved region, 256x32 register file
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
// Address map (byte addresses):
//   0x000-0x3FF : fast region, zero wait state   (256 x 32 register file)
//   0x400-0x7FF : slow region, one wait state    (same register file)
//   0x800+      : reserved  -> pslverr at completion + irq event
// ============================================================================
module APB_top #(
  parameter int DW    = 32,   // data width
  parameter int AW    = 32,   // address width
  parameter int DEPTH = 256   // register-file depth (words)
)(
  input  logic          clk,
  input  logic          rst_n,
  // APB3 slave interface
  input  logic          psel,
  input  logic          penable,
  input  logic [AW-1:0] paddr,
  input  logic          pwrite,
  input  logic [DW-1:0] pwdata,
  output logic [DW-1:0] prdata,
  output logic          pready,
  output logic          pslverr,
  output logic          irq       // protocol error event (pslverr completion)
);

  // APB phases: APB_IDLE covers "no transfer" and the SETUP cycle
  // (psel=1, penable=0); APB_ACCESS covers the ACCESS cycles (penable=1).
  // Back-to-back transfers re-enter the SETUP condition immediately after
  // a completing ACCESS, so no phantom transaction is ever started.
  typedef enum logic {APB_IDLE, APB_ACCESS} state_t;
  state_t state;

  (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];

  // transfer attributes captured during the SETUP cycle
  logic          write_q;
  logic [AW-1:0] addr_q;
  logic          slow_q;    // slow region: insert one wait state
  logic          err_q;     // reserved region: pslverr
  logic          waited_q;  // wait state already inserted

  wire setup_cycle   = (state == APB_IDLE) && psel && !penable;
  wire access        = (state == APB_ACCESS);
  wire access_finish = access && penable && pready;  // completing this cycle

  // ------------------------------------------------------------------
  // APB FSM: IDLE --(psel & !penable)--> ACCESS --(pready)--> IDLE
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= APB_IDLE;
    else
      case (state)
        APB_IDLE   : state <= setup_cycle   ? APB_ACCESS : APB_IDLE;
        APB_ACCESS : state <= access_finish ? APB_IDLE   : APB_ACCESS;
        default    : state <= APB_IDLE;
      endcase
  end

  // ------------------------------------------------------------------
  // capture transfer attributes at the end of the SETUP cycle
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      write_q  <= 1'b0;
      addr_q   <= '0;
      slow_q   <= 1'b0;
      err_q    <= 1'b0;
      waited_q <= 1'b0;
    end else if (setup_cycle) begin
      write_q  <= pwrite;
      addr_q   <= paddr;
      slow_q   <= (paddr[11:10] == 2'b01);
      err_q    <=  paddr[11];
      waited_q <= 1'b0;
    end else if (access && penable && !pready) begin
      waited_q <= 1'b1;                                   // wait cycle spent
    end
  end

  // ------------------------------------------------------------------
  // register-file write at ACCESS completion
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else if (access_finish && write_q && !err_q) begin
      mem[addr_q[9:2]] <= pwdata;
    end
  end

  // ------------------------------------------------------------------
  // outputs
  // ------------------------------------------------------------------
  // pready: low during the first ACCESS cycle of a slow-region transfer
  assign pready  = access && penable && !(slow_q && !waited_q);
  // pslverr: only valid in the final ACCESS cycle (pready high)
  assign pslverr = access_finish && err_q;
  // read data: valid during ACCESS of a read transfer
  assign prdata  = (access && !write_q && !err_q) ? mem[addr_q[9:2]] : '0;
  // protocol error event
  assign irq     = access_finish && err_q;

endmodule
