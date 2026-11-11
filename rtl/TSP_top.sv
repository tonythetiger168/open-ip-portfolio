// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// TSP: transport stream processor of the STB SoC: DVB-CISSA descrambling
// (AES-128-CBC, ETSI TS 103 127), PCR capture for clock recovery and PES /
// section routing of 188-byte TS packets, memory to memory (AXI4 manager,
// APB4 registers)
// ----------------------------------------------------------------------------
// - A job (CMD.start) takes PKTS packets, 47 words each, from SRC_ADDR (byte
// i of a packet in word i / 4, bits 8 * (i % 4) + 7 : 8 * (i % 4)) and
// handles them one at a time: read, descramble, write.
// - PID slots 0..3 (SLOT_CFG: PID, valid, route; loaded into the slot
// SLOT_SEL.slot by CMD.slot_load). A packet whose PID matches no valid slot
// is dropped (UNMATCHED in DROP_CNT). Route bit 0 copies the packet to
// buffer A (OUTA_ADDR, OUTA_MAX packets, e.g. PES / video), bit 1 to
// buffer B (OUTB_ADDR, OUTB_MAX, e.g. sections), at 188 bytes per packet;
// A_CNT / B_CNT count the packets written. A packet that finds its buffer
// full is not written there (OVF_CNT, OVF interrupt).
// - Keys: KEY0..KEY3 (key byte i in KEY(i / 4) bits 8 * (i % 4) + 7 :
// 8 * (i % 4)) loaded by CMD.key_load into slot SLOT_SEL.slot, even
// (SLOT_SEL.odd 0) or odd key; the core keeps only the last round key (10
// clocks to expand; STATUS.key_busy). Keys cannot be read back.
// - Descrambling: transport_scrambling_control 10 (even) or 11 (odd) with
// that key loaded: the payload (after the adaptation field) is decrypted
// in 16-byte AES-128-CBC blocks with the CISSA IV "DVBTMCPTAESCISSA"; a
// trailing part under 16 bytes stays as it is. The control bits are then
// cleared (unless CTRL.keep_tsc) and DESC_CNT counts the packet. Scrambled
// without a key: passed unchanged (NOKEY_CNT, NOKEY interrupt). Control 00
// or 01: passed unchanged.
// - Sync byte other than 0x47: the packet is dropped (SYNC_CNT, SYNC
// interrupt).
// - PCR: a packet of PID PCR_PID (with PCR_EN) whose adaptation field has
// the PCR flag loads PCR_BASE (bits 31:0 of the 33-bit base), PCR_EXT
// ({base[32], extension[8:0]}) and PCR_LOCAL (the free-running clock
// counter when the packet was read), PCR interrupt; software compares PCR
// and PCR_LOCAL deltas to steer the system clock.
// - DONE when the job ends; ERR as well after an AXI error response.
// ============================================================================
module TSP_top #(
  parameter logic [3:0] AXI_ID = 4'd12
) (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic        keep_tsc,
  input  logic        pcr_en,
  input  logic [12:0] pcr_pid,
  input  logic [31:0] src_addr,
  input  logic [15:0] pkts,
  input  logic [31:0] outa_addr,
  input  logic [15:0] outa_max,
  input  logic [31:0] outb_addr,
  input  logic [15:0] outb_max,
  input  logic [1:0]  slot,
  input  logic        odd,
  input  logic [31:0] key0,
  input  logic [31:0] key1,
  input  logic [31:0] key2,
  input  logic [31:0] key3,
  input  logic [12:0] slot_pid,
  input  logic        slot_valid,
  input  logic [1:0]  slot_route,
  // commands (one-clock pulses)
  input  logic        start,
  input  logic        key_load,
  input  logic        slot_load,
  // status
  output logic        busy,
  output logic        key_busy,
  output logic        err,
  output logic [15:0] a_cnt,
  output logic [15:0] b_cnt,
  output logic [15:0] desc_cnt,
  output logic [15:0] nokey_cnt,
  output logic [15:0] sync_cnt,
  output logic [15:0] drop_cnt,
  output logic [15:0] ovf_cnt,
  output logic [15:0] pkt_cnt,
  output logic [31:0] pcr_base,
  output logic [9:0]  pcr_ext,
  output logic [31:0] pcr_local,
  // interrupt pulses
  output logic        done,
  output logic        err_irq,
  output logic        nokey,
  output logic        sync,
  output logic        pcr,
  output logic        ovf,
  // AXI4 manager
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
  localparam logic [127:0] CISSA_IV = 128'h44564254_4d435054_41455343_49535341;   // "DVBTMCPTAESCISSA"

  // ---------------- key table ----------------
  logic [127:0] rk_e [4], rk_o [4];
  logic [3:0]   ke_ok, ko_ok;
  logic [12:0]  s_pid [4];
  logic [3:0]   s_val;
  logic [1:0]   s_route [4];
  logic         kx_busy, kx_done;
  logic [127:0] kx_rk;
  logic [1:0]   kx_slot;
  logic         kx_odd;
  tsp_aes128_lastkey u_kx (
    .clk, .rst_n, .start(key_load && !kx_busy),
    .key({key0[7:0], key0[15:8], key0[23:16], key0[31:24], key1[7:0], key1[15:8], key1[23:16], key1[31:24],
          key2[7:0], key2[15:8], key2[23:16], key2[31:24], key3[7:0], key3[15:8], key3[23:16], key3[31:24]}),
    .busy(kx_busy), .done(kx_done), .rk10(kx_rk)
  );
  assign key_busy = kx_busy;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin rk_e[i] <= '0; rk_o[i] <= '0; s_pid[i] <= '0; s_route[i] <= '0; end
      ke_ok <= '0; ko_ok <= '0; s_val <= '0; kx_slot <= '0; kx_odd <= 1'b0;
    end else begin
      if (key_load && !kx_busy) begin
        kx_slot <= slot; kx_odd <= odd;
        if (odd) ko_ok[slot] <= 1'b0; else ke_ok[slot] <= 1'b0;   // unusable until expanded
      end
      if (kx_done) begin
        if (kx_odd) begin rk_o[kx_slot] <= kx_rk; ko_ok[kx_slot] <= 1'b1; end
        else begin rk_e[kx_slot] <= kx_rk; ke_ok[kx_slot] <= 1'b1; end
      end
      if (slot_load) begin
        s_pid[slot] <= slot_pid; s_val[slot] <= slot_valid; s_route[slot] <= slot_route;
      end
    end
  end

  // ---------------- AXI engine (one job at a time, one direction) ----------------
  logic        e_start, e_rd, e_busy, e_done, e_err;
  logic [31:0] e_addr, e_cycles;
  logic        rs_valid, rs_ready, ws_valid, ws_ready;
  logic [31:0] rs_data, ws_data;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(e_rd), .wr_en(!e_rd),
    .src(e_addr), .dst(e_addr), .len(16'd47),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid(rs_valid), .rs_data(rs_data), .rs_ready(rs_ready),
    .ws_valid(ws_valid), .ws_data(ws_data), .ws_ready(ws_ready),
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  // ---------------- packet buffer: 47 words ----------------
  logic [31:0] pw [47];
  logic [5:0]  wi;                                 // word index (DMA)
  logic [7:0]  bi;                                 // byte index (descrambler)
  wire  [7:0]  b_rd = pw[bi[7:2]][8 * bi[1:0] +: 8];
  // header fields
  wire  [7:0]  h_sync = pw[0][7:0];
  wire  [12:0] h_pid  = {pw[0][12:8], pw[0][23:16]};
  wire  [1:0]  h_tsc  = pw[0][31:30];
  wire  [1:0]  h_afc  = pw[0][29:28];
  wire  [7:0]  h_afl  = pw[1][7:0];
  wire         h_pcrf = h_afc[1] && h_afl >= 8'd7 && pw[1][12];
  wire  [8:0]  h_pay  = (h_afc == 2'b01) ? 9'd4 : 9'd5 + {1'b0, h_afl};   // payload start (afc 01 / 11)
  wire         h_has  = h_afc[0] && h_pay < 9'd188;

  // slot match
  logic        m_hit;
  logic [1:0]  m_slot;
  always_comb begin
    m_hit = 1'b0; m_slot = 2'd0;
    for (int i = 3; i >= 0; i--)
      if (s_val[i] && s_pid[i] == h_pid) begin m_hit = 1'b1; m_slot = 2'(i); end
  end

  // ---------------- AES ----------------
  logic         a_start, a_busy, a_done;
  logic [127:0] a_ct, a_rk, a_pt, iv;
  tsp_aes128_dec u_aes (.clk, .rst_n, .start(a_start), .ct(a_ct), .rk10(a_rk), .busy(a_busy), .done(a_done), .pt(a_pt));

  // ---------------- sequencer ----------------
  typedef enum logic [3:0] {S_IDLE, S_RD, S_RD_W, S_HDR, S_LD, S_AES, S_ST, S_WR, S_WR_W, S_NEXT} st_t;
  st_t         st;
  logic [15:0] pi;                                 // packet index
  logic [1:0]  wr_dst;                             // destinations still to write (bit 0 A, bit 1 B)
  logic        wr_b;                               // writing B
  logic [3:0]  k16;                                // byte within a block
  logic [7:0]  nblk;                               // blocks left
  logic [127:0] blk;
  logic [31:0] clk_cnt, rd_time;
  logic        e_fin, e_errq;

  assign busy     = (st != S_IDLE);
  assign rs_ready = (st == S_RD_W) && wi != 6'd47;
  assign ws_valid = (st == S_WR_W) && wi != 6'd47;
  assign ws_data  = pw[wi];

  wire [31:0] pkt_off = {pi, 7'd0} + {pi, 5'd0} + {pi, 4'd0} + {pi, 3'd0} + {pi, 2'd0};   // 188 * pi
  wire [31:0] a_off   = {a_cnt, 7'd0} + {a_cnt, 5'd0} + {a_cnt, 4'd0} + {a_cnt, 3'd0} + {a_cnt, 2'd0};
  wire [31:0] b_off   = {b_cnt, 7'd0} + {b_cnt, 5'd0} + {b_cnt, 4'd0} + {b_cnt, 3'd0} + {b_cnt, 2'd0};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) clk_cnt <= '0;
    else clk_cnt <= clk_cnt + 32'd1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; pi <= '0; wi <= '0; bi <= '0; wr_dst <= '0; wr_b <= 1'b0; k16 <= '0; nblk <= '0;
      blk <= '0; iv <= '0; a_start <= 1'b0; a_ct <= '0; a_rk <= '0; rd_time <= '0;
      e_start <= 1'b0; e_rd <= 1'b0; e_addr <= '0; e_fin <= 1'b0; e_errq <= 1'b0;
      for (int i = 0; i < 47; i++) pw[i] <= '0;
      err <= 1'b0; a_cnt <= '0; b_cnt <= '0; desc_cnt <= '0; nokey_cnt <= '0; sync_cnt <= '0;
      drop_cnt <= '0; ovf_cnt <= '0; pkt_cnt <= '0; pcr_base <= '0; pcr_ext <= '0; pcr_local <= '0;
      done <= 1'b0; err_irq <= 1'b0; nokey <= 1'b0; sync <= 1'b0; pcr <= 1'b0; ovf <= 1'b0;
    end else begin
      e_start <= 1'b0; a_start <= 1'b0;
      done <= 1'b0; err_irq <= 1'b0; nokey <= 1'b0; sync <= 1'b0; pcr <= 1'b0; ovf <= 1'b0;
      if (e_done) begin e_fin <= 1'b1; if (e_err) e_errq <= 1'b1; end
      if (rs_valid && rs_ready) begin pw[wi] <= rs_data; wi <= wi + 6'd1; end
      if (ws_valid && ws_ready) wi <= wi + 6'd1;
      case (st)
        S_IDLE: if (start) begin
          pi <= '0; e_errq <= 1'b0; a_cnt <= '0; b_cnt <= '0; err <= 1'b0;
          if (pkts == 16'd0) st <= S_NEXT; else st <= S_RD;
        end
        // read one packet
        S_RD: if (!kx_busy) begin                  // a key being expanded is not used half-loaded
          e_rd <= 1'b1; e_addr <= src_addr + pkt_off; e_start <= 1'b1; e_fin <= 1'b0;
          wi <= '0; rd_time <= clk_cnt; st <= S_RD_W;
        end
        S_RD_W: if (e_fin) st <= S_HDR;
        // header: sync, PCR, slot, keys
        S_HDR: begin
          if (pkt_cnt != 16'hFFFF) pkt_cnt <= pkt_cnt + 16'd1;
          if (h_sync != 8'h47) begin
            sync <= 1'b1; if (sync_cnt != 16'hFFFF) sync_cnt <= sync_cnt + 16'd1;
            st <= S_NEXT;
          end else begin
            if (pcr_en && h_pid == pcr_pid && h_pcrf) begin
              pcr_base  <= {pw[1][23:16], pw[1][31:24], pw[2][7:0], pw[2][15:8]} << 1 | {31'd0, pw[2][23]};
              pcr_ext   <= {pw[1][23], pw[2][16], pw[2][31:24]};
              pcr_local <= rd_time; pcr <= 1'b1;
            end
            if (!m_hit) begin
              if (drop_cnt != 16'hFFFF) drop_cnt <= drop_cnt + 16'd1;
              st <= S_NEXT;
            end else begin
              wr_dst <= s_route[m_slot];
              if (h_tsc[1] && !(h_tsc[0] ? ko_ok[m_slot] : ke_ok[m_slot])) begin
                nokey <= 1'b1; if (nokey_cnt != 16'hFFFF) nokey_cnt <= nokey_cnt + 16'd1;
                st <= S_WR;
              end else if (h_tsc[1]) begin
                a_rk <= h_tsc[0] ? rk_o[m_slot] : rk_e[m_slot];
                if (!keep_tsc) pw[0][31:30] <= 2'b00;
                if (desc_cnt != 16'hFFFF) desc_cnt <= desc_cnt + 16'd1;
                iv <= CISSA_IV; bi <= h_pay[7:0]; k16 <= '0;
                nblk <= h_has ? 8'((9'd188 - h_pay) >> 4) : 8'd0;
                if (h_has && (9'd188 - h_pay) >= 9'd16) st <= S_LD; else st <= S_WR;
              end else st <= S_WR;
            end
          end
        end
        // load a 16-byte block, one byte per clock
        S_LD: begin
          blk[127 - 8 * k16 -: 8] <= b_rd;
          bi <= bi + 8'd1; k16 <= k16 + 4'd1;
          if (k16 == 4'd15) begin
            a_ct <= {blk[127:8], b_rd}; a_start <= 1'b1; bi <= bi - 8'd15; st <= S_AES;
          end
        end
        S_AES: if (a_done) begin
          blk <= a_pt ^ iv; iv <= a_ct; k16 <= '0; st <= S_ST;
        end
        // store the plaintext block, one byte per clock
        S_ST: begin
          pw[bi[7:2]][8 * bi[1:0] +: 8] <= blk[127 - 8 * k16 -: 8];
          bi <= bi + 8'd1; k16 <= k16 + 4'd1;
          if (k16 == 4'd15) begin
            nblk <= nblk - 8'd1;
            if (nblk == 8'd1) st <= S_WR; else st <= S_LD;
          end
        end
        // write to A and / or B
        S_WR: begin
          if (wr_dst[0]) begin
            wr_dst[0] <= 1'b0;
            if (a_cnt < outa_max) begin
              e_rd <= 1'b0; e_addr <= outa_addr + a_off; e_start <= 1'b1; e_fin <= 1'b0; wi <= '0; wr_b <= 1'b0; st <= S_WR_W;
            end else begin ovf <= 1'b1; if (ovf_cnt != 16'hFFFF) ovf_cnt <= ovf_cnt + 16'd1; end
          end else if (wr_dst[1]) begin
            wr_dst[1] <= 1'b0;
            if (b_cnt < outb_max) begin
              e_rd <= 1'b0; e_addr <= outb_addr + b_off; e_start <= 1'b1; e_fin <= 1'b0; wi <= '0; wr_b <= 1'b1; st <= S_WR_W;
            end else begin ovf <= 1'b1; if (ovf_cnt != 16'hFFFF) ovf_cnt <= ovf_cnt + 16'd1; end
          end else st <= S_NEXT;
        end
        S_WR_W: if (e_fin) begin
          if (wr_b) b_cnt <= b_cnt + 16'd1; else a_cnt <= a_cnt + 16'd1;
          st <= S_WR;
        end
        default: begin                             // S_NEXT
          if (pi + 16'd1 >= pkts) begin
            st <= S_IDLE; done <= 1'b1; err_irq <= e_errq; if (e_errq) err <= 1'b1;
          end else begin pi <= pi + 16'd1; st <= S_RD; end
        end
      endcase
    end
  end
endmodule
