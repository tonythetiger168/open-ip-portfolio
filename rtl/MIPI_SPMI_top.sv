// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI SPMI protocol IP -- SPMI slave controller
// Implementation scope (subset of MIPI SPMI v2.0, clk oversamples the bus):
//   - SSC: SDATA rises then falls while SCLK stays low. It is recognised in
//     any state the slave is not driving, so a new SSC aborts a sequence.
//     Bus arbitration is left to the masters; this slave never requests.
//   - Master drives SDATA on SCLK rising edges; the slave samples on SCLK
//     falling edges, and drives read data / ACK on rising edges.
//   - Command frame, 13 bits: SA[3:0] | C[7:0] | P, odd parity per frame.
//       0000BBBB : extended register write  -> A[7:0]|P, BC+1 data frames
//       00010000 : reset     (clears the register file)
//       00010001 : sleep     \
//       00010010 : shutdown   > accepted, no power modes in this slave
//       00010011 : wakeup    /
//       0010BBBB : extended register read   -> A[7:0]|P, bus park,
//                                              BC+1 frames from the slave
//       00110BBB : ext. register write long -> A[15:8]|P, A[7:0]|P, BC+1
//       00111BBB : ext. register read long  -> A[15:8]|P, A[7:0]|P, bus
//                                              park, BC+1 slave frames
//       010AAAAA : register write           -> D[7:0]|P
//       011AAAAA : register read            -> bus park, D[7:0]|P
//       1DDDDDDD : register 0 write          (reg0 <= {0, D[6:0]})
//   - Write response: after a write addressed to USID whose frames all had
//     good parity, the slave drives ACK (1) for one SCLK cycle, then parks
//     the bus (drives 0 for the high phase) and releases it. A sequence with
//     a parity error is abandoned without a response, so the master reads
//     the bus keeper's 0 as NACK. Broadcast writes get no response.
//   - Every read ends with the slave's bus park and release.
//   - SA = USID addresses this slave; SA = 0 (broadcast) is accepted for
//     writes, reset, sleep, shutdown and wakeup. Other SAs are another
//     slave's traffic and are ignored.
//   - 32 x 8 register file; extended accesses auto-increment (the 16-bit
//     address wraps from 0xFFFF to 0); addresses 32..65535 read as 0
//     and ignore writes.
//   - Command/address/data parity errors and unsupported commands (master
//     read/write, authenticate, bus ownership transfer, DDB, ...) abort the
//     sequence and raise irq, which holds until the next SSC.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module MIPI_SPMI_top #(
  parameter logic [3:0] USID = 4'h5   // unique slave ID
)(
  input  logic clk,
  input  logic rst_n,
  input  logic sclk,                  // SPMI clock (driven by the master)
  inout  wire  sdata,                 // SPMI data
  output logic irq                    // protocol error, held until next SSC
);

  typedef enum logic [2:0] {
    S_IDLE,      // wait for SSC
    S_CMD,       // command frame (13 bits)
    S_ADDR,      // extended address frame(s) (9 bits each)
    S_WDATA,     // write data frame(s) (9 bits each)
    S_ACK,       // write: slave drives ACK, then its bus park
    S_BP,        // read: master bus-park cycle
    S_RDATA,     // read: slave drives data frame(s)
    S_PARK       // slave bus park, release on the falling edge
  } state_t;
  state_t state;

  // ------------------------------------------------------------------
  // input synchronizers
  // ------------------------------------------------------------------
  logic [2:0] sclk_d, sdat_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin sclk_d <= '0; sdat_d <= '0; end
    else begin sclk_d <= {sclk_d[1:0], sclk}; sdat_d <= {sdat_d[1:0], sdata}; end
  end
  wire ev_r    = (sclk_d[2:1] == 2'b01);
  wire ev_f    = (sclk_d[2:1] == 2'b10);
  wire din     = sdat_d[1];
  wire sd_r    = (sdat_d[2:1] == 2'b01);
  wire sd_f    = (sdat_d[2:1] == 2'b10);
  wire sclk_lo = !sclk_d[1] && !sclk_d[2];

  logic drv_en, drv_val;
  assign sdata = drv_en ? drv_val : 1'bz;

  // ------------------------------------------------------------------
  // SSC detector: SDATA high pulse with SCLK low throughout
  // ------------------------------------------------------------------
  logic ssc_arm;
  wire  slave_drv = (state == S_RDATA) || (state == S_PARK) || (state == S_ACK);
  wire  ssc = ssc_arm && sd_f && sclk_lo && !slave_drv;

  // ------------------------------------------------------------------
  // datapath
  // ------------------------------------------------------------------
  logic [11:0] sh;
  logic [3:0]  bcnt;
  logic [15:0] addr;
  logic [3:0]  nleft;                       // frames left minus 1 (0..15)
  logic        rd_q;                        // extended access is a read
  logic        long_q;                      // two address frames
  logic        hi_q;                        // high address byte received
  logic        ack_q;                       // respond to this write
  logic        ack_hi;                      // ACK bit already driven
  logic [7:0]  rbyte;
  logic [7:0]  mem [0:31];
  logic        err;
  wire  [12:0] cmd   = {sh, din};
  wire  [8:0]  frm   = {sh[7:0], din};
  wire  [3:0]  f_sa  = cmd[12:9];
  wire  [7:0]  f_c   = cmd[8:1];
  wire         c_ok  = ^cmd;                // odd parity
  wire         f_ok  = ^frm;
  wire         me    = (f_sa == USID);
  wire         bcast = (f_sa == 4'h0);
  wire         in_rf = (addr[15:5] == 11'd0);
  wire  [7:0]  rd_v  = in_rf ? mem[addr[4:0]] : 8'h00;

  assign irq = err;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; ssc_arm <= 1'b0; sh <= '0; bcnt <= '0; addr <= '0;
      nleft <= '0; rd_q <= 1'b0; long_q <= 1'b0; hi_q <= 1'b0; ack_q <= 1'b0;
      ack_hi <= 1'b0; rbyte <= '0; drv_en <= 1'b0; drv_val <= 1'b0; err <= 1'b0;
      for (int i = 0; i < 32; i++) mem[i] <= 8'h00;
    end else begin
      if (!sclk_lo) ssc_arm <= 1'b0;
      else if (sd_r) ssc_arm <= 1'b1;
      if (ssc) begin
        ssc_arm <= 1'b0; state <= S_CMD; bcnt <= '0; sh <= '0; err <= 1'b0;
      end else begin
        case (state)
          S_IDLE: ;
          S_CMD: if (ev_f) begin
            sh <= cmd[11:0];
            bcnt <= bcnt + 4'd1;
            if (bcnt == 4'd12) begin
              bcnt <= '0;
              state <= S_IDLE;
              ack_q <= me; ack_hi <= 1'b0; hi_q <= 1'b0;
              if (!c_ok) err <= 1'b1;
              else if (me || bcast) begin
                if (f_c[7]) begin                          // register 0 write
                  mem[0] <= {1'b0, f_c[6:0]};
                  if (me) state <= S_ACK;
                end else if (f_c[7:5] == 3'b010) begin     // register write
                  addr <= {11'd0, f_c[4:0]}; nleft <= '0; state <= S_WDATA;
                end else if (f_c[7:5] == 3'b011) begin     // register read
                  if (me) begin addr <= {11'd0, f_c[4:0]}; nleft <= '0; state <= S_BP; end
                end else if (f_c[7:4] == 4'b0000 || f_c[7:4] == 4'b0010) begin
                  // extended write / read, BC = C[3:0]
                  nleft <= f_c[3:0]; rd_q <= f_c[5]; long_q <= 1'b0;
                  if (me || !f_c[5]) state <= S_ADDR;
                end else if (f_c[7:4] == 4'b0011) begin
                  // extended write / read long, BC = C[2:0]
                  nleft <= {1'b0, f_c[2:0]}; rd_q <= f_c[3]; long_q <= 1'b1;
                  if (me || !f_c[3]) state <= S_ADDR;
                end else if (f_c[7:2] == 6'b000100) begin  // reset/sleep/shutdown/wakeup
                  if (f_c[1:0] == 2'b00)
                    for (int i = 0; i < 32; i++) mem[i] <= 8'h00;
                end else err <= 1'b1;                      // unsupported
              end
            end
          end
          S_ADDR: if (ev_f) begin
            sh <= {3'd0, frm};
            bcnt <= bcnt + 4'd1;
            if (bcnt == 4'd8) begin
              bcnt <= '0;
              if (!f_ok) begin err <= 1'b1; state <= S_IDLE; end
              else if (long_q && !hi_q) begin
                addr[15:8] <= frm[8:1]; hi_q <= 1'b1;
              end else begin
                if (!long_q) addr[15:8] <= 8'd0;
                addr[7:0] <= frm[8:1];
                state <= rd_q ? S_BP : S_WDATA;
              end
            end
          end
          S_WDATA: if (ev_f) begin
            sh <= {3'd0, frm};
            bcnt <= bcnt + 4'd1;
            if (bcnt == 4'd8) begin
              bcnt <= '0;
              if (!f_ok) begin err <= 1'b1; state <= S_IDLE; end
              else begin
                if (in_rf) mem[addr[4:0]] <= frm[8:1];
                addr <= addr + 16'd1;
                if (nleft == '0) state <= ack_q ? S_ACK : S_IDLE;
                nleft <= nleft - 4'd1;
              end
            end
          end
          S_ACK: if (ev_r) begin
            drv_en <= 1'b1;
            if (!ack_hi) begin drv_val <= 1'b1; ack_hi <= 1'b1; end
            else begin drv_val <= 1'b0; state <= S_PARK; end
          end
          S_BP: if (ev_r) begin                            // bus-park cycle
            bcnt <= '0; rbyte <= rd_v; state <= S_RDATA;
          end
          S_RDATA: if (ev_r) begin
            drv_en <= 1'b1;
            if (bcnt < 4'd8) begin
              drv_val <= rbyte[3'd7 - bcnt[2:0]]; bcnt <= bcnt + 4'd1;
            end else if (bcnt == 4'd8) begin
              drv_val <= ~^rbyte; bcnt <= bcnt + 4'd1;     // odd parity
              addr <= addr + 16'd1;
            end else if (nleft != '0) begin                // next frame
              drv_val <= rd_v[7]; rbyte <= rd_v; bcnt <= 4'd1;
              nleft <= nleft - 4'd1;
            end else begin
              drv_val <= 1'b0; state <= S_PARK;            // slave bus park
            end
          end
          S_PARK: if (ev_f) begin
            drv_en <= 1'b0; state <= S_IDLE;
          end
        endcase
      end
    end
  end

endmodule
