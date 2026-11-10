// SPDX-License-Identifier: Apache-2.0
// SDMMC_ADMA (SD / eMMC host with an ADMA2 descriptor DMA): concurrent SVA
// against independent decoders of the card bus and a model of the ADMA2
// walk, + functional coverage. All bus bits are taken at sd_clk rises.
//  - CMD: after C_START the host's 48-bit command {0, 1, index, argument,
//    CRC7, 1} (CRC7 computed here); then the card's 48- or 136-bit response,
//    or none within 80 clocks. At CMD_DONE: RSP0..3 hold the response bits,
//    C_ERR[3:0] = {framing, index, CRC7, no response} as decoded here.
//  - DAT, writes: each block the host sends (start bit, BLKSZ bytes on 1, 4
//    or 8 lines MSB first, bytes in address order, a CRC16 per line, end
//    bit) must carry the words the DMA read from memory, in order, with the
//    right CRC16 on every line; then the card's CRC status token and busy.
//  - DAT, reads: the words of each block the card sends (CRC16 and end bit
//    checked here: D_ERR[1] / D_ERR[2] must follow) are the words the DMA
//    writes to memory, in order.
//  - ADMA2: every descriptor fetch is at the address the walk predicts
//    (ADMA_ADDR, + 8, or a link's address), each tran job moves min(length,
//    words left) to / from its address, DMA_INT pulses for int descriptors,
//    and D_ERR[6:4] (invalid / unaligned descriptor, AXI error, table ended)
//    are the walk's own errors when the card side had none.
// The engine is closed by its own run.
`include "cov_macros.svh"
module SDMMC_ADMA_sva (
  input logic        clk, rst_n, sd_clk, cmd, clk_en, dat_reset,
  input logic [7:0]  dat,
  input logic [9:0]  clk_div,
  input logic [1:0]  bus_w, c_rsp, c_data,
  input logic [11:0] blksz,
  input logic [15:0] blkcnt,
  input logic [31:0] adma_addr, c_arg, rsp0, rsp1, rsp2, rsp3,
  input logic [5:0]  c_idx,
  input logic        c_crc_chk, c_idx_chk, c_start, cmd_busy, dat_busy, cmd_done, cmd_err,
  input logic        xfer_done, xfer_err, dma_int,
  input logic [4:0]  c_err,
  input logic [7:0]  d_err,
  input logic [15:0] blk_done,
  input logic        c_go, a_data, drop, dir_rd, hold,
  input logic        e_start, e_rd, e_wr, e_done, e_err,
  input logic [31:0] e_src, e_dst,
  input logic [15:0] e_len,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  function automatic logic [6:0] c7(input logic [6:0] c, input logic b);
    c7 = {c[5:0], 1'b0} ^ ((b ^ c[6]) ? 7'h09 : 7'h00);
  endfunction
  function automatic logic [15:0] c16(input logic [15:0] c, input logic b);
    c16 = {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0000);
  endfunction
  function automatic logic [31:0] bsw(input logic [31:0] w); bsw = {w[7:0], w[15:8], w[23:16], w[31:24]}; endfunction

  logic       sclk_q, cmd_q;
  logic [7:0] dat_q;
  wire        sr = sd_clk && !sclk_q;          // a rise happened at the last clock: cmd_q / dat_q are its bits
  wire        cb = (cmd_q !== 1'b0);
  wire  [7:0] db;
  for (genvar g = 0; g < 8; g++) begin : g_db assign db[g] = (dat_q[g] !== 1'b0); end
  wire        dgo = c_go && c_data != 0;

  // ---------------------------------------------------------------- CMD
  logic [2:0]   cm;                // 0 idle, 1 host hunt, 2 host bits, 3 response hunt, 4 response bits
  int           cn;
  logic [47:0]  c_exp, c_got;
  logic [1:0]   c_rt;
  logic         c_cc, c_ic, c_long;
  logic [5:0]   c_ix;
  logic [134:0] r_got;
  logic [6:0]   r_crc;
  logic [3:0]   m_cerr;
  logic [127:0] m_rsp;
  logic         m_rsp_long, m_rsp_v;
  logic         m_done;            // the model has decoded a response or timed out
  logic         chk_cmd;           // the host's command has just been decoded
  wire  [39:0]  c_body = {2'b01, c_idx, c_arg};
  logic [6:0]   c_body_crc;
  always_comb begin
    c_body_crc = 0;
    for (int i = 39; i >= 0; i--) c_body_crc = c7(c_body_crc, c_body[i]);
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_q <= 0; cmd_q <= 1; dat_q <= 8'hFF; cm <= 0; cn <= 0; c_exp <= 0; c_got <= 0; c_rt <= 0;
      c_cc <= 0; c_ic <= 0; c_long <= 0; c_ix <= 0; r_got <= 0; r_crc <= 0; m_cerr <= 0; m_rsp <= 0;
      m_rsp_long <= 0; m_rsp_v <= 0; chk_cmd <= 0; m_done <= 0;
    end else begin
      sclk_q <= sd_clk; cmd_q <= cmd; dat_q <= dat; chk_cmd <= 0; m_done <= 0;
      if (c_go) begin
        cm <= 1; c_exp <= {c_body, c_body_crc, 1'b1}; c_rt <= c_rsp; c_cc <= c_crc_chk; c_ic <= c_idx_chk;
        c_ix <= c_idx; c_long <= c_rsp == 2; m_cerr <= 0; m_rsp_v <= 0;
      end else if (sr) begin
        case (cm)
          1: if (!cb) begin cm <= 2; cn <= 1; c_got <= 48'd0; end
          2: begin
            c_got <= {c_got[46:0], cb}; cn <= cn + 1;
            if (cn == 47) begin chk_cmd <= 1; cm <= (c_rt == 0) ? 3'd0 : 3'd3; cn <= 0; end
          end
          3: begin
            cn <= cn + 1;
            if (cn != 0 && !cb) begin cm <= 4; cn <= 1; r_got <= 0; r_crc <= c7(7'd0, 1'b0); end
            else if (cn == 80) begin cm <= 0; m_cerr <= 4'b0001; m_done <= 1; end
          end
          4: begin
            logic [134:0] r;
            logic [3:0]   e;
            r = {r_got[133:0], cb};
            r_got <= r; cn <= cn + 1;
            // CRC7: bits 0..39 of a short response (start bit included above),
            // bits 8..127 of a long one
            if (c_long ? (cn >= 8 && cn <= 127) : (cn <= 39)) r_crc <= c7(c_long && cn == 8 ? 7'd0 : r_crc, cb);
            if (cn == (c_long ? 135 : 47)) begin
              e = 0;
              if (c_cc && r[7:1] != r_crc) e[1] = 1;
              if (c_ic && !c_long && r[45:40] != c_ix) e[2] = 1;
              if (!r[0] || (c_long ? r[134] : r[46])) e[3] = 1;
              m_cerr <= e; m_rsp <= c_long ? r[127:0] : {96'd0, r[39:8]}; m_rsp_long <= c_long; m_rsp_v <= 1; cm <= 0; m_done <= 1;
            end
          end
          default: ;
        endcase
      end
    end
  end
  `SVA_IMP(a_cmd_frame, chk_cmd, c_got == c_exp)
  `SVA_IMP(a_cmd_errors, m_done, c_err[3:0] == m_cerr)   // the model samples the lines one SD_CLK late: check when it ends
  `SVA_IMP(a_rsp, m_done && m_rsp_v, m_rsp_long ? {rsp3, rsp2, rsp1, rsp0} == m_rsp : rsp0 == m_rsp[31:0])

  // ---------------------------------------------------------------- DAT
  logic [2:0]   dm;               // 0 idle, 1 hunt block, 2 data, 3 crc, 4 end bit, 5 token hunt, 6 token, 7 busy
  logic [1:0]   w;                // bus width of the transfer
  logic         rd;
  int           dn, dk, bwords;
  logic [31:0]  sh;
  int           shn;
  logic [15:0]  crc_c [8], crc_r [8];
  logic [31:0]  q_mem [$];        // writes: words read from memory; reads: words from the card
  logic         chk_w, chk_w_ok, chk_blk, chk_blk_crc_ok, chk_blk_end_ok;
  logic [31:0]  chk_w_got, chk_w_exp;
  logic         m_rd_crc_err, m_rd_end_err;
  wire  [7:0]   lm = (w == 2) ? 8'hFF : (w == 1) ? 8'h0F : 8'h01;
  wire  [3:0]   bpc = (w == 2) ? 4'd8 : (w == 1) ? 4'd4 : 4'd1;    // bits per clock
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dm <= 0; w <= 0; rd <= 0; dn <= 0; dk <= 0; bwords <= 0; sh <= 0; shn <= 0; q_mem.delete();
      chk_w <= 0; chk_w_ok <= 0; chk_blk <= 0; chk_blk_crc_ok <= 0; chk_blk_end_ok <= 0; chk_w_got <= 0; chk_w_exp <= 0;
      m_rd_crc_err <= 0; m_rd_end_err <= 0;
      for (int l = 0; l < 8; l++) begin crc_c[l] <= 0; crc_r[l] <= 0; end
    end else begin
      chk_w <= 0; chk_blk <= 0;
      // memory side of the data jobs
      if (a_data && rs_valid && rs_ready && !drop && !rd) q_mem.push_back(rs_data);
      if (a_data && ws_valid && ws_ready && !drop && rd) begin
        chk_w <= 1; chk_w_got <= ws_data; chk_w_exp <= q_mem.size() ? q_mem[0] : 32'hxxxx_xxxx;
        chk_w_ok <= q_mem.size() != 0 && ws_data == q_mem[0];
        if (q_mem.size()) void'(q_mem.pop_front());
      end
      if (dgo) begin
        dm <= 1; w <= bus_w; rd <= c_data == 1; bwords <= int'(blksz[9:2]); q_mem.delete();
        m_rd_crc_err <= 0; m_rd_end_err <= 0;
      end else if (xfer_done || dat_reset) dm <= 0;      // DAT_RESET aborts the block
      else if (sr) begin
        case (dm)
          1: if (!db[0]) begin
            dm <= 2; dn <= 0; shn <= 0; sh <= 0;
            for (int l = 0; l < 8; l++) crc_c[l] <= 0;
          end
          2: begin
            logic [31:0] s;
            int n;
            s = sh; n = shn;
            for (int b = int'(bpc) - 1; b >= 0; b--) begin s = {s[30:0], db[b]}; n++; end
            for (int l = 0; l < 8; l++) if (lm[l]) crc_c[l] <= c16(crc_c[l], db[l]);
            if (n == 32) begin
              n = 0;
              if (!rd) begin
                chk_w <= 1; chk_w_got <= bsw(s); chk_w_exp <= q_mem.size() ? q_mem[0] : 32'hxxxx_xxxx;
                chk_w_ok <= q_mem.size() != 0 && bsw(s) == q_mem[0];
                if (q_mem.size()) void'(q_mem.pop_front());
              end else q_mem.push_back(bsw(s));
              dn <= dn + 1;
              if (dn + 1 == bwords) begin dm <= 3; dk <= 0; end
            end
            sh <= s; shn <= n;
          end
          3: begin
            for (int l = 0; l < 8; l++) crc_r[l] <= {crc_r[l][14:0], db[l]};
            dk <= dk + 1;
            if (dk == 15) dm <= 4;
          end
          4: begin
            logic ok;
            ok = 1;
            for (int l = 0; l < 8; l++) if (lm[l] && crc_r[l] != crc_c[l]) ok = 0;
            chk_blk <= 1; chk_blk_crc_ok <= ok; chk_blk_end_ok <= (db & lm) == lm;
            if (rd) begin
              if (!ok) m_rd_crc_err <= 1;
              if ((db & lm) != lm) m_rd_end_err <= 1;
              dm <= 1;
            end else begin dm <= 5; dk <= 0; end
          end
          5: if (!db[0]) begin dm <= 6; dk <= 0; end
          6: begin dk <= dk + 1; if (dk == 3) dm <= 7; end
          7: if (db[0]) dm <= 1;
          default: ;
        endcase
      end
    end
  end
  `SVA_IMP(a_data_word, chk_w, chk_w_ok)
  `SVA_IMP(a_wr_block_crc, chk_blk && !rd, chk_blk_crc_ok && chk_blk_end_ok)
  `SVA_IMP(a_rd_errors, xfer_done && rd && (d_err & 8'hF9) == 0, d_err[2:1] == {m_rd_end_err, m_rd_crc_err})

  // ---------------------------------------------------------------- ADMA2 walk
  logic [31:0] a_desc, a_w0, a_w1;
  logic        a_wn, a_on, a_fetch;
  int          a_rem;
  logic [7:0]  a_err;
  logic        a_exp_job;                // a tran job is due
  int          a_job_w;
  wire  [16:0] lb = (a_w0[31:16] == 0) ? 17'h10000 : {1'b0, a_w0[31:16]};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_desc <= 0; a_w0 <= 0; a_w1 <= 0; a_wn <= 0; a_on <= 0; a_fetch <= 0; a_rem <= 0; a_err <= 0;
      a_exp_job <= 0; a_job_w <= 0;
    end else begin
      if (dgo) begin
        a_desc <= adma_addr; a_on <= 1; a_rem <= int'(blksz[9:2]) * ((blkcnt == 0) ? 1 : int'(blkcnt)); a_err <= 0;
        a_exp_job <= 0; a_fetch <= 0;
        if (adma_addr[1:0] != 0) begin a_err <= 8'h10; a_on <= 0; end
      end else if (a_on) begin
        if (e_start && !a_data) begin a_fetch <= 1; a_wn <= 0; end
        if (a_fetch && rs_valid && rs_ready) begin if (!a_wn) a_w0 <= rs_data; else a_w1 <= rs_data; a_wn <= 1; end
        if (a_fetch && e_done) begin
          a_fetch <= 0;
          if (e_err) begin a_err <= 8'h20; a_on <= 0; end
          else if (!a_w0[0] || (a_w0[5:4] == 2 && (a_w1[1:0] != 0 || a_w0[17:16] != 0)) || (a_w0[5:4] == 3 && a_w1[1:0] != 0)) begin
            a_err <= 8'h10; a_on <= 0;
          end else if (a_w0[5:4] == 3) begin
            a_desc <= a_w1;
            if (a_w1[1:0] != 0) begin a_err <= 8'h10; a_on <= 0; end
          end else if (a_w0[5:4] == 2) begin
            a_exp_job <= 1; a_job_w <= (int'(lb[16:2]) < a_rem) ? int'(lb[16:2]) : a_rem;
          end else if (a_w0[1]) begin a_err <= 8'h40; a_on <= 0; end
          else a_desc <= a_desc + 8;
        end
        if (e_start && a_data) begin a_exp_job <= 0; a_rem <= a_rem - a_job_w; end
        if (!a_fetch && a_data && e_done) begin
          if (e_err) begin a_err <= 8'h20; a_on <= 0; end
          else if (a_rem == 0) a_on <= 0;
          else if (a_w0[1]) begin a_err <= 8'h40; a_on <= 0; end
          else a_desc <= a_desc + 8;
        end
      end
    end
  end
  `SVA_IMP(a_fetch_addr, e_start && !a_data, e_src == a_desc && e_len == 2 && e_rd && !e_wr && a_on && !a_exp_job)
  `SVA_IMP(a_tran_job, e_start && a_data, a_exp_job && e_src == a_w1 && e_dst == a_w1 && e_len == 16'(a_job_w)
                                          && e_rd == !dir_rd && e_wr == dir_rd)
  `SVA_IMP(a_dma_errors, xfer_done && (d_err & 8'h8F) == 0, (d_err & 8'h70) == a_err)

  // ---------------------------------------------------------------- coverage
  covergroup cg_sdmmc @(posedge clk);
    option.per_instance = 1;
    cp_rsp: coverpoint c_rsp iff (rst_n && c_go);
    cp_cerr: coverpoint c_err iff (rst_n && cmd_done && cmd_err)
      { bins none_ = {5'b00001}; bins crc = {5'b00010}; bins idx = {5'b00100}; bins frame = {[5'b01000:5'b01111]}; bins busy_to = {5'b10000}; }
    cp_xfer: coverpoint {c_data, bus_w} iff (rst_n && dgo)
      { bins rd[] = {4'b0100, 4'b0101, 4'b0110}; bins wr[] = {4'b1000, 4'b1001, 4'b1010}; }
    cp_blocks: coverpoint blkcnt iff (rst_n && dgo) { bins zero = {0}; bins one = {1}; bins many = {[2:16'hFFFF]}; }
    cp_derr: coverpoint d_err iff (rst_n && xfer_done && xfer_err)
      { bins dto = {8'h01}; bins rcrc = {8'h02}; bins wtok = {8'h08}; bins desc = {8'h10}; bins axi = {8'h20}; bins table_end = {8'h40};
        bins cmd_fail = {[8'h80:8'hFF]}; bins reset = {0}; }
    cp_desc: coverpoint a_w0[5:4] iff (rst_n && a_on && a_fetch && e_done && !e_err && a_w0[0])
      { bins nop = {0}; bins reserved = {1}; bins tran_ = {2}; bins link = {3}; }
    cp_int: coverpoint a_w0[2] iff (rst_n && a_on && a_fetch && e_done && !e_err && a_w0[0]);
    cp_div: coverpoint clk_div iff (rst_n && c_go) { bins zero = {0}; bins small_ = {[1:7]}; bins big = {[8:1023]}; }
  endgroup
  cg_sdmmc u_cg_sdmmc = new;

  `FC(clock_stopped_buffer_full, hold && clk_en && dat_busy)
  `FC(tran_capped, e_start && a_data && a_job_w < int'(lb[16:2]))
  `FC(tran_len_65536, a_fetch && e_done && a_w0[5:4] == 2 && a_w0[31:16] == 0)
  `FC(cmd_during_transfer, c_go && c_data == 0 && dat_busy)
  `FC(data_cmd_blocked, c_start && c_data != 0 && dat_busy && !cmd_busy)
  `FC(dat_reset_mid, dat_reset && dat_busy)
  `FC(clk_gated, !clk_en && dat_busy)
  `FC_RST(reset_mid_transfer, rst_n && dat_busy ##1 !rst_n)
endmodule

bind SDMMC_ADMA_top SDMMC_ADMA_sva u_sva (.*);
