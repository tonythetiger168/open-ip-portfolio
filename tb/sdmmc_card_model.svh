// SPDX-License-Identifier: Apache-2.0
// sdmmc_card_model: behavioural SD memory card / eMMC device for the
// SDMMC_ADMA testbenches. `emmc` selects the personality at run time (call
// insert() after changing it). Samples CMD / DAT on the rising sd_clk edge,
// drives them on the falling edge.
// - SD: CMD0, CMD8 (R7 echo), CMD55 + ACMD41 (R3, ready on the 3rd poll,
//   CCS = 1), CMD2 (R2 CID), CMD3 (R6, RCA 0xB37A), CMD7 (R1b), ACMD6 (bus
//   width 1 / 4), CMD13, CMD16, CMD17 / 18, CMD24 / 25, CMD12 (R1b).
// - rnd_id: insert() picks a random CID and SD RCA (identification tests).
// - eMMC: CMD0, CMD1 (R3, ready on the 3rd poll, sector mode, OCR bits 14:8
//   as offered by the host), CMD2, CMD3
//   (the host's RCA), CMD7, CMD6 SWITCH of EXT_CSD[183] BUS_WIDTH (R1b; 1 /
//   4 / 8 bits), CMD8 SEND_EXT_CSD (one 512-byte block), and the same data
//   commands.
// - Data: NBLK blocks; the block at argument A starts at byte A * blklen
//   (blklen is 512 until CMD16). Read data starts 2..8 clocks after the
//   response (N_AC) and after each block; a multiple-block read or write
//   runs until CMD12. Each write block gets the CRC status token 2 clocks
//   after its end bit and 0..busy_max clocks of busy.
// - One-shot faults: f_mute (no response), f_rcrc (bad response CRC7),
//   f_ridx (wrong index in a 48-bit response), f_rend (end bit 0),
//   f_rd_end (DAT0 end bit 0 on the next read block),
//   f_rd_crc (bad CRC16 on DAT0 of the next read block), f_wtok (next write
//   block rejected, CRC status 101, not written), f_busy (next R1b busy
//   lasts busy_long clocks), f_wnotok (no CRC status token after the next
//   write block), f_wbusy (busy_long clocks of busy after the next write
//   block).
// - Checks (counted in `errors`): host command CRC7, transmission and end
//   bits, write data CRC16 and end bits, start bits on every data line in
//   use, lines driven by the host while the card drives them.
`ifndef SDMMC_CARD_MODEL_SVH
`define SDMMC_CARD_MODEL_SVH
module sdmmc_card_model #(parameter int NBLK = 64) (
  input  logic sclk,
  inout  tri   cmd,
  inout  tri   [7:0] dat
);
  bit          emmc = 0;
  logic [7:0]  mem [0:NBLK * 512 - 1];
  logic [7:0]  ext_csd [0:511];
  logic [127:0] cid;
  int          errors = 0, n_cmds = 0, n_rd_blk = 0, n_wr_blk = 0;
  int          width = 1, blklen = 512, polls = 0, busy_max = 6, busy_long = 5000;
  logic [15:0] rca = 0;
  bit          acmd = 0, selected = 0;
  bit          f_mute = 0, f_rcrc = 0, f_rd_crc = 0, f_wtok = 0, f_busy = 0;
  bit          f_ridx = 0, f_rend = 0, f_rd_end = 0, f_wnotok = 0, f_wbusy = 0;
  bit          rnd_id = 0;                // insert(): random CID body and SD RCA
  logic [15:0] sd_rca = 16'hB37A;
  // drivers
  logic        c_oe = 0, c_o = 1, busy_lo = 0;
  logic [7:0]  d_oe = 0, d_o = 8'hFF;
  assign cmd = c_oe ? c_o : 1'bz;
  assign dat[0] = d_oe[0] ? d_o[0] : busy_lo ? 1'b0 : 1'bz;
  genvar gi;
  generate for (gi = 1; gi < 8; gi++) begin : g_d
    assign dat[gi] = d_oe[gi] ? d_o[gi] : 1'bz;
  end endgenerate
  // data requests from the command side
  bit          rd_req = 0, wr_req = 0, multi = 0, stop = 0, xcsd = 0;
  int          d_addr = 0;

  bit          expect_bad = 0;   // a test breaks the protocol on purpose: report, do not count
  function automatic void bad(input string m);
    if (expect_bad) begin $display("note: sdmmc_card (expected): %s @%0t", m, $time); return; end
    errors++;
    $display("ERROR: sdmmc_card: %s @%0t", m, $time);
  endfunction
  function automatic logic [6:0] crc7(input logic [135:0] b, input int hi, input int lo);
    logic [6:0] c;
    c = 0;
    for (int i = hi; i >= lo; i--) c = {c[5:0], 1'b0} ^ ((b[i] ^ c[6]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic b);
    return {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0000);
  endfunction
  task automatic insert;
    logic [119:0] body;
    width = 1; blklen = 512; polls = 0; rca = 0; acmd = 0; selected = 0;
    c_oe = 0; d_oe = 0; busy_lo = 0; rd_req = 0; wr_req = 0; stop = 0;
    body = emmc ? 120'h15_0100_4D_4D43_3136_47_10_DEADBEEF_A1 : 120'h03_5344_5344_3634_47_80_12345678_016;
    if (rnd_id) begin
      body = {$urandom, $urandom, $urandom, $urandom};
      sd_rca = $urandom; if (sd_rca == 0) sd_rca = 16'h1;
    end else sd_rca = 16'hB37A;
    cid = {body, crc7({16'd0, body}, 119, 0), 1'b1};
    for (int i = 0; i < 512; i++) ext_csd[i] = 8'(i * 7 + 3);
    ext_csd[183] = 0; ext_csd[192] = 8; ext_csd[212] = 8'(NBLK); ext_csd[213] = 0;
  endtask
  initial insert();

  function automatic logic [31:0] status;
    return {19'd0, selected ? 4'd4 : 4'd3, 1'b1, 2'b00, acmd, 5'd0};
  endfunction

  // ------------------------------------------------------------ responses
  task automatic send(input logic [135:0] f, input int n, input bit r1b);
    int b;
    if (f_rcrc) begin f[1] = ~f[1]; f_rcrc = 0; end
    if (f_ridx && n == 48) begin f[40] = ~f[40]; f[7:1] = crc7(f, 47, 8); f_ridx = 0; end  // CRC still good
    if (f_rend) begin f[0] = 1'b0; f_rend = 0; end
    repeat (2) @(negedge sclk);                        // N_CR = 2
    for (int i = n - 1; i >= 0; i--) begin
      c_oe = 1; c_o = f[i];
      @(negedge sclk);
    end
    c_oe = 0;
    if (r1b) begin
      b = f_busy ? busy_long : 1 + $urandom % busy_max;
      f_busy = 0;
      busy_lo = 1; repeat (b) @(negedge sclk); busy_lo = 0;
    end
  endtask
  task automatic r1(input logic [5:0] idx, input bit r1b);
    logic [135:0] f;
    f = 0; f[47:8] = {2'b00, idx, status()};
    f[7:1] = crc7(f, 47, 8); f[0] = 1;
    send(f, 48, r1b);
  endtask
  task automatic r3(input logic [31:0] ocr);
    logic [135:0] f;
    f = 0; f[47:0] = {2'b00, 6'h3F, ocr, 7'h7F, 1'b1};
    send(f, 48, 0);
  endtask
  task automatic r2;
    logic [135:0] f;
    f = {2'b00, 6'h3F, cid};
    send(f, 136, 0);
  endtask
  task automatic r6;
    logic [135:0] f;
    f = 0; f[47:8] = {2'b00, 6'd3, rca, 16'h0500};
    f[7:1] = crc7(f, 47, 8); f[0] = 1;
    send(f, 48, 0);
  endtask
  task automatic r7(input logic [31:0] arg);
    logic [135:0] f;
    f = 0; f[47:8] = {2'b00, 6'd8, 20'd0, arg[11:0]};
    f[7:1] = crc7(f, 47, 8); f[0] = 1;
    send(f, 48, 0);
  endtask

  // ------------------------------------------------------------ command side
  logic [47:0] fr;
  initial forever begin
    @(posedge sclk);
    if (cmd === 1'b0 && !c_oe) begin
      logic [135:0] fb;
      logic [5:0]   idx;
      logic [31:0]  arg;
      bit           a;
      fr = 0;
      for (int i = 46; i >= 0; i--) begin
        @(posedge sclk);
        if (cmd !== 1'b0 && cmd !== 1'b1) bad("command bit not driven");
        fr[i] = cmd;
      end
      fb = {88'd0, fr};
      if (!fr[46]) bad("transmission bit 0 in a command");
      if (!fr[0]) bad("command end bit 0");
      if (fr[7:1] !== crc7(fb, 47, 8)) bad($sformatf("command CRC7 %h, expected %h", fr[7:1], crc7(fb, 47, 8)));
      idx = fr[45:40]; arg = fr[39:8]; a = acmd; acmd = 0; n_cmds++;
      if (idx == 6'd12) stop = 1;
      if (f_mute) f_mute = 0;
      else if (a && !emmc) case (idx)
        6'd41: begin polls++; r3({polls >= 3, 1'b1, 6'd0, 24'hFF8000}); end
        6'd6:  begin r1(idx, 0); width = (arg[1:0] == 2'b10) ? 4 : 1; end
        default: ;
      endcase
      else case (idx)
        6'd0:  insert();
        6'd1:  if (emmc) begin polls++; r3({polls >= 3, 2'b10, 5'd0, 24'hFF8080 | (arg[23:0] & 24'h007F00)}); end
        6'd2:  r2();
        6'd3:  if (emmc) begin rca = arg[31:16]; r1(idx, 0); end else begin rca = sd_rca; r6(); end
        6'd6:  if (emmc) begin
                 if (arg[25:24] == 2'b11 && arg[23:16] == 8'd183) begin
                   ext_csd[183] = arg[15:8];
                   width = (arg[15:8] == 8'd2) ? 8 : (arg[15:8] == 8'd1) ? 4 : 1;
                 end
                 r1(idx, 1);
               end
        6'd7:  begin selected = (arg[31:16] == rca); r1(idx, 1); end
        6'd8:  if (emmc) begin r1(idx, 0); xcsd = 1; multi = 0; stop = 0; rd_req = 1; end
               else r7(arg);
        6'd12: r1(idx, 1);
        6'd13: r1(idx, 0);
        6'd16: begin blklen = arg; r1(idx, 0); end
        6'd17, 6'd18: begin
                 r1(idx, 0); xcsd = 0; multi = (idx == 6'd18); d_addr = arg * blklen; stop = 0; rd_req = 1;
               end
        6'd24, 6'd25: begin
                 multi = (idx == 6'd25); d_addr = arg * blklen; stop = 0; wr_req = 1; r1(idx, 0);
               end
        6'd55: begin acmd = 1; r1(idx, 0); end
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------ data side
  task automatic rd_block(output bit aborted);
    logic [15:0] c [0:7];
    int          n, len;
    aborted = 0;
    len = xcsd ? 512 : blklen;
    n = 2 + $urandom % 7;
    repeat (n) begin @(negedge sclk); if (stop) begin aborted = 1; d_oe = 0; return; end end
    for (int l = 0; l < 8; l++) c[l] = 0;
    d_oe = (width == 8) ? 8'hFF : (width == 4) ? 8'h0F : 8'h01; d_o = 8'h00;   // start bit
    for (int i = 0; i < len; i++) begin
      logic [7:0] by;
      by = xcsd ? ext_csd[i] : mem[(d_addr + i) % (NBLK * 512)];
      for (int s = 0; s < 8 / ((width == 8) ? 8 : (width == 4) ? 4 : 1); s++) begin
        logic [7:0] o;
        if (width == 8) o = by;
        else if (width == 4) o = {4'hF, (s == 0) ? by[7:4] : by[3:0]};
        else o = {7'h7F, by[7 - s]};
        @(negedge sclk);
        if (stop) begin aborted = 1; d_oe = 0; return; end
        d_o = o;
        for (int l = 0; l < width; l++) c[l] = crc16(c[l], o[l]);
      end
    end
    if (f_rd_crc) begin c[0] = ~c[0]; f_rd_crc = 0; end
    for (int k = 15; k >= 0; k--) begin
      @(negedge sclk);
      if (stop) begin aborted = 1; d_oe = 0; return; end
      for (int l = 0; l < 8; l++) d_o[l] = c[l][k];
    end
    @(negedge sclk); d_o = 8'hFF;                       // end bit
    if (f_rd_end) begin d_o[0] = 1'b0; f_rd_end = 0; end
    @(negedge sclk); d_oe = 0;
    n_rd_blk++;
    d_addr += len;
  endtask

  task automatic wr_block(output bit aborted);
    logic [15:0] c [0:7], rc [0:7];
    logic [7:0]  buf_b [0:2047];
    logic [7:0]  lm;
    bit          ok;
    int          b;
    aborted = 0;
    lm = (width == 8) ? 8'hFF : (width == 4) ? 8'h0F : 8'h01;
    forever begin                                       // start bit
      @(posedge sclk);
      if (stop) begin aborted = 1; return; end
      if (dat[0] === 1'b0) break;
    end
    if ((dat & lm) !== 8'h00) bad($sformatf("write start bit %b on the lines in use", dat & lm));
    for (int l = 0; l < 8; l++) c[l] = 0;
    for (int i = 0; i < blklen; i++) begin
      logic [7:0] by;
      by = 0;
      for (int s = 0; s < 8 / ((width == 8) ? 8 : (width == 4) ? 4 : 1); s++) begin
        logic [7:0] v;
        @(posedge sclk);
        v = dat;
        if (width == 8) by = v;
        else if (width == 4) by = {by[3:0], v[3:0]};
        else by = {by[6:0], v[0]};
        for (int l = 0; l < width; l++) c[l] = crc16(c[l], v[l]);
      end
      buf_b[i] = by;
    end
    for (int k = 0; k < 16; k++) begin
      logic [7:0] v;
      @(posedge sclk); v = dat;
      for (int l = 0; l < 8; l++) rc[l] = {rc[l][14:0], v[l]};
    end
    @(posedge sclk);
    if ((dat & lm) !== lm) bad("write end bit");
    ok = 1;
    for (int l = 0; l < width; l++) if (rc[l] !== c[l]) begin
      ok = 0; bad($sformatf("write CRC16 line %0d: %h, expected %h", l, rc[l], c[l]));
    end
    if (f_wtok) begin ok = 0; f_wtok = 0; end
    if (ok) begin
      for (int i = 0; i < blklen; i++) mem[(d_addr + i) % (NBLK * 512)] = buf_b[i];
      n_wr_blk++;
    end
    if (f_wnotok) begin f_wnotok = 0; aborted = 1; return; end   // no CRC status token
    @(negedge sclk);                                    // N1
    @(negedge sclk); d_oe[0] = 1; d_o[0] = 0;           // token start
    @(negedge sclk); d_o[0] = ok ? 1'b0 : 1'b1;
    @(negedge sclk); d_o[0] = ok ? 1'b1 : 1'b0;
    @(negedge sclk); d_o[0] = ok ? 1'b0 : 1'b1;
    @(negedge sclk); d_o[0] = 1;                        // end bit
    @(negedge sclk); d_oe[0] = 0;
    b = f_wbusy ? busy_long : $urandom % (busy_max + 1);
    f_wbusy = 0;
    busy_lo = (b != 0); repeat (b) @(negedge sclk); busy_lo = 0;
    d_addr += blklen;
    if (!ok) aborted = 1;
  endtask

  initial forever begin
    bit ab;
    wait (rd_req || wr_req);
    if (rd_req) begin
      rd_req = 0;
      do rd_block(ab); while (multi && !ab);
    end else begin
      wr_req = 0;
      do wr_block(ab); while (multi && !ab);
      if (ab && multi && !stop) begin                  // rejected: wait for the stop
        wait (stop);
      end
    end
  end

  // the host must not drive what the card drives
  always @(posedge sclk) begin
    if (c_oe && cmd !== c_o) bad($sformatf("CMD contention: card drives %b, line %b", c_o, cmd));
    for (int l = 0; l < 8; l++)
      if (d_oe[l] && dat[l] !== d_o[l]) bad($sformatf("DAT%0d contention: card drives %b, line %b", l, d_o[l], dat[l]));
    if (busy_lo && !d_oe[0] && dat[0] !== 1'b0) bad("DAT0 busy contention");
  end
endmodule
`endif
