// SPDX-License-Identifier: Apache-2.0
// SD card model for SD_apb_tb (the same model as tb/SD_tb.sv).

module sd_card (
  input logic      sd_clk,
  inout wire       cmd,
  inout wire [3:0] dat
);
  localparam int F_NONE = 0, F_MUTE = 1, F_R3 = 2, F_R2 = 3, F_CRC7 = 4, F_IDX = 5, F_END = 6,
                 F_TXB = 7, F_STAT = 8, F_TOK = 9, F_TOKMUTE = 10, F_BUSYHOLD = 11, F_RDMUTE = 12,
                 F_RDCRC = 13, F_RDEND = 14, F_RDDATA = 15, F_WCRC = 16, F_R3RES = 17, F_R2RES = 18,
                 F_R7V = 19, F_R7P = 20;
  logic [127:0] cid_base = 128'h0353_4453_4430_3847_8012_3456_7801_5A00;
  logic [15:0]  rca = 16'hB37A;
  logic         ccs = 1;

  logic coe = 0, co = 1;
  logic [3:0] doe = 0, dout = 4'hF;
  assign cmd = coe ? co : 1'bz;
  for (genvar i = 0; i < 4; i++) begin : g_dat
    assign dat[i] = doe[i] ? dout[i] : 1'bz;
  end

  int fault = F_NONE, fault_cmd = -1, crc_line = 0;
  int busy_polls = 2, polls = 0, busy_len = 6;
  logic [31:0] st_err = 32'h0040_0000;     // status bits sent with F_STAT
  logic [31:0] st_ok  = 32'h0000_0900;     // status bits sent otherwise
  logic [15:0] r6_err = 16'h4000;
  int bad_frames = 0, bad_args = 0, n_cmds = 0;
  logic [255:0] mem [0:3];
  logic wr_go = 0, rd_go = 0;
  logic [1:0] dblk;
  int dfault = F_NONE;

  function automatic logic [6:0] crc7(input logic [119:0] d, input int n);
    logic [6:0] c = 0;
    for (int i = 119; i >= 0; i--) if (i < n) c = {c[5:0], 1'b0} ^ ((d[i] ^ c[6]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  // CRC16 of DAT line k of a 4-bit block (nibble j bit k = block bit 255-4j-(3-k))
  function automatic logic [15:0] crc16(input logic [255:0] d, input int k);
    logic [15:0] c = 0;
    logic b;
    for (int j = 0; j < 64; j++) begin
      b = d[255 - 4 * j - (3 - k)];
      c = {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0);
    end
    return c;
  endfunction
  function automatic logic [127:0] cid_val();
    cid_val = cid_base;
    cid_val[7:1] = crc7(cid_base[127:8], 120);
    cid_val[0] = 1'b1;
  endfunction

  task automatic bitw(input int k);
    repeat (k) @(negedge sd_clk);
  endtask

  // drive a response MSB first on CMD
  logic [135:0] rsp;
  task automatic send_rsp(input int len);
    coe <= 1;
    for (int i = len - 1; i >= 0; i--) begin co <= rsp[i]; bitw(1); end
    coe <= 0; co <= 1;
  endtask

  task automatic r48(input logic [5:0] idx, input logic [31:0] arg, input int flt);
    rsp = 0;
    rsp[47:0] = {2'b00, idx, arg, 7'h0, 1'b1};
    rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40);
    if (flt == F_CRC7) rsp[1] = ~rsp[1];
    if (flt == F_IDX)  begin rsp[40] = ~rsp[40]; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
    if (flt == F_END)  rsp[0] = 1'b0;
    if (flt == F_TXB) begin rsp[46] = 1'b1; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
    send_rsp(48);
  endtask

  task automatic kill();
    disable run; disable drun;
    coe <= 0; co <= 1; doe <= 0; dout <= 4'hF; wr_go = 0; rd_go = 0; polls = 0;
  endtask

  // ------------------------- command side -------------------------
  initial forever begin : run
    logic [47:0] f;
    logic [5:0] idx;
    logic [31:0] arg;
    int flt;
    @(negedge sd_clk);
    if (cmd === 1'b0 && !coe) begin
      f = 0;
      for (int i = 46; i >= 0; i--) begin bitw(1); f[i] = cmd; end
      idx = f[45:40]; arg = f[39:8];
      n_cmds++;
      if (!f[46] || !f[0] || crc7({80'h0, f[47:8]}, 40) != f[7:1]) bad_frames++;
      else begin
        flt = (fault_cmd == idx) ? fault : F_NONE;
        if (flt != F_NONE) begin fault = F_NONE; fault_cmd = -1; end
        bitw(5);
        if (flt != F_MUTE) case (idx)
          6'd0: polls = 0;
          6'd8: begin
            if (arg != 32'h1AA) bad_args++;
            r48(6'd8, {20'h0, flt == F_R7V ? 4'h2 : 4'h1, flt == F_R7P ? 8'h55 : 8'hAA}, flt);
          end
          6'd41: begin
            if (arg != 32'h40FF_8000) bad_args++;
            rsp = 0;
            rsp[47:0] = {2'b00, 6'h3F, polls >= busy_polls, ccs, 30'h00FF_8000, 8'hFF};
            if (flt == F_R3) rsp[45] = 1'b0;
            if (flt == F_R3RES) rsp[3] = 1'b0;
            polls++;
            send_rsp(48);
          end
          6'd2: begin
            rsp = {2'b00, 6'h3F, cid_val()};
            if (flt == F_R2) rsp[3] = ~rsp[3];
            if (flt == F_R2RES) rsp[130] = 1'b0;
            send_rsp(136);
          end
          6'd3: r48(6'd3, {rca, flt == F_STAT ? r6_err : 16'h0500}, flt);
          default: begin
            if ((idx == 6'd7 || idx == 6'd13) && arg != {rca, 16'h0}) bad_args++;
            if ((idx == 6'd24 || idx == 6'd17) &&
                (ccs ? arg[31:2] != 0 : (arg[31:7] != 0 || arg[4:0] != 0))) bad_args++;
            r48(idx, ((flt == F_STAT) ? (st_ok | st_err) : st_ok) | (idx == 6'd55 ? 32'h20 : 32'h0), flt);
            if (flt == F_NONE || flt >= F_TOK) begin
              dblk = ccs ? arg[1:0] : arg[6:5]; dfault = flt;
              if (idx == 6'd24) wr_go = 1;
              if (idx == 6'd17) rd_go = 1;
            end
          end
        endcase
      end
    end
  end

  // ------------------------- data side -------------------------
  initial forever begin : drun
    logic [255:0] d;
    logic [15:0] c [4];
    logic [3:0] e;
    logic ok;
    int t;
    @(negedge sd_clk);
    if (wr_go) begin
      wr_go = 0;
      t = 0;
      while (dat !== 4'h0 && t < 200) begin @(negedge sd_clk); t++; end
      for (int j = 0; j < 64; j++) begin bitw(1); d[255 - 4 * j -: 4] = dat; end
      for (int i = 15; i >= 0; i--) begin
        bitw(1);
        for (int k = 0; k < 4; k++) c[k][i] = dat[k];
      end
      bitw(1); e = dat;
      ok = e == 4'hF && dfault != F_WCRC;
      for (int k = 0; k < 4; k++) if (c[k] != crc16(d, k)) ok = 0;
      if (ok) mem[dblk] = d;
      bitw(2);
      if (dfault != F_TOKMUTE) begin
        doe[0] <= 1; dout[0] <= 0; bitw(1);
        dout[0] <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout[0] <= ok && dfault != F_TOK ? 1'b1 : 1'b0; bitw(1);
        dout[0] <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout[0] <= 1; bitw(1);
        dout[0] <= 0; bitw(dfault == F_BUSYHOLD ? 70 : busy_len);
        doe[0] <= 0; dout[0] <= 1;
      end
    end else if (rd_go) begin
      rd_go = 0;
      bitw(2);
      if (dfault != F_RDMUTE) begin
        d = mem[dblk];
        if (dfault == F_RDDATA) d[77] = ~d[77];   // with a matching CRC16
        for (int k = 0; k < 4; k++) c[k] = crc16(d, k);
        if (dfault == F_RDCRC) c[crc_line][crc_line * 3] = ~c[crc_line][crc_line * 3];
        doe <= 4'hF; dout <= 4'h0; bitw(1);
        for (int j = 0; j < 64; j++) begin dout <= d[255 - 4 * j -: 4]; bitw(1); end
        for (int i = 15; i >= 0; i--) begin dout <= {c[3][i], c[2][i], c[1][i], c[0][i]}; bitw(1); end
        dout <= dfault == F_RDEND ? 4'b1110 : 4'hF; bitw(1);
        doe <= 0; dout <= 4'hF;
      end
    end
  end
endmodule
