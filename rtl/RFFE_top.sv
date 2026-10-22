// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// RFFE_top v2.0: MIPI RFFE-style bus master (the bus owner)
// ----------------------------------------------------------------------------
// The master drives SCLK and runs one command sequence per host command:
//  - SSC: with SCLK low, SDATA high for one SCLK period, then low; the
//    first SCLK rising edge follows half a period later.
//  - Every bit is one SCLK period (2 x (cfg_div + 1) PCLK, high half
//    first). The master drives a bit at the rising edge; the slaves sample
//    it at the falling edge. In a read, the slave drives each bit after the
//    rising edge and the master samples it at the falling edge (SDATA
//    through two flops, so cfg_div must cover the slave's delay; 7 or more
//    with MIPI_RFFE_top).
//  - Command frame SA[3:0] C[7:0] P, address and data frames D[7:0] P, all
//    MSB first with odd parity:
//      0 Register 0 write       C = 1 D[6:0]           (data in cmd_addr[6:0])
//      1 Register write         C = 010 A[4:0], data frame
//      2 Register read          C = 011 A[4:0], read frame
//      3 Extended write         C = 0000 BC, A[7:0], BC + 1 data frames
//      4 Extended read          C = 0010 BC, A[7:0], BC + 1 read frames
//      5 Extended long write    C = 00110 BC[2:0], A[15:8], A[7:0], data
//      6 Extended long read     C = 00111 BC[2:0], A[15:8], A[7:0], read
//      7 reserved: no bus activity, done at once
//  - Write sequences end with a bus park cycle (the master drives SDATA low
//    while SCLK is high and releases it at the falling edge). Reads put the
//    bus park cycle before the read frames, and end with the slave's bus
//    park cycle (one more SCLK period, SDATA left to the slave, and half a
//    period more before the master may drive SDATA again).
//  - Data bytes come from the wr_* stream, one per data frame. With no byte
//    ready, the master holds SCLK low (and SDATA) until one arrives.
//  - Each read frame is delivered on rd_* with rd_perr when its parity
//    fails; done pulses at the end of the sequence, with done_perr when any
//    read frame of it failed.
//  SDATA is released outside sequences (a bus holder keeps it low).
//  Not implemented: half-speed reads, masked writes, interrupt and
//  master-ownership-handover sequences.
// ============================================================================
module RFFE_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [3:0]  cfg_div,           // SCLK half period - 1 (PCLK)
  // bus
  output logic        sclk,
  output logic        sdata_o,
  output logic        sdata_oe,
  input  logic        sdata_i,
  // commands
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [2:0]  cmd_type,
  input  logic [3:0]  cmd_sa,
  input  logic [15:0] cmd_addr,
  input  logic [3:0]  cmd_bc,            // byte count - 1 (extended; long uses [2:0])
  // write data
  input  logic        wr_valid,
  output logic        wr_ready,
  input  logic [7:0]  wr_data,
  // read data
  output logic        rd_valid,
  output logic [7:0]  rd_data,
  output logic        rd_perr,
  // status
  output logic        done,
  output logic        done_perr,
  output logic        busy
);
  typedef enum logic [2:0] {S_IDLE, S_SSC, S_TX, S_WAIT, S_BP, S_RX, S_SP} st_t;
  st_t         st;
  logic [3:0]  t;                        // PCLK in this half period
  logic [1:0]  sub;                      // SSC: half periods done
  logic [12:0] tsr;                      // frame being sent, MSB first
  logic [3:0]  nb;                       // bits left in this frame
  logic [1:0]  fk;                       // frame: 0 command, 1 address high, 2 address low, 3 data
  logic [2:0]  typ;
  logic [7:0]  a_lo;
  logic [3:0]  nleft;                    // data / read frames left - 1
  logic [7:0]  rsr;
  logic [1:0]  si;
  logic        perr;

  wire tick = t == cfg_div;
  wire wr_t = typ[0];                   // 1, 3, 5: writes with data frames (7 never gets here)
  assign cmd_ready = st == S_IDLE;
  assign busy = st != S_IDLE;

  function automatic logic [8:0] frame9(input logic [7:0] d);
    frame9 = {d, ~^d};
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st <= S_IDLE; t <= '0; sub <= '0; tsr <= '0; nb <= '0; fk <= '0; typ <= '0; a_lo <= '0;
      nleft <= '0; rsr <= '0; si <= '0; perr <= 1'b0;
      sclk <= 1'b0; sdata_o <= 1'b0; sdata_oe <= 1'b0;
      wr_ready <= 1'b0; rd_valid <= 1'b0; rd_data <= '0; rd_perr <= 1'b0; done <= 1'b0; done_perr <= 1'b0;
    end else begin
      wr_ready <= 1'b0; rd_valid <= 1'b0; done <= 1'b0;
      si <= {si[0], sdata_i};
      t <= st == S_IDLE || st == S_WAIT || tick ? 4'd0 : t + 4'd1;
      unique case (st)
        S_IDLE: if (cmd_valid) begin : b_cmd
          logic [7:0] c;
          typ <= cmd_type; a_lo <= cmd_addr[7:0]; perr <= 1'b0;
          case (cmd_type)
            3'd3, 3'd4: nleft <= cmd_bc;
            3'd5, 3'd6: nleft <= {1'b0, cmd_bc[2:0]};
            default: nleft <= 4'd0;
          endcase
          case (cmd_type)
            3'd0: c = {1'b1, cmd_addr[6:0]};
            3'd1: c = {3'b010, cmd_addr[4:0]};
            3'd2: c = {3'b011, cmd_addr[4:0]};
            3'd3: c = {4'b0000, cmd_bc};
            3'd4: c = {4'b0010, cmd_bc};
            3'd5: c = {5'b00110, cmd_bc[2:0]};
            default: c = {5'b00111, cmd_bc[2:0]};
          endcase
          tsr <= {cmd_sa, c, ~^{cmd_sa, c}};
          fk <= 2'd0; nb <= 4'd13;
          if (cmd_type == 3'd7) begin done <= 1'b1; done_perr <= 1'b0; end
          else begin
            st <= S_SSC; sub <= '0; sdata_oe <= 1'b1; sdata_o <= 1'b1;
          end
          rsr <= cmd_addr[15:8];                  // a long command's first address frame
        end
        S_SSC: if (tick) begin
          sub <= sub + 2'd1;
          if (sub == 2'd1) sdata_o <= 1'b0;
          if (sub == 2'd3) st <= S_TX;
        end
        S_WAIT: if (wr_valid) begin
          wr_ready <= 1'b1; tsr <= {frame9(wr_data), 4'd0}; st <= S_TX;
        end
        S_TX: if (tick) begin
          if (!sclk) begin
            sclk <= 1'b1; sdata_o <= tsr[12];
          end else begin : b_fall
            logic last;
            sclk <= 1'b0;
            tsr <= {tsr[11:0], 1'b0};
            nb <= nb - 4'd1;
            last = nb == 4'd1;
            if (last) begin
              nb <= 4'd9;
              // next frame
              if (fk == 2'd0 && (typ == 3'd5 || typ == 3'd6)) begin
                fk <= 2'd1; tsr <= {frame9(rsr), 4'd0};
              end else if (fk == 2'd0 && (typ == 3'd3 || typ == 3'd4) || fk == 2'd1) begin
                fk <= 2'd2; tsr <= {frame9(a_lo), 4'd0};
              end else if (fk == 2'd0 && typ == 3'd1 || fk == 2'd2 && wr_t ||
                           fk == 2'd3 && nleft != 4'd0) begin
                if (fk == 2'd3) nleft <= nleft - 4'd1;
                fk <= 2'd3;
                if (wr_valid) begin wr_ready <= 1'b1; tsr <= {frame9(wr_data), 4'd0}; end
                else st <= S_WAIT;
              end else st <= S_BP;                    // a write's end, or a read's turnaround
            end
          end
        end
        S_BP: if (tick) begin
          if (!sclk) begin sclk <= 1'b1; sdata_o <= 1'b0; end
          else begin
            sclk <= 1'b0; sdata_oe <= 1'b0;
            if (wr_t || typ == 3'd0) begin st <= S_IDLE; done <= 1'b1; done_perr <= 1'b0; end
            else st <= S_RX;
          end
        end
        S_RX: if (tick) begin
          if (!sclk) sclk <= 1'b1;
          else begin : b_rx
            logic [8:0] f;
            sclk <= 1'b0;
            f = {rsr, si[1]};
            rsr <= f[7:0];
            nb <= nb - 4'd1;
            if (nb == 4'd1) begin
              nb <= 4'd9;
              rd_valid <= 1'b1; rd_data <= f[8:1]; rd_perr <= !(^f);
              if (!(^f)) perr <= 1'b1;
              nleft <= nleft - 4'd1;
              if (nleft == 4'd0) begin st <= S_SP; sub <= 2'd0; end
            end
          end
        end
        S_SP: if (tick) begin
          // the slave's bus park cycle, then half a period for it to let go
          if (sub == 2'd1) begin st <= S_IDLE; done <= 1'b1; done_perr <= perr; end
          else if (!sclk) sclk <= 1'b1;
          else begin sclk <= 1'b0; sub <= 2'd1; end
        end
      endcase
    end
endmodule
