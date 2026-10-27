// SPDX-License-Identifier: Apache-2.0
// I2S_Audio: a pin-level bus monitor decodes the serial line on the bit
// clock rising edges (bclk_out/wclk_out in master mode, bclk_in/wclk_in in
// slave mode). Every transmitted bit is checked against the sample pair
// accepted through tx_valid/tx_ready (zeros on underrun) for the selected
// format/depth, and every rx_valid word against the words decoded from
// sd_in. Master-mode timing: sd_out and wclk_out never change on a cycle
// where bclk_out rises.
`include "cov_macros.svh"
module I2S_Audio_sva #(parameter int DW = 32) (
  input logic          clk, rst_n, cfg_master, bclk_out, wclk_out, bclk_in, wclk_in,
  input logic          tx_valid, tx_ready, rx_valid, sd_out, sd_in, irq,
  input logic [1:0]    cfg_fmt, cfg_depth,
  input logic [DW-1:0] tx_l, tx_r, rx_l, rx_r
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [31:0] ljust(input logic [31:0] s, input logic [1:0] d);
    return (d == 0) ? {s[15:0], 16'h0} : (d == 1) ? {s[23:0], 8'h0} : s;
  endfunction
  wire [5:0] shv = (cfg_depth == 0) ? 6'd16 : (cfg_depth == 1) ? 6'd8 : 6'd0;

  wire  bck = cfg_master ? bclk_out : bclk_in;
  wire  ws  = cfg_master ? wclk_out : wclk_in;
  logic bck_q, ws_q, sdo_q;
  logic [4:0] cfg_q;
  wire  cfg_chg = {cfg_master, cfg_fmt, cfg_depth} != cfg_q;
  wire  brise = bck && !bck_q;

  // ---------------- TX: expected line content ----------------
  logic [31:0] cur_l, cur_r, prev_r_lsb_w;    // words of the frame on the line
  logic [31:0] nxt_l, nxt_r;                  // pair accepted for the next frame
  int          pos;                           // rises since the last ws edge
  logic        slot_ch;                       // channel of the current slot
  int          ok;                            // complete frames since resync
  logic [31:0] dl, dr;                        // RX decode (left-justified)
  logic [31:0] m_rx_l, m_rx_r;
  logic        m_rx_ok;

  // words in effect at this rise (the first bit of a frame already
  // belongs to the newly accepted pair)
  wire        new_frame = brise && ws != slot_ch && !ws;
  wire [31:0] e_l = new_frame ? nxt_l : cur_l;
  wire [31:0] e_r = new_frame ? nxt_r : cur_r;
  wire        e_p = new_frame ? cur_r[0] : prev_r_lsb_w[0];
  function automatic logic exp_bit(input int p, input logic ch);
    automatic logic [31:0] w = ch ? e_r : e_l;
    case (cfg_fmt)
      2'd1:    return w[31 - p];
      2'd2:    return (p >= shv) ? w[31 + shv - p] : 1'b0;
      default: return (p == 0) ? (ch ? e_l[0] : e_p) : w[32 - p];
    endcase
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bck_q <= 0; ws_q <= 0; sdo_q <= 0; cfg_q <= 0;
      cur_l <= 0; cur_r <= 0; prev_r_lsb_w <= 0; nxt_l <= 0; nxt_r <= 0;
      pos <= 0; slot_ch <= 0; ok <= 0; dl <= 0; dr <= 0;
      m_rx_l <= 0; m_rx_r <= 0; m_rx_ok <= 0;
    end else begin
      bck_q <= bck; ws_q <= ws; sdo_q <= sd_out; cfg_q <= {cfg_master, cfg_fmt, cfg_depth};
      if (tx_ready) begin
        nxt_l <= tx_valid ? ljust(tx_l, cfg_depth) : 32'h0;
        nxt_r <= tx_valid ? ljust(tx_r, cfg_depth) : 32'h0;
      end
      if (cfg_chg || irq) begin ok <= 0; m_rx_ok <= 0; end
      else if (brise) begin
        if (ws != slot_ch) begin                    // first bit of a new slot
          if (!ws) begin                            // new frame (left slot)
            prev_r_lsb_w <= cur_r;
            cur_l <= nxt_l; cur_r <= nxt_r;
            ok <= (pos == 32) ? ok + 1 : 0;   // 32 bits per slot
          end else if (pos != 32) ok <= 0;
          slot_ch <= ws; pos <= 1;
        end else pos <= pos + 1;
        // RX decode of sd_in at this rise
        begin
          automatic int  p  = (ws != slot_ch) ? 0 : pos;
          automatic logic ch = ws;
          case (cfg_fmt)
            2'd1: begin
              if (ch) dr[31 - p] <= sd_in; else dl[31 - p] <= sd_in;
              if (ch && p == 31) begin m_rx_l <= dl; m_rx_r <= {dr[31:1], sd_in}; m_rx_ok <= ok >= 2; end
            end
            2'd2: begin
              if (p >= shv) begin if (ch) dr[31 + shv - p] <= sd_in; else dl[31 + shv - p] <= sd_in; end
              // last bit lands in bit shv of the slot word
              if (ch && p == 31) begin
                m_rx_l <= dl; m_rx_r <= (dr & ~(32'h1 << shv)) | ({31'h0, sd_in} << shv);
                m_rx_ok <= ok >= 2;
              end
            end
            default: begin
              if (p == 0) begin
                if (ch) dl[0] <= sd_in; else dr[0] <= sd_in;
                if (!ch) begin m_rx_l <= dl; m_rx_r <= {dr[31:1], sd_in}; m_rx_ok <= ok >= 2; end
              end else begin
                if (ch) dr[32 - p] <= sd_in; else dl[32 - p] <= sd_in;
              end
            end
          endcase
        end
      end
    end
  end
  wire check_tx = brise && ok >= 2 && !cfg_chg;

  `SVA_RST(a_reset_quiet, !rst_n, !bclk_out && !wclk_out && !rx_valid && !irq && !tx_ready)
  `SVA_IMP(a_tx_bit_model, check_tx, sd_out == exp_bit((ws != slot_ch) ? 0 : pos, ws))
  `SVA_IMP(a_master_stable_at_rise, cfg_master && brise && !cfg_chg && ok >= 1,
           sd_out == sdo_q && wclk_out == ws_q)
  // rx words are latched one clock before rx_valid, with the depth of then
  logic [5:0] shv_q;
  always_ff @(posedge clk) shv_q <= shv;
  `SVA_IMP(a_rx_model, rx_valid && m_rx_ok,
           rx_l == (m_rx_l >> shv_q) && rx_r == (m_rx_r >> shv_q))
  `SVA_IMP(a_irq_slave_only, irq, !cfg_master)
  `SVA_IMP(a_ready_once_per_frame, tx_ready, !$past(tx_ready))

  // ---------------- functional coverage ----------------
  // every mode x format x depth combination received end to end
  covergroup cg_combo @(posedge clk);
    cp_combo: coverpoint {cfg_master, cfg_fmt, (cfg_depth == 2'd3) ? 2'd2 : cfg_depth}
              iff (rst_n && rx_valid && m_rx_ok) {
      bins slave_i2s_d16 = {5'd0};
      bins slave_i2s_d24 = {5'd1};
      bins slave_i2s_d32 = {5'd2};
      bins slave_lj_d16 = {5'd4};
      bins slave_lj_d24 = {5'd5};
      bins slave_lj_d32 = {5'd6};
      bins slave_rj_d16 = {5'd8};
      bins slave_rj_d24 = {5'd9};
      bins slave_rj_d32 = {5'd10};
      bins master_i2s_d16 = {5'd16};
      bins master_i2s_d24 = {5'd17};
      bins master_i2s_d32 = {5'd18};
      bins master_lj_d16 = {5'd20};
      bins master_lj_d24 = {5'd21};
      bins master_lj_d32 = {5'd22};
      bins master_rj_d16 = {5'd24};
      bins master_rj_d24 = {5'd25};
      bins master_rj_d32 = {5'd26};
    }
  endgroup
  cg_combo u_cg_combo = new;
  // sample data: zero / full scale / alternating / other per channel and
  // depth, both directions
  function automatic int dcls(input logic [31:0] v, input logic [1:0] d);
    logic [31:0] m;
    m = d == 0 ? 32'h0000_FFFF : d == 1 ? 32'h00FF_FFFF : 32'hFFFF_FFFF;
    v = v & m;
    dcls = v == 0 ? 0 : v == m ? 1 : (v == (32'h5555_5555 & m) || v == (32'hAAAA_AAAA & m)) ? 2 : 3;
  endfunction
  wire [1:0] dep = cfg_depth == 2'd3 ? 2'd2 : cfg_depth;
  covergroup cg_data @(posedge clk);
    cp_dep_t: coverpoint dep iff (rst_n && tx_ready && tx_valid) { bins d16 = {0}; bins d24 = {1}; bins d32 = {2}; }
    cp_tl: coverpoint dcls(32'(tx_l), cfg_depth) iff (rst_n && tx_ready && tx_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_tr: coverpoint dcls(32'(tx_r), cfg_depth) iff (rst_n && tx_ready && tx_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_tl: cross cp_dep_t, cp_tl;
    x_tr: cross cp_dep_t, cp_tr;
    cp_dep_r: coverpoint dep iff (rst_n && rx_valid && m_rx_ok) { bins d16 = {0}; bins d24 = {1}; bins d32 = {2}; }
    cp_rl: coverpoint dcls(32'(rx_l), cfg_depth) iff (rst_n && rx_valid && m_rx_ok)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rr: coverpoint dcls(32'(rx_r), cfg_depth) iff (rst_n && rx_valid && m_rx_ok)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_rl: cross cp_dep_r, cp_rl;
    x_rr: cross cp_dep_r, cp_rr;
  endgroup
  cg_data u_cg_data = new;
  `FC(depth_code_3, rx_valid && m_rx_ok && cfg_depth == 2'd3)
  `FC(tx_underrun, tx_ready && !tx_valid && ok >= 2)
  `FC(slave_frame_sync_error, irq)
  `FC(cfg_change_mid_frame, cfg_chg && pos > 3 && pos < 30)
  `FC_RST(reset_mid_frame, rst_n && ok >= 2 ##1 !rst_n)
endmodule

bind I2S_Audio_top I2S_Audio_sva #(.DW(DW)) u_sva (.*);
