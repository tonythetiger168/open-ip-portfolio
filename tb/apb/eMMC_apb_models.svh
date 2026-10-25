// SPDX-License-Identifier: Apache-2.0
// eMMC device model for eMMC_apb_tb (the same model as tb/eMMC_tb.sv).

module emmc_card #(parameter int BC = 1) (
  input logic clk,
  inout wire  cmd,
  inout wire  dat0
);
  localparam int F_NONE = 0, F_MUTE = 1, F_R3 = 2, F_R2 = 3, F_CRC7 = 4, F_IDX = 5, F_END = 6,
                 F_TXB = 7, F_STAT = 8, F_TOK = 9, F_TOKMUTE = 10, F_BUSYHOLD = 11, F_RDMUTE = 12,
                 F_RDCRC = 13, F_RDEND = 14, F_RDDATA = 15, F_WCRC = 16, F_R3RES = 17, F_R2RES = 18;
  logic [127:0] cid_base = 128'h1501_0045_4D4D_4331_3600_1234_5678_9A00;

  logic coe = 0, co = 1, doe = 0, dout = 1;
  assign cmd  = coe ? co : 1'bz;
  assign dat0 = doe ? dout : 1'bz;

  int fault = F_NONE, fault_cmd = -1;
  int busy_polls = 2, polls = 0, busy_len = 6;
  logic [31:0] st_err = 32'h0040_0000;     // status bits sent with F_STAT
  logic [31:0] st_ok  = 32'h0000_0900;     // status bits sent otherwise
  int bad_frames = 0, n_cmds = 0;
  logic [255:0] mem [0:3];
  logic wr_go = 0, rd_go = 0;
  logic [1:0] dblk;
  int dfault = F_NONE;

  function automatic logic [6:0] crc7(input logic [119:0] d, input int n);
    logic [6:0] c = 0;
    for (int i = 119; i >= 0; i--) if (i < n) c = {c[5:0], 1'b0} ^ ((d[i] ^ c[6]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  function automatic logic [15:0] crc16(input logic [255:0] d);
    logic [15:0] c = 0;
    for (int i = 255; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((d[i] ^ c[15]) ? 16'h1021 : 16'h0);
    return c;
  endfunction
  function automatic logic [127:0] cid_val();
    cid_val = cid_base;
    cid_val[7:1] = crc7(cid_base[127:8], 120);
    cid_val[0] = 1'b1;
  endfunction

  task automatic bitw(input int k);
    repeat (k * BC) @(posedge clk);
  endtask

  // drive a response MSB first on CMD
  logic [135:0] rsp;
  task automatic send_rsp(input int len);
    coe <= 1;
    for (int i = len - 1; i >= 0; i--) begin co <= rsp[i]; bitw(1); end
    coe <= 0; co <= 1;
  endtask

  task automatic kill();
    disable run; disable drun;
    coe <= 0; co <= 1; doe <= 0; dout <= 1; wr_go = 0; rd_go = 0; polls = 0;
  endtask

  // ------------------------- command side -------------------------
  initial forever begin : run
    logic [47:0] f;
    logic [5:0] idx;
    int flt;
    @(posedge clk);
    if (cmd === 1'b0 && !coe) begin
      f = 0;
      for (int i = 46; i >= 0; i--) begin bitw(1); f[i] = cmd; end
      idx = f[45:40];
      n_cmds++;
      if (!f[46] || !f[0] || crc7({80'h0, f[47:8]}, 40) != f[7:1]) bad_frames++;
      else begin
        flt = (fault_cmd == idx) ? fault : F_NONE;
        if (flt != F_NONE) begin fault = F_NONE; fault_cmd = -1; end
        bitw(4);
        case (idx)
          6'd0: polls = 0;
          6'd1: if (flt != F_MUTE) begin
            rsp = 0;
            rsp[47:0] = {2'b00, 6'h3F, polls >= busy_polls, 31'h00FF_8080, 8'hFF};
            if (flt == F_R3) rsp[45] = 1'b0;
            if (flt == F_R3RES) rsp[3] = 1'b0;
            polls++;
            send_rsp(48);
          end
          6'd2: if (flt != F_MUTE) begin
            rsp = {2'b00, 6'h3F, cid_val()};
            if (flt == F_R2) rsp[3] = ~rsp[3];
            if (flt == F_R2RES) rsp[130] = 1'b0;
            send_rsp(136);
          end
          default: if (flt != F_MUTE) begin
            logic [31:0] st;
            st = (flt == F_STAT) ? (st_ok | st_err) : st_ok;
            rsp = 0;
            rsp[47:0] = {2'b00, idx, st, 7'h0, 1'b1};
            rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40);
            if (flt == F_CRC7) rsp[1] = ~rsp[1];
            if (flt == F_IDX)  begin rsp[40] = ~rsp[40]; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
            if (flt == F_END)  rsp[0] = 1'b0;
            if (flt == F_TXB) begin rsp[46] = 1'b1; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
            send_rsp(48);
            if (flt == F_NONE || flt >= F_TOK) begin
              dblk = f[9:8]; dfault = flt;
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
    logic [15:0] c;
    logic e, ok;
    int t;
    @(posedge clk);
    if (wr_go) begin
      wr_go = 0;
      t = 0;
      while (dat0 !== 1'b0 && t < 200) begin @(posedge clk); t++; end
      for (int i = 255; i >= 0; i--) begin bitw(1); d[i] = dat0; end
      for (int i = 15; i >= 0; i--) begin bitw(1); c[i] = dat0; end
      bitw(1); e = dat0;
      ok = e && c == crc16(d) && dfault != F_WCRC;
      if (ok) mem[dblk] = d;
      bitw(2);
      if (dfault != F_TOKMUTE) begin
        doe <= 1; dout <= 0; bitw(1);
        {dout} <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b1 : 1'b0; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout <= 1; bitw(1);
        dout <= 0; bitw(dfault == F_BUSYHOLD ? 70 : busy_len);
        doe <= 0; dout <= 1;
      end
    end else if (rd_go) begin
      rd_go = 0;
      bitw(2);
      if (dfault != F_RDMUTE) begin
        d = mem[dblk];
        if (dfault == F_RDDATA) d[77] = ~d[77];   // with a matching CRC16
        c = crc16(d);
        if (dfault == F_RDCRC) c[0] = ~c[0];
        doe <= 1; dout <= 0; bitw(1);
        for (int i = 255; i >= 0; i--) begin dout <= d[i]; bitw(1); end
        for (int i = 15; i >= 0; i--) begin dout <= c[i]; bitw(1); end
        dout <= dfault != F_RDEND; bitw(1);
        doe <= 0; dout <= 1;
      end
    end
  end
endmodule
