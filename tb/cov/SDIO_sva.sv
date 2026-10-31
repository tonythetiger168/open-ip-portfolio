// SPDX-License-Identifier: Apache-2.0
// SDIO card: a pin-level model follows CMD and DAT[3:0] bit time by bit
// time. It decodes each command frame (own CRC7), works out the R5 flags,
// data and CRC7, keeps a shadow of the function-1 register file, decodes
// write blocks with its own per-line CRC16 and predicts the CRC status
// token, and builds the read blocks. It predicts the card's CMD and DAT
// drivers (enable and value) on every bit time, the irq pulses and the
// register file.
`include "cov_macros.svh"
module SDIO_sva #(parameter int BIT_CLKS = 1) (
  input logic       sd_clk, rst_n, cmd, irq, cmd_oe, cmd_out,
  input logic [3:0] dat, dat_oe, dat_out,
  input logic [7:0] reg1 [0:127]
);
  `COV_CLOCKING(sd_clk, !rst_n)

  function automatic logic [6:0] crc7(input logic [39:0] m);
    logic [46:0] r;
    r = {m, 7'h0};
    for (int i = 46; i >= 7; i--) if (r[i]) r[i -: 8] ^= 8'h89;   // x^7 + x^3 + 1
    return r[6:0];
  endfunction
  function automatic logic [15:0] c16(input logic [15:0] c, input logic b);
    return {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0);
  endfunction

  int bd;
  wire tk = BIT_CLKS <= 1 || bd == BIT_CLKS - 1;

  localparam int IDLE = 0, CMD = 1, RDLY = 2, RSP = 3, WWAIT = 4, WDATA = 5, WCRC = 6, WEND = 7,
                 WSTAT = 8, RSTART = 9, RDATA = 10, RCRC = 11, REND = 12;
  int          ph, n, k, nb, base;
  logic [47:0] fr, r5;
  logic        pc, pi, wr, inc, data, okw;
  logic [7:0]  sh [0:127];
  logic [7:0]  buf_ [0:31];
  logic [15:0] cc [0:3], cr [0:3];
  logic [3:0]  hn;
  logic        m_irq, m_coe, m_cb;
  logic [3:0]  m_doe, m_db;

  wire  [47:0] f    = {fr[46:0], cmd};
  wire         good = !f[47] && f[46] && f[0] && crc7(f[47:8]) == f[7:1];
  wire         c52  = f[45:40] == 6'd52, c53 = f[45:40] == 6'd53 && !f[35];
  wire  [16:0] fa   = f[33:17];
  wire  [8:0]  fn_  = f[16:8];
  wire         efn  = f[38:36] != 3'd1;
  wire         erg  = fa > 17'd127 || (c53 && (fn_ == 0 || fn_ > 32 || (f[34] && int'(fa) + int'(fn_) > 128)));
  wire  [7:0]  rd8  = sh[(base + (inc ? n : 0)) % 128];
  logic        crc_good;
  always_comb begin
    crc_good = 1;
    for (int l = 0; l < 4; l++) if (cr[l] != cc[l]) crc_good = 0;
  end

  // coverage strobes
  logic v52r, v52w, v53r, v53w, vfix, vcrc, vill, vfn, vrg, vbadblk, vend, vtmo, vflags, v32;

  always_ff @(posedge sd_clk or negedge rst_n) begin
    if (!rst_n) begin
      bd <= 0; ph <= IDLE; n <= 0; k <= 0; nb <= 0; base <= 0; fr <= 0; r5 <= 0;
      pc <= 0; pi <= 0; wr <= 0; inc <= 0; data <= 0; okw <= 0; hn <= 0;
      m_irq <= 0; m_coe <= 0; m_cb <= 1; m_doe <= 0; m_db <= 4'hF;
      for (int i = 0; i < 128; i++) sh[i] <= 0;
      for (int l = 0; l < 4; l++) begin cc[l] <= 0; cr[l] <= 0; end
      {v52r, v52w, v53r, v53w, vfix, vcrc, vill, vfn, vrg, vbadblk, vend, vtmo, vflags, v32} <= '0;
    end else begin
      bd <= tk ? 0 : bd + 1;
      {v52r, v52w, v53r, v53w, vfix, vcrc, vill, vfn, vrg, vbadblk, vend, vtmo, vflags, v32} <= '0;
      if (tk) begin
        m_irq <= 0;
        case (ph)
          IDLE: begin
            m_coe <= 0; m_doe <= 0;
            if (cmd == 0) begin ph <= CMD; n <= 1; fr <= 0; end
          end
          CMD: begin
            fr <= f; n <= n + 1;
            if (n == 47) begin
              if (good && (c52 || c53)) begin
                logic [7:0] fl, d;
                fl = {pc, pi, 2'b01, 2'b00, efn, erg};
                d  = (c52 && !efn && !erg) ? (f[39] ? f[15:8] : sh[fa[6:0]]) : 8'h00;
                r5 <= {2'b00, f[45:40], 16'h0, fl, d, crc7({2'b00, f[45:40], 16'h0, fl, d}), 1'b1};
                vflags <= pc || pi; vfn <= efn; vrg <= erg;
                pc <= 0; pi <= 0;
                ph <= RDLY; k <= 0;
                wr <= f[39]; inc <= f[34]; base <= int'(fa[6:0]); nb <= int'(fn_);
                data <= c53 && !efn && !erg;
                if (c52 && !efn && !erg && f[39]) sh[fa[6:0]] <= f[15:8];
                v52r <= c52 && !f[39]; v52w <= c52 && f[39];
                v53r <= c53 && !f[39] && !efn && !erg; v53w <= c53 && f[39] && !efn && !erg;
                vfix <= c53 && !f[34] && !efn && !erg; v32 <= c53 && fn_ == 32;
              end else begin
                m_irq <= 1; ph <= IDLE;
                if (!good) begin pc <= 1; vcrc <= 1; end else begin pi <= 1; vill <= 1; end
              end
            end
          end
          RDLY: begin k <= k + 1; if (k == 2) begin ph <= RSP; k <= 0; end end
          RSP: begin
            m_coe <= 1; m_cb <= r5[47 - k]; k <= k + 1;
            n <= 0; hn <= 0;
            for (int l = 0; l < 4; l++) cc[l] <= 0;
            if (k == 47) begin ph <= !data ? IDLE : wr ? WWAIT : RSTART; k <= 0; end
          end
          WWAIT: begin
            m_coe <= 0; k <= k + 1;
            if (dat == 4'h0) begin ph <= WDATA; k <= 0; end
            else if (k == 63) begin m_irq <= 1; ph <= IDLE; vtmo <= 1; end
          end
          WDATA: begin
            for (int l = 0; l < 4; l++) cc[l] <= c16(cc[l], dat[l]);
            k <= k + 1;
            if (k % 2 == 0) hn <= dat;
            else begin
              buf_[k / 2] <= {hn, dat};
              if (k / 2 == nb - 1) begin ph <= WCRC; k <= 0; end
            end
          end
          WCRC: begin
            for (int l = 0; l < 4; l++) cr[l] <= {cr[l][14:0], dat[l]};
            k <= k + 1;
            if (k == 15) ph <= WEND;
          end
          WEND: begin
            okw <= dat == 4'hF && crc_good;
            if (dat == 4'hF && crc_good) begin
              for (int i = 0; i < 32; i++) if (i < nb) sh[(base + (inc ? i : 0)) % 128] <= buf_[i];
            end else begin m_irq <= 1; vbadblk <= crc_good; vend <= !crc_good; end
            ph <= WSTAT; k <= 0;
          end
          WSTAT: begin
            k <= k + 1;
            case (k)
              0, 1: ;
              2: begin m_doe <= 4'b0001; m_db[0] <= 0; end
              3: m_db[0] <= !okw;
              4: m_db[0] <= okw;
              5: m_db[0] <= !okw;
              6: m_db[0] <= 1;
              default: begin m_doe <= 0; ph <= IDLE; end
            endcase
          end
          RSTART: begin
            m_coe <= 0; k <= k + 1;
            if (k == 1) begin m_doe <= 4'hF; m_db <= 4'h0; ph <= RDATA; k <= 0; end
          end
          RDATA: begin
            k <= k + 1;
            m_db <= (k % 2) ? rd8[3:0] : rd8[7:4];
            for (int l = 0; l < 4; l++) cc[l] <= c16(cc[l], (k % 2) ? rd8[l] : rd8[l + 4]);
            if (k % 2) begin n <= n + 1; if (n == nb - 1) begin ph <= RCRC; k <= 0; end end
          end
          RCRC: begin
            for (int l = 0; l < 4; l++) begin m_db[l] <= cc[l][15]; cc[l] <= cc[l] << 1; end
            k <= k + 1;
            if (k == 15) ph <= REND;
          end
          default: begin m_db <= 4'hF; ph <= IDLE; end
        endcase
      end
    end
  end

  logic mem_ok;
  always_comb begin
    mem_ok = 1;
    for (int i = 0; i < 128; i++) if (reg1[i] != sh[i]) mem_ok = 0;
  end

  `SVA_RST(a_reset_released, !rst_n, !cmd_oe && dat_oe == 0 && !irq)
  `SVA_INV(a_cmd_driver, cmd_oe == m_coe && (!cmd_oe || cmd_out == m_cb))
  `SVA_INV(a_dat_driver, dat_oe == m_doe && ((dat_out & dat_oe) == (m_db & m_doe)))
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_register_file, mem_ok)

  // accepted command x direction x outcome, CMD53 byte count and address
  // mode per direction, CMD52 register address class per direction,
  // CMD52 write data / read data byte classes
  function automatic logic [1:0] bcls(input logic [7:0] v);
    bcls = (v == 8'h00) ? 2'd0 : (v == 8'hFF) ? 2'd1 : (v == 8'h55 || v == 8'hAA) ? 2'd2 : 2'd3;
  endfunction
  wire acc  = tk && ph == CMD && n == 47 && good && (c52 || c53);
  wire [1:0] outc = efn ? 2'd1 : erg ? 2'd2 : 2'd0;
  covergroup cg_cmd @(posedge sd_clk);
    option.per_instance = 1;
    cp_kind: coverpoint {c53, f[39], outc} iff (rst_n && acc)
      { bins r52_ok = {4'b0_0_00}; bins r52_fn = {4'b0_0_01}; bins r52_rg = {4'b0_0_10};
        bins w52_ok = {4'b0_1_00}; bins w52_fn = {4'b0_1_01}; bins w52_rg = {4'b0_1_10};
        bins r53_ok = {4'b1_0_00}; bins r53_fn = {4'b1_0_01}; bins r53_rg = {4'b1_0_10};
        bins w53_ok = {4'b1_1_00}; bins w53_fn = {4'b1_1_01}; bins w53_rg = {4'b1_1_10}; }
    cp_dir53: coverpoint f[39] iff (rst_n && acc && c53 && outc == 0) { bins rd = {0}; bins wr = {1}; }
    cp_cnt53: coverpoint fn_ iff (rst_n && acc && c53 && outc == 0)
      { bins one = {1}; bins mid = {[2:31]}; bins max32 = {32}; }
    cp_mode53: coverpoint f[34] iff (rst_n && acc && c53 && outc == 0) { bins fixed = {0}; bins incr = {1}; }
    x_53: cross cp_dir53, cp_cnt53, cp_mode53;
    cp_dir52: coverpoint f[39] iff (rst_n && acc && c52 && outc == 0) { bins rd = {0}; bins wr = {1}; }
    cp_addr52: coverpoint fa iff (rst_n && acc && c52 && outc == 0)
      { bins first = {0}; bins last = {127}; bins mid = {[1:126]}; }
    x_52: cross cp_dir52, cp_addr52;
    cp_wd52: coverpoint bcls(f[15:8]) iff (rst_n && acc && c52 && f[39] && outc == 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rd: coverpoint bcls(rd8) iff (rst_n && tk && ph == RDATA && k % 2 == 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_cmd u_cg_cmd = new;

  `FC(cmd52_read, v52r)
  `FC(cmd52_write, v52w)
  `FC(cmd53_read, v53r)
  `FC(cmd53_write, v53w)
  `FC(cmd53_32_bytes, v32)
  `FC(cmd53_fixed_address, vfix)
  `FC(no_response_crc_or_framing, vcrc)
  `FC(no_response_illegal, vill)
  `FC(r5_reports_previous_error, vflags)
  `FC(r5_function_number, vfn)
  `FC(r5_out_of_range, vrg)
  `FC(write_crc16_error, vend)
  `FC(write_end_bit_error, vbadblk)
  `FC(write_block_timeout, vtmo)
  `FC(write_status_accepted, tk && ph == WSTAT && k == 4 && okw)
  `FC_RST(reset_during_read_block, rst_n && ph == RDATA ##1 !rst_n)
  `FC_RST(reset_during_status, rst_n && ph == WSTAT ##1 !rst_n)
endmodule

bind SDIO_top SDIO_sva #(.BIT_CLKS(BIT_CLKS)) u_sva (.*);
