// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Directed BIT_CLKS=4 functional testbench for SAS_top -- SystemVerilog
// (a) OOB loopback to PHY READY (OOB signalling runs on raw clk, unscaled)
// (b) RX path: TB drives an SSP write frame aligned to the DUT dword
//     boundary (bit_tick && rx_bit_cnt==31), 4 clks per bit, and verifies
//     wr_evt / wr_addr / wr_data / regs[].
// (c) TX path: TB injects a read request, samples tx_p at the divided bit
//     phase, reassembles the dword stream and scans it for the RDRSP frame
//     (payload == 32'hDEADBEEF, CRC32 checked with an independent reference
//     model, EOF checked).
// (e) reconnect tx->rx loopback; after the sequencer's first clean
//     round-trip absorbs any stale timeout, require ok_cnt +2 more with zero
//     tmo_cnt growth (proves SQ_TMO scaling gives the link enough budget).
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module SAS_bitclks_tb;
  localparam int BC = 4;          // clk cycles per serial bit (DUT setting)

  logic clk = 0, rst_n = 0, refclk = 0;
  logic tx_n, tx_p, rx_n, rx_p, irq;
  int   errors = 0;

  // RX source mux: 0 = loopback (tx->rx), 1 = TB-directed drive
  logic tb_drive = 1'b0;
  logic rxp_drv  = 1'b0;

  SAS_top #(.BIT_CLKS(BC)) dut (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx_n), .tx_p(tx_p),
    .rx_n(rx_n), .rx_p(rx_p),
    .refclk(refclk), .irq(irq)
  );

  always #5 clk    = ~clk;
  always #3 refclk = ~refclk;

  assign rx_p = tb_drive ? rxp_drv : tx_p;
  assign rx_n = tx_n;

  localparam logic [31:0] SSP_SOF = 32'hA5A5_0001;
  localparam logic [31:0] SSP_EOF = 32'hA5A5_0002;
  localparam logic [7:0]  T_WRITE = 8'h01;
  localparam logic [7:0]  T_RDREQ = 8'h02;
  localparam logic [7:0]  T_RDRSP = 8'h83;

  // -------- independent CRC32 reference model (Ethernet FCS style) --------
  function automatic logic [31:0] crc32_dw(input logic [31:0] crc,
                                           input logic [31:0] dw);
    logic [31:0] c;
    begin
      c = crc;
      for (int b = 3; b >= 0; b--) begin          // dword bytes, MSB byte first
        for (int i = 0; i < 8; i++) begin         // LSB-first within byte
          if (c[0] ^ dw[b*8+i]) c = (c >> 1) ^ 32'hEDB88320;
          else                  c = (c >> 1);
        end
      end
      crc32_dw = c;
    end
  endfunction

  // -------- TB-side counters ------------------------------------------------
  int tmo_cnt = 0;                  // sequencer timeout pulses observed
  always @(posedge clk) if (rst_n && dut.tmo_err_pulse) tmo_cnt++;

  // capture of the directed write frame's register-write event
  logic        wr_seen  = 1'b0;
  logic [3:0]  wr_a     = 4'd0;
  logic [31:0] wr_d     = 32'd0;
  always @(posedge clk) begin
    if (rst_n && dut.wr_evt) begin
      wr_seen <= 1'b1;
      wr_a    <= dut.wr_addr;
      wr_d    <= dut.wr_data;
    end
  end

  // -------- TX stream capture: sample tx_p on the DUT's own bit_tick --------
  // At a bit_tick posedge, tx_p still shows the bit that just completed
  // (tx_shift updates in the NBA region), and tx_bit_cnt==31 marks the last
  // bit of a dword.  Dword stream feeds a small SSP frame parser.
  typedef enum logic [2:0] {P_SCAN, P_HDR, P_PAY, P_CRC, P_EOF} parse_t;
  parse_t      pstate  = P_SCAN;
  logic [31:0] cap_sh  = 32'd0;
  logic [7:0]  p_len   = 8'd0, p_type = 8'd0;
  logic [7:0]  p_pay_cnt = 8'd0;
  logic [31:0] p_pay0  = 32'd0;
  logic [31:0] p_crc   = 32'd0;
  logic        rdrsp_ok     = 1'b0;   // RDRSP(payload=DEADBEEF)+CRC32+EOF seen
  logic        rdrsp_bad    = 1'b0;   // RDRSP with wrong shape/CRC/EOF seen
  logic        p_rdrsp_good = 1'b0;   // CRC dword of current RDRSP was good
  logic [31:0] dw;
  logic        cap_en = 1'b0;         // enabled during phase (c)

  always @(posedge clk) begin
    if (rst_n && cap_en && dut.phy_ready && dut.bit_tick) begin
      dw = {cap_sh[30:0], tx_p};
      cap_sh <= dw;
      if (dut.tx_bit_cnt == 6'd31) begin   // dword boundary: dw is complete
        case (pstate)
          P_SCAN: if (dw == SSP_SOF) pstate <= P_HDR;
          P_HDR: begin
            p_len    <= dw[31:24];
            p_type   <= dw[23:16];
            p_crc    <= crc32_dw(32'hFFFF_FFFF, dw);
            p_pay_cnt<= 8'd0;
            pstate   <= (dw[31:24] == 8'd0) ? P_CRC : P_PAY;
          end
          P_PAY: begin
            if (p_pay_cnt == 8'd0) p_pay0 <= dw;
            p_crc <= crc32_dw(p_crc, dw);
            if (p_pay_cnt == p_len - 8'd1) pstate <= P_CRC;
            p_pay_cnt <= p_pay_cnt + 8'd1;
          end
          P_CRC: begin
            p_rdrsp_good <= (p_type == T_RDRSP) &&
                            (dw === (p_crc ^ 32'hFFFF_FFFF)) &&
                            (p_len == 8'd1) && (p_pay0 === 32'hDEAD_BEEF);
            pstate <= P_EOF;
          end
          P_EOF: begin
            if (p_type == T_RDRSP) begin
              if (p_rdrsp_good && dw === SSP_EOF) rdrsp_ok  <= 1'b1;
              else                                rdrsp_bad <= 1'b1;
            end
            pstate <= P_SCAN;
          end
          default: pstate <= P_SCAN;
        endcase
      end
    end
  end

  // -------- directed SSP frame driver (BC clks per bit, MSB first) ---------
  // Synchronize so the first SOF bit lands in the rx_bit_cnt==0 sample slot,
  // then hold every bit for exactly BC clks (matching the DUT bit_tick phase).
  task automatic ssp_bit(input logic b);
    begin
      @(negedge clk); rxp_drv = b;
      repeat (BC) @(posedge clk);
    end
  endtask

  task automatic ssp_dw(input logic [31:0] v);
    begin
      for (int i = 31; i >= 0; i--) ssp_bit(v[i]);
    end
  endtask

  task automatic ssp_sync;
    begin
      while (!(dut.bit_tick && dut.rx_bit_cnt == 6'd31)) @(posedge clk);
    end
  endtask

  // write frame: SOF HDR(len=1,type=write) PAYLOAD CRC32 EOF
  task automatic ssp_write(input logic [7:0] addr, input logic [31:0] data);
    logic [31:0] hdr, c;
    begin
      hdr = {8'd1, T_WRITE, addr, 8'h42};
      c   = crc32_dw(crc32_dw(32'hFFFF_FFFF, hdr), data) ^ 32'hFFFF_FFFF;
      ssp_sync();
      ssp_dw(SSP_SOF);
      ssp_dw(hdr);
      ssp_dw(data);
      ssp_dw(c);
      ssp_dw(SSP_EOF);
    end
  endtask

  // read request frame: SOF HDR(len=0,type=rdreq) CRC32 EOF
  task automatic ssp_rdreq(input logic [7:0] addr);
    logic [31:0] hdr, c;
    begin
      hdr = {8'd0, T_RDREQ, addr, 8'h42};
      c   = crc32_dw(32'hFFFF_FFFF, hdr) ^ 32'hFFFF_FFFF;
      ssp_sync();
      ssp_dw(SSP_SOF);
      ssp_dw(hdr);
      ssp_dw(c);
      ssp_dw(SSP_EOF);
    end
  endtask

  // ---------------- test sequence ------------------------------------------
  int t;
  int ok0, tmo0;

  initial begin
    // reset
    rst_n = 0; repeat (10) @(posedge clk);
    rst_n = 1;

    // (a) OOB handshake over loopback (raw-clk timing) -> PHY READY
    t = 0;
    while (!dut.phy_ready && t < 3000) begin @(posedge clk); t++; end
    if (!dut.phy_ready) begin
      errors++; $display("ERROR: OOB did not reach PHY READY (BIT_CLKS=%0d)", BC);
    end else begin
      $display("INFO: OOB complete, PHY READY after %0d clks", t);
    end

    // switch RX to TB-directed drive (sequencer frames now go into the void;
    // its timeout pulses during phases b/c are expected and tolerated)
    @(negedge clk); tb_drive = 1'b1; rxp_drv = 1'b0;

    // (b) directed SSP write of 32'hDEADBEEF to reg 3
    ssp_write(8'd3, 32'hDEAD_BEEF);
    repeat (4*BC) @(posedge clk);
    if (!wr_seen) begin
      errors++; $display("ERROR: no wr_evt for directed write frame");
    end else begin
      if (wr_a !== 4'd3) begin
        errors++; $display("ERROR: wr_addr got=%0d exp=3", wr_a);
      end
      if (wr_d !== 32'hDEAD_BEEF) begin
        errors++; $display("ERROR: wr_data got=%h exp=DEADBEEF", wr_d);
      end
    end
    if (dut.regs[3] !== 32'hDEAD_BEEF) begin
      errors++; $display("ERROR: regs[3] got=%h exp=DEADBEEF", dut.regs[3]);
    end

    // (c) directed read request -> DUT must answer RDRSP(payload=DEADBEEF)
    cap_en = 1'b1;
    ssp_rdreq(8'd3);
    t = 0;
    while (!rdrsp_ok && !rdrsp_bad && t < 30000) begin @(posedge clk); t++; end
    if (rdrsp_bad) begin
      errors++; $display("ERROR: RDRSP frame malformed (payload/CRC32/EOF)");
    end else if (!rdrsp_ok) begin
      errors++; $display("ERROR: no valid RDRSP frame observed on tx_p");
    end else begin
      $display("INFO: RDRSP payload=DEADBEEF with good CRC32+EOF after %0d clks", t);
    end
    cap_en = 1'b0;

    // (e) reconnect tx->rx loopback; first clean round-trip absorbs any
    // stale sequencer timeout, then ok_cnt must advance twice more with
    // zero additional timeouts (SQ_TMO scaled by BIT_CLKS).
    @(negedge clk); tb_drive = 1'b0;
    ok0 = dut.ok_cnt;
    t = 0;
    while (dut.ok_cnt == ok0 && t < 40000) begin @(posedge clk); t++; end
    if (dut.ok_cnt == ok0) begin
      errors++; $display("ERROR: sequencer never completed a round-trip after reconnect");
    end
    ok0  = dut.ok_cnt;
    tmo0 = tmo_cnt;
    t = 0;
    while (dut.ok_cnt < ok0 + 2 && t < 80000) begin @(posedge clk); t++; end
    if (dut.ok_cnt < ok0 + 2) begin
      errors++;
      $display("ERROR: loopback stalled: ok_cnt=%0d exp>=%0d", dut.ok_cnt, ok0+2);
    end
    if (tmo_cnt != tmo0) begin
      errors++;
      $display("ERROR: %0d sequencer timeouts during stable loopback (SQ_TMO too small?)",
               tmo_cnt - tmo0);
    end
    if (dut.mm_cnt != 0 && dut.ok_cnt < ok0 + 2) begin
      errors++; $display("ERROR: read-verify mismatches without progress");
    end
    $display("INFO: loopback stable, ok_cnt=%0d mm_cnt=%0d tmo_cnt=%0d",
             dut.ok_cnt, dut.mm_cnt, tmo_cnt);

    if (errors == 0) $display("TEST PASSED: SAS_BITCLKS");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
