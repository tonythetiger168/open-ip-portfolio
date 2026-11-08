// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SDMMC_ADMA: SD / eMMC host controller with an ADMA2 descriptor DMA (AXI4
// manager)
// ----------------------------------------------------------------------------
// The software-driven host that the fixed-sequence SD_top / eMMC_top demos
// do not cover (SD card and eMMC storage of the IP camera SoC). One IP for
// both: the card protocol (CMD0 / CMD8 / ACMD41 or CMD1, CMD2, CMD3, ...)
// is run by software, one command at a time.
// - Bus: sd_clk, CMD, DAT[7:0] (1-, 4- or 8-bit data, BUS_W 0 / 1 / 2).
//   Half an sd_clk period is CLK_DIV + 1 clocks; CLK_EN gates it. The host
//   samples CMD / DAT at the rising sd_clk edge and changes them at the
//   falling edge.
// - Command: C_IDX, C_ARG, C_RSP (0 none, 1 48-bit, 2 136-bit, 3 48-bit +
//   busy on DAT0), C_CRC_CHK (CRC7), C_IDX_CHK (index echo); C_START sends
//   it (ignored while CMD_BUSY, or while DAT_BUSY for a data command).
//   RSP0..3: a 48-bit response's argument in RSP0; a 136-bit response's
//   bits 127:0 (CID / CSD with the end bit in bit 0) in RSP3..RSP0.
//   C_ERR: bit 0 no response within 80 clocks, 1 CRC7, 2 index, 3 framing
//   (transmission or end bit), 4 busy longer than DTO clocks. CMD_DONE
//   pulses when the command (and its busy) ends, CMD_ERR as well on an
//   error.
// - Data (C_DATA 1 read, 2 write): BLKCNT blocks (0 counts as 1) of BLKSZ
//   bytes (a multiple of 4, 4..1020), per-line CRC16, the CRC status token
//   and the busy after each write block. Read data is accepted from when
//   the command starts; write data starts 2 clocks after the response. A
//   read block starts only when the 256-word buffer has room for it:
//   otherwise sd_clk stops (low) at the block boundary, so the card never
//   overruns it. Bytes are little-endian in a memory word and go out in
//   address order, MSB first.
// - ADMA2 (32-bit): ADMA_ADDR points at 8-byte descriptors {word 0: bit 0
//   valid, 1 end, 2 int, 5:4 act (00 nop, 01 reserved, 10 tran, 11 link),
//   31:16 length in bytes (0 = 65536); word 1: address}. tran moves its
//   length (capped at what the transfer still needs) to / from its
//   address, link continues at its address, nop / reserved skip. int
//   pulses DMA_INT when the descriptor is done. Addresses and lengths must
//   be word aligned. The transfer ends when BLKSZ * BLKCNT bytes have
//   moved, even before an end descriptor.
// - D_ERR: 0 data timeout (DTO sd_clk periods with no start bit, CRC
//   status or busy release), 1 read CRC16, 2 end bit, 3 write CRC status
//   not "010", 4 invalid or unaligned descriptor, 5 AXI error response, 6
//   descriptor table ended before the transfer, 7 the data command failed.
//   Any of them, or DAT_RESET, aborts the transfer: the DMA job in progress
//   is finished with dummy data and nothing more is fetched. XFER_DONE
//   pulses when the transfer has ended (for a read: when the last word is
//   in memory), XFER_ERR as well on an abort. Software ends an open-ended
//   multiple-block transfer with CMD12.
// - AXI4 manager through soc_ss_axi_engine: ID AXI_ID, INCR bursts of up to
//   16 beats, never across 4 KB.
// ============================================================================
module SDMMC_ADMA_top #(
  parameter logic [3:0] AXI_ID = 4'd11
) (
  input  logic        clk,
  input  logic        rst_n,
  // card bus
  output logic        sd_clk,
  inout  tri          cmd,
  inout  tri   [7:0]  dat,
  // configuration
  input  logic [9:0]  clk_div,
  input  logic        clk_en,
  input  logic [1:0]  bus_w,
  input  logic [11:0] blksz,
  input  logic [15:0] blkcnt,
  input  logic [23:0] dto,
  input  logic [31:0] adma_addr,
  // command
  input  logic [5:0]  c_idx,
  input  logic [31:0] c_arg,
  input  logic [1:0]  c_rsp,
  input  logic        c_crc_chk,
  input  logic        c_idx_chk,
  input  logic [1:0]  c_data,
  input  logic        c_start,
  input  logic        dat_reset,
  output logic [31:0] rsp0,
  output logic [31:0] rsp1,
  output logic [31:0] rsp2,
  output logic [31:0] rsp3,
  output logic        cmd_busy,
  output logic        dat_busy,
  output logic [4:0]  c_err,
  output logic [7:0]  d_err,
  output logic [15:0] blk_done,
  output logic [31:0] adma_cur,
  output logic        cmd_done,
  output logic        cmd_err,
  output logic        xfer_done,
  output logic        xfer_err,
  output logic        dma_int,
  // AXI4 manager (m_*)
  output logic [3:0]  m_awid,
  output logic [31:0] m_awaddr,
  output logic [7:0]  m_awlen,
  output logic [2:0]  m_awsize,
  output logic [1:0]  m_awburst,
  output logic [2:0]  m_awprot,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wlast,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [3:0]  m_bid,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,
  output logic [3:0]  m_arid,
  output logic [31:0] m_araddr,
  output logic [7:0]  m_arlen,
  output logic [2:0]  m_arsize,
  output logic [1:0]  m_arburst,
  output logic [2:0]  m_arprot,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [3:0]  m_rid,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rlast,
  input  logic        m_rvalid,
  output logic        m_rready
);
  function automatic logic [15:0] c16(input logic [15:0] c, input logic b);
    c16 = {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0000);
  endfunction
  function automatic logic [6:0] c7(input logic [6:0] c, input logic b);
    c7 = {c[5:0], 1'b0} ^ ((b ^ c[6]) ? 7'h09 : 7'h00);
  endfunction
  function automatic logic [31:0] bswap(input logic [31:0] w);
    bswap = {w[7:0], w[15:8], w[23:16], w[31:24]};
  endfunction

  // ------------------------------------------------------------ sd_clk
  logic [9:0] ccnt;
  logic       hold;                      // data engine: stop sd_clk (low)
  wire        run  = clk_en && !(hold && !sd_clk);
  wire        tgl  = run && (ccnt == clk_div);
  wire        rise = tgl && !sd_clk;
  wire        fall = tgl && sd_clk;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ccnt <= '0; sd_clk <= 1'b0; end
    else if (!run) ccnt <= '0;
    else if (tgl) begin ccnt <= '0; sd_clk <= ~sd_clk; end
    else ccnt <= ccnt + 10'd1;
  end

  // pins: values chosen at a rise go out at the next fall
  logic       cmd_o_r, cmd_oe_r, cmd_o_p, cmd_oe_p;
  logic [7:0] dat_o_r, dat_oe_r, dat_o_p, dat_oe_p;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin cmd_o_p <= 1'b1; cmd_oe_p <= 1'b0; dat_o_p <= 8'hFF; dat_oe_p <= 8'h00; end
    else if (fall) begin cmd_o_p <= cmd_o_r; cmd_oe_p <= cmd_oe_r; dat_o_p <= dat_o_r; dat_oe_p <= dat_oe_r; end
  end
  assign cmd = cmd_oe_p ? cmd_o_p : 1'bz;
  genvar gi;
  generate for (gi = 0; gi < 8; gi++) begin : g_dat
    assign dat[gi] = dat_oe_p[gi] ? dat_o_p[gi] : 1'bz;
  end endgenerate
  wire       cmd_i = cmd;
  wire [7:0] dat_i = dat;

  // ------------------------------------------------------------ command engine
  typedef enum logic [2:0] {C_IDLE, C_TX, C_HUNT, C_RX, C_BGAP, C_BUSY} cs_t;
  cs_t         cs;
  logic [47:0] c_sh;
  logic [7:0]  c_n;
  logic [6:0]  c_crc;
  logic [134:0] r_sh;
  logic [1:0]  rsp_q;
  logic        crc_chk_q, idx_chk_q;
  logic [5:0]  idx_q;
  logic [23:0] c_to;
  logic        cmd_ok_pulse;           // the command ended without error
  wire  [134:0] r_nx = {r_sh[133:0], cmd_i};
  wire  [39:0] c_body = {2'b01, c_idx, c_arg};
  logic [6:0]  c_body_crc;
  always_comb begin
    c_body_crc = 7'd0;
    for (int i = 39; i >= 0; i--) c_body_crc = c7(c_body_crc, c_body[i]);
  end
  logic [4:0]  e;                       // response checks (blocking temp)
  wire c_go = c_start && cs == C_IDLE && !(c_data != 2'd0 && dat_busy);
  assign cmd_busy = (cs != C_IDLE);
  wire r_long = (rsp_q == 2'd2);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs <= C_IDLE; c_sh <= '0; c_n <= '0; c_crc <= '0; r_sh <= '0; rsp_q <= '0;
      crc_chk_q <= 1'b0; idx_chk_q <= 1'b0; idx_q <= '0; c_to <= '0; cmd_o_r <= 1'b1; cmd_oe_r <= 1'b0;
      rsp0 <= '0; rsp1 <= '0; rsp2 <= '0; rsp3 <= '0; c_err <= '0;
      cmd_done <= 1'b0; cmd_err <= 1'b0; cmd_ok_pulse <= 1'b0;
    end else begin
      cmd_done <= 1'b0; cmd_err <= 1'b0; cmd_ok_pulse <= 1'b0;
      if (c_go) begin
        cs <= C_TX; c_sh <= {c_body, c_body_crc, 1'b1}; c_n <= 8'd0; rsp_q <= c_rsp;
        crc_chk_q <= c_crc_chk; idx_chk_q <= c_idx_chk; idx_q <= c_idx; c_err <= '0;
      end else if (rise) begin
        case (cs)
          C_TX: begin
            cmd_oe_r <= 1'b1; cmd_o_r <= c_sh[47]; c_sh <= {c_sh[46:0], 1'b1};
            c_n <= c_n + 8'd1;
            if (c_n == 8'd47) begin cs <= C_HUNT; c_n <= 8'd0; end
          end
          C_HUNT: begin
            cmd_oe_r <= 1'b0; cmd_o_r <= 1'b1;
            if (rsp_q == 2'd0) begin
              cs <= C_IDLE; cmd_done <= 1'b1; cmd_ok_pulse <= 1'b1;
            end else if (c_n != 8'd0 && cmd_i == 1'b0) begin     // start bit (not in the end bit's clock)
              cs <= C_RX; c_n <= 8'd1; c_crc <= 7'd0; r_sh <= '0;
            end else if (c_n == 8'd80) begin
              cs <= C_IDLE; c_err[0] <= 1'b1; cmd_done <= 1'b1; cmd_err <= 1'b1;
            end else c_n <= c_n + 8'd1;
          end
          C_RX: begin
            r_sh <= r_nx; c_n <= c_n + 8'd1;
            if (r_long ? (c_n >= 8'd8 && c_n <= 8'd127) : (c_n <= 8'd39)) c_crc <= c7(c_crc, cmd_i);
            if (c_n == (r_long ? 8'd135 : 8'd47)) begin
              e = 5'd0;
              if (crc_chk_q && r_nx[7:1] != c_crc) e[1] = 1'b1;
              if (idx_chk_q && !r_long && r_nx[45:40] != idx_q) e[2] = 1'b1;
              if (!r_nx[0] || (r_long ? r_nx[134] : r_nx[46])) e[3] = 1'b1;
              c_err <= e;
              if (r_long) begin rsp0 <= r_nx[31:0]; rsp1 <= r_nx[63:32]; rsp2 <= r_nx[95:64]; rsp3 <= r_nx[127:96]; end
              else rsp0 <= r_nx[39:8];
              if (e != 5'd0) begin cs <= C_IDLE; cmd_done <= 1'b1; cmd_err <= 1'b1; end
              else if (rsp_q == 2'd3) begin cs <= C_BGAP; c_n <= 8'd0; c_to <= '0; end
              else begin cs <= C_IDLE; cmd_done <= 1'b1; cmd_ok_pulse <= 1'b1; end
            end
          end
          C_BGAP: begin c_n <= c_n + 8'd1; if (c_n == 8'd1) cs <= C_BUSY; end
          C_BUSY: begin
            c_to <= c_to + 24'd1;
            if (dat_i[0]) begin cs <= C_IDLE; cmd_done <= 1'b1; cmd_ok_pulse <= 1'b1; end
            else if (c_to == dto) begin cs <= C_IDLE; c_err[4] <= 1'b1; cmd_done <= 1'b1; cmd_err <= 1'b1; end
          end
          default: cs <= C_IDLE;
        endcase
      end
    end
  end

  // ------------------------------------------------------------ data buffer
  logic [31:0] fifo [0:255];
  logic [7:0]  fwp, frp;
  logic [8:0]  fcnt;
  logic        f_push, f_pop, f_flush;
  logic [31:0] f_din;
  wire  [31:0] f_head = fifo[frp];
  always_ff @(posedge clk) if (f_push) fifo[fwp] <= f_din;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin fwp <= '0; frp <= '0; fcnt <= '0; end
    else if (f_flush) begin fwp <= '0; frp <= '0; fcnt <= '0; end
    else begin
      if (f_push) fwp <= fwp + 8'd1;
      if (f_pop)  frp <= frp + 8'd1;
      fcnt <= fcnt + {8'd0, f_push} - {8'd0, f_pop};
    end
  end

  // ------------------------------------------------------------ data engine
  typedef enum logic [3:0] {D_IDLE, D_RWAIT, D_RDATA, D_RCRC, D_REND, D_WCMD, D_WGAP, D_WRDY,
                            D_WDATA, D_WCRC, D_WEND, D_WTOKH, D_WTOK, D_WBUSY, D_DONE, D_ABORT} ds_t;
  ds_t          ds;
  logic         dir_rd;                // transfer direction: card to memory
  logic [1:0]   w_q;
  logic [7:0]   lmask;
  logic [7:0]   bw_q;                  // words per block
  logic [15:0]  bc_q;                  // blocks
  logic [7:0]   widx;                  // word in block
  logic [4:0]   wcnt;                  // clock in word
  logic [4:0]   wlast;
  logic [31:0]  sh;                    // bus-order shift register
  logic [127:0] crc_a, rc_a;           // per-line CRC16: computed, received
  logic [4:0]   k;
  logic [2:0]   tok;
  logic [23:0]  d_to;
  logic         abort_req;             // from the DMA side or DAT_RESET
  logic         ae_idle;
  logic         d_push;
  logic [31:0]  d_word;
  logic [7:0]   d_out;
  logic [31:0]  sh_rd;
  logic         d_pop;
  assign dat_busy = (ds != D_IDLE);
  wire [8:0] room = 9'd256 - fcnt;
  assign hold = (ds == D_RWAIT) && (room < {1'b0, bw_q});

  // bits of the next clock (write) and the word assembled (read)
  always_comb begin
    case (w_q)
      2'd2:    begin d_out = sh[31:24];          sh_rd = {sh[23:0], dat_i}; end
      2'd1:    begin d_out = {4'hF, sh[31:28]};  sh_rd = {sh[27:0], dat_i[3:0]}; end
      default: begin d_out = {7'h7F, sh[31]};    sh_rd = {sh[30:0], dat_i[0]}; end
    endcase
  end

  logic [7:0] d_errs;                  // errors raised this clock (data side)
  logic       own_cmd;                 // the transfer's command is still running
  logic       dma_err_set;             // from the ADMA engine
  logic [7:0] dma_err_bits;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ds <= D_IDLE; dir_rd <= 1'b0; w_q <= '0; lmask <= 8'h01; bw_q <= '0; bc_q <= '0;
      widx <= '0; wcnt <= '0; wlast <= '0; sh <= '0; crc_a <= '0; rc_a <= '0; k <= '0; tok <= '0;
      d_to <= '0; dat_o_r <= 8'hFF; dat_oe_r <= 8'h00; d_err <= '0; blk_done <= '0;
      xfer_done <= 1'b0; xfer_err <= 1'b0; d_push <= 1'b0; d_word <= '0; own_cmd <= 1'b0;
    end else begin
      xfer_done <= 1'b0; xfer_err <= 1'b0; d_push <= 1'b0;
      d_errs = 8'd0;
      if (c_go && c_data != 2'd0) begin
        dir_rd <= (c_data == 2'd1); w_q <= bus_w;
        lmask <= (bus_w == 2'd2) ? 8'hFF : (bus_w == 2'd1) ? 8'h0F : 8'h01;
        wlast <= (bus_w == 2'd2) ? 5'd3 : (bus_w == 2'd1) ? 5'd7 : 5'd31;
        bw_q <= blksz[9:2]; bc_q <= (blkcnt == 16'd0) ? 16'd1 : blkcnt;
        d_err <= '0; blk_done <= '0; d_to <= '0; own_cmd <= 1'b1;
        if (c_data == 2'd1) ds <= D_RWAIT; else ds <= D_WCMD;
      end else if (ds != D_IDLE && ds != D_ABORT && ds != D_DONE && (abort_req || dma_err_set)) begin
        ds <= D_ABORT; dat_oe_r <= 8'h00;
      end else begin
        case (ds)
          D_DONE: if (ae_idle) begin ds <= D_IDLE; xfer_done <= 1'b1; xfer_err <= (d_err != 8'd0) || dma_err_set; end
          D_ABORT: if (ae_idle) begin ds <= D_IDLE; xfer_done <= 1'b1; xfer_err <= 1'b1; end
          D_WCMD: if (cmd_done && cmd_ok_pulse) begin ds <= D_WGAP; k <= '0; end
          default: ;
        endcase
        if (own_cmd && cmd_done) begin
          own_cmd <= 1'b0;
          if (cmd_err) d_errs[7] = 1'b1;              // the data command failed
        end
        if (rise) begin
          case (ds)
            // ------------------------------------------------ read
            D_RWAIT: begin
              d_to <= d_to + 24'd1;
              if (dat_i[0] == 1'b0) begin
                ds <= D_RDATA; widx <= '0; wcnt <= '0; crc_a <= '0; d_to <= '0;
              end else if (d_to == dto) d_errs[0] = 1'b1;
            end
            D_RDATA: begin
              for (int l = 0; l < 8; l++)
                if (lmask[l]) crc_a[16 * l +: 16] <= c16(crc_a[16 * l +: 16], dat_i[l]);
              sh <= sh_rd; wcnt <= wcnt + 5'd1;
              if (wcnt == wlast) begin
                wcnt <= '0; d_push <= 1'b1; d_word <= bswap(sh_rd); widx <= widx + 8'd1;
                if (widx == bw_q - 8'd1) begin ds <= D_RCRC; k <= '0; end
              end
            end
            D_RCRC: begin
              for (int l = 0; l < 8; l++) rc_a[16 * l +: 16] <= {rc_a[16 * l +: 15], dat_i[l]};
              k <= k + 5'd1;
              if (k == 5'd15) ds <= D_REND;
            end
            D_REND: begin
              for (int l = 0; l < 8; l++) if (lmask[l] && rc_a[16 * l +: 16] != crc_a[16 * l +: 16]) d_errs[1] = 1'b1;
              if ((dat_i & lmask) != lmask) d_errs[2] = 1'b1;
              blk_done <= blk_done + 16'd1;
              if (blk_done + 16'd1 == bc_q) ds <= D_DONE;
              else begin ds <= D_RWAIT; d_to <= '0; end
            end
            // ------------------------------------------------ write
            D_WGAP: begin dat_oe_r <= 8'h00; k <= k + 5'd1; if (k == 5'd1) ds <= D_WRDY; end
            D_WRDY: if (fcnt >= {1'b0, bw_q}) begin
              dat_oe_r <= lmask; dat_o_r <= 8'h00;           // start bit
              sh <= bswap(f_head); widx <= '0; wcnt <= '0; crc_a <= '0; ds <= D_WDATA;
            end
            D_WDATA: begin
              dat_o_r <= d_out;
              for (int l = 0; l < 8; l++)
                if (lmask[l]) crc_a[16 * l +: 16] <= c16(crc_a[16 * l +: 16], d_out[l]);
              wcnt <= wcnt + 5'd1;
              case (w_q)
                2'd2:    sh <= {sh[23:0], 8'h00};
                2'd1:    sh <= {sh[27:0], 4'h0};
                default: sh <= {sh[30:0], 1'b0};
              endcase
              if (wcnt == wlast) begin
                wcnt <= '0; widx <= widx + 8'd1;
                if (widx == bw_q - 8'd1) begin ds <= D_WCRC; k <= '0; end
                else sh <= bswap(f_head);
              end
            end
            D_WCRC: begin
              for (int l = 0; l < 8; l++) begin
                dat_o_r[l] <= crc_a[16 * l + 15];
                crc_a[16 * l +: 16] <= {crc_a[16 * l +: 15], 1'b0};
              end
              k <= k + 5'd1;
              if (k == 5'd15) ds <= D_WEND;
            end
            D_WEND: begin                                    // end bit, then release
              k <= k + 5'd1;
              if (k == 5'd16) dat_o_r <= 8'hFF;
              else begin dat_oe_r <= 8'h00; ds <= D_WTOKH; d_to <= '0; end
            end
            D_WTOKH: begin
              d_to <= d_to + 24'd1;
              if (dat_i[0] == 1'b0) begin ds <= D_WTOK; k <= '0; end
              else if (d_to == dto) d_errs[0] = 1'b1;
            end
            D_WTOK: begin
              k <= k + 5'd1;
              if (k < 5'd3) tok <= {tok[1:0], dat_i[0]};
              else begin
                if (tok != 3'b010 || !dat_i[0]) d_errs[3] = 1'b1;
                else begin ds <= D_WBUSY; d_to <= '0; end
              end
            end
            D_WBUSY: begin
              d_to <= d_to + 24'd1;
              if (dat_i[0]) begin
                blk_done <= blk_done + 16'd1;
                if (blk_done + 16'd1 == bc_q) ds <= D_DONE;
                else begin ds <= D_WGAP; k <= '0; end
              end else if (d_to == dto) d_errs[0] = 1'b1;
            end
            default: ;
          endcase
        end
        if (d_errs != 8'd0) begin d_err <= d_err | d_errs; ds <= D_ABORT; dat_oe_r <= 8'h00; end
      end
      if (dma_err_set) d_err <= d_err | d_errs | dma_err_bits;
    end
  end

  // FIFO pops of the write path: the first word at the start bit, the next
  // ones at a word boundary
  always_comb begin
    d_pop = 1'b0;
    if (rise && !abort_req && !dma_err_set && !(c_go && c_data != 2'd0)) begin
      if (ds == D_WRDY && fcnt >= {1'b0, bw_q}) d_pop = 1'b1;
      if (ds == D_WDATA && wcnt == wlast && widx != bw_q - 8'd1) d_pop = 1'b1;
    end
  end

  // ------------------------------------------------------------ ADMA2 engine
  typedef enum logic [2:0] {A_IDLE, A_FETCH, A_FWAIT, A_DEC, A_XFER, A_XWAIT} as_t;
  as_t         as_q;
  logic [31:0] desc, w0, w1;
  logic        w_n;                    // descriptor words captured
  logic [23:0] tot_rem;                // words still to move
  logic        e_start, e_rd, e_wr, e_busy, e_done, e_err;
  logic [31:0] e_src, e_dst;
  logic [15:0] e_len;
  logic        rs_valid, rs_ready, ws_valid, ws_ready;
  logic [31:0] rs_data, ws_data;
  logic        draining;               // abort: finish the job with dummy data
  logic        a_data;                 // the job in progress is a data job
  logic [31:0] e_cycles;
  wire  [16:0] d_len_b = (w0[31:16] == 16'd0) ? 17'h10000 : {1'b0, w0[31:16]};
  wire  [14:0] d_len_w = d_len_b[16:2];
  wire  [23:0] j_words = ({9'd0, d_len_w} < tot_rem) ? {9'd0, d_len_w} : tot_rem;
  assign ae_idle  = (as_q == A_IDLE) && !e_busy;
  assign adma_cur = desc;
  assign abort_req = dat_reset && ds != D_IDLE;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      as_q <= A_IDLE; desc <= '0; w0 <= '0; w1 <= '0; w_n <= 1'b0; tot_rem <= '0; e_start <= 1'b0;
      e_rd <= 1'b0; e_wr <= 1'b0; e_src <= '0; e_dst <= '0; e_len <= '0; draining <= 1'b0;
      a_data <= 1'b0; dma_int <= 1'b0; dma_err_set <= 1'b0; dma_err_bits <= '0;
    end else begin
      e_start <= 1'b0; dma_int <= 1'b0; dma_err_set <= 1'b0; dma_err_bits <= '0;
      if (c_go && c_data != 2'd0) begin
        as_q <= A_FETCH; desc <= adma_addr; draining <= 1'b0;
        tot_rem <= {16'd0, blksz[9:2]} * {8'd0, (blkcnt == 16'd0) ? 16'd1 : blkcnt};
      end else begin
        if ((ds == D_ABORT || abort_req || draining) && as_q != A_IDLE) begin
          draining <= 1'b1;
          if (w0[2] && as_q == A_XWAIT && e_done) dma_int <= 1'b1;
          if (!e_busy && !e_start) as_q <= A_IDLE;
        end else case (as_q)
          A_FETCH: begin
            if (desc[1:0] != 2'b00) begin dma_err_set <= 1'b1; dma_err_bits <= 8'h10; as_q <= A_IDLE; end
            else begin
              e_start <= 1'b1; e_rd <= 1'b1; e_wr <= 1'b0; e_src <= desc; e_len <= 16'd2;
              a_data <= 1'b0; w_n <= 1'b0; as_q <= A_FWAIT;
            end
          end
          A_FWAIT: begin
            if (rs_valid && rs_ready && !a_data) begin
              if (!w_n) w0 <= rs_data; else w1 <= rs_data;
              w_n <= 1'b1;
            end
            if (e_done) begin
              if (e_err) begin dma_err_set <= 1'b1; dma_err_bits <= 8'h20; as_q <= A_IDLE; end
              else as_q <= A_DEC;
            end
          end
          A_DEC: begin
            if (!w0[0] || (w0[5:4] == 2'b10 && (w1[1:0] != 2'b00 || w0[17:16] != 2'b00))
                || (w0[5:4] == 2'b11 && w1[1:0] != 2'b00)) begin
              dma_err_set <= 1'b1; dma_err_bits <= 8'h10; as_q <= A_IDLE;
            end else if (w0[5:4] == 2'b11) begin desc <= w1; as_q <= A_FETCH; end
            else if (w0[5:4] == 2'b10) begin
              e_start <= 1'b1; e_rd <= !dir_rd; e_wr <= dir_rd; e_src <= w1; e_dst <= w1;
              e_len <= j_words[15:0]; a_data <= 1'b1; as_q <= A_XWAIT;
              tot_rem <= tot_rem - j_words;
            end else if (w0[1]) begin dma_err_set <= 1'b1; dma_err_bits <= 8'h40; as_q <= A_IDLE; end
            else begin desc <= desc + 32'd8; as_q <= A_FETCH; end
          end
          A_XWAIT: if (e_done) begin
            if (w0[2]) dma_int <= 1'b1;
            if (e_err) begin dma_err_set <= 1'b1; dma_err_bits <= 8'h20; as_q <= A_IDLE; end
            else if (tot_rem == 24'd0) as_q <= A_IDLE;
            else if (w0[1]) begin dma_err_set <= 1'b1; dma_err_bits <= 8'h40; as_q <= A_IDLE; end
            else begin desc <= desc + 32'd8; as_q <= A_FETCH; end
          end
          default: ;
        endcase
      end
    end
  end
  wire _unused = &{1'b0, e_cycles, desc[31:0] == 32'd0, d_len_b[1:0]};

  // engine streams, FIFO hookup
  wire drop = draining || ds == D_ABORT || abort_req;
  assign ws_valid = a_data && e_busy && e_wr && (drop || fcnt != 9'd0);
  assign ws_data  = drop ? 32'd0 : f_head;
  assign rs_ready = !a_data || (drop || fcnt != 9'd256);
  always_comb begin
    f_flush = c_go && c_data != 2'd0;
    f_push = 1'b0; f_din = d_word; f_pop = 1'b0;
    if (dir_rd) begin
      f_push = d_push && !drop;
      f_pop  = ws_valid && ws_ready && !drop;
    end else begin
      f_push = a_data && rs_valid && rs_ready && !drop; f_din = rs_data;
      f_pop  = d_pop;
    end
  end

  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(e_rd), .wr_en(e_wr), .src(e_src), .dst(e_dst), .len(e_len),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid, .rs_data, .rs_ready, .ws_valid, .ws_data, .ws_ready,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );
endmodule
