// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// OCP protocol -- OCP-IP 3.0 slave (MCmd/MAddr/MData -> SCmdAccept/SData/SResp)
// Scope: basic data-handshake subset of OCP-IP:
//   - MCmd: IDLE=0 / WR=1 / RD=2 / WRNP=5 (posted write, no response)
//   - configurable command-accept latency (ACCEPT_DLY = 0 or 1)
//   - fixed 2-cycle DVA response latency for WR/RD, SData valid with DVA
//   - MByteEn partial-write merge, MThreadID echoed on SThreadID
//   - 256x32 register file (1 KiB, word aligned); accesses outside
//     0x000..0x3FC or misaligned -> SResp=ERR + irq pulse
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module OCP_top #(
  parameter int DW         = 32,   // data width
  parameter int AW         = 32,   // address width
  parameter int DEPTH      = 256,  // internal register-file depth (words)
  parameter int ACCEPT_DLY = 1     // SCmdAccept latency: 0=same cycle, 1=next cycle
)(
  input  logic             clk,
  input  logic             rst_n,
  // OCP request phase (driven by master)
  input  logic [2:0]       mcmd,       // 0=IDLE 1=WR 2=RD 5=WRNP
  input  logic [AW-1:0]    maddr,
  input  logic [DW-1:0]    mdata,
  input  logic [DW/8-1:0]  mbyteen,
  input  logic [1:0]       mthreadid,
  // OCP response phase (driven by this slave)
  output logic             scmdaccept,
  output logic [DW-1:0]    sdata,
  output logic [1:0]       sresp,      // 0=NULL 1=DVA 2=ERR
  output logic [1:0]       sthreadid,
  output logic             irq
);

  // OCP command / response encodings
  localparam logic [2:0] MCMD_IDLE = 3'b000;
  localparam logic [2:0] MCMD_WR   = 3'b001;
  localparam logic [2:0] MCMD_RD   = 3'b010;
  localparam logic [2:0] MCMD_WRNP = 3'b101;
  localparam logic [1:0] SRESP_NULL = 2'b00;
  localparam logic [1:0] SRESP_DVA  = 2'b01;
  localparam logic [1:0] SRESP_ERR  = 2'b10;

  typedef enum logic [1:0] {S_IDLE, S_ACCEPT, S_LAT, S_RESP} state_t;
  state_t state;

  // 256x32 register file
  (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];

  // captured request
  logic [7:0]    idx_q;       // word index maddr[9:2]
  logic          rd_q;        // 1 = RD, 0 = WR
  logic          err_q;       // request targets reserved/misaligned space
  logic [1:0]    thread_q;
  logic [DW-1:0] rdata_q;

  logic          cmd_valid;
  logic          addr_bad;
  logic          accept;

  assign cmd_valid = (mcmd != MCMD_IDLE);
  // valid space: 0x000..0x3FC, word aligned
  assign addr_bad  = (maddr[AW-1:10] != '0) || (maddr[1:0] != 2'b00);

  // command accept handshake
  generate
    if (ACCEPT_DLY == 0) begin : g_accept0
      assign scmdaccept = (state == S_IDLE) && cmd_valid;
    end else begin : g_accept1
      assign scmdaccept = (state == S_ACCEPT);
    end
  endgenerate
  assign accept = scmdaccept && cmd_valid;

  // ------------------------------------------------------------------
  // sequential: FSM + request capture + register-file write
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      idx_q    <= '0;
      rd_q     <= 1'b0;
      err_q    <= 1'b0;
      thread_q <= 2'b00;
      rdata_q  <= '0;
      irq      <= 1'b0;
    end else begin
      irq <= 1'b0;   // default: single-cycle pulse
      case (state)
        S_IDLE: begin
          if (cmd_valid) begin
            if (ACCEPT_DLY == 0) begin
              // same-cycle accept: capture now
              idx_q    <= maddr[9:2];
              rd_q     <= (mcmd == MCMD_RD);
              err_q    <= addr_bad;
              thread_q <= mthreadid;
              rdata_q  <= mem[maddr[9:2]];
              if (mcmd == MCMD_WRNP) begin
                if (addr_bad) irq <= 1'b1;          // posted write to reserved space
                state <= S_IDLE;                    // posted: no response phase
              end else begin
                state <= S_LAT;
                if (addr_bad) irq <= 1'b1;
              end
            end else begin
              state <= S_ACCEPT;                    // accept one cycle later
            end
          end
        end
        S_ACCEPT: begin
          // scmdaccept is high this cycle; capture the request
          idx_q    <= maddr[9:2];
          rd_q     <= (mcmd == MCMD_RD);
          err_q    <= addr_bad;
          thread_q <= mthreadid;
          rdata_q  <= mem[maddr[9:2]];
          if (mcmd == MCMD_WRNP) begin
            if (addr_bad) irq <= 1'b1;
            state <= S_IDLE;                        // posted: no response phase
          end else begin
            state <= S_LAT;
            if (addr_bad) irq <= 1'b1;
          end
        end
        S_LAT:  state <= S_RESP;                    // 2-cycle response latency
        S_RESP: state <= S_IDLE;                    // response valid 1 cycle
        default: state <= S_IDLE;
      endcase

      // register-file write with byte-enable merge (at accept time)
      if (accept && !addr_bad &&
          ((mcmd == MCMD_WR) || (mcmd == MCMD_WRNP))) begin
        for (int b = 0; b < DW/8; b++)
          if (mbyteen[b]) mem[maddr[9:2]][b*8 +: 8] <= mdata[b*8 +: 8];
      end
    end
  end

  // ------------------------------------------------------------------
  // response phase outputs
  // ------------------------------------------------------------------
  always_comb begin
    sresp     = (state == S_RESP) ? (err_q ? SRESP_ERR : SRESP_DVA) : SRESP_NULL;
    sdata     = rdata_q;
    sthreadid = thread_q;
  end

endmodule
