// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// GbE_DMA: Ethernet MAC with descriptor-ring DMA (AXI4 manager, APB4 regs)
// ----------------------------------------------------------------------------
// The unchanged Ethernet_top MAC (GMII-style byte interface, address filter,
// PAUSE) with a TX and an RX descriptor ring in memory, moved by one
// soc_ss_axi_engine that a scheduler shares between the two directions.
// - Descriptor (8 bytes, word aligned): word 0 buffer address (word
//   aligned), word 1 length. Ring entry i is at BASE + 8 * i, NUM entries.
//   Software owns TAIL (the next entry it will fill), the hardware HEAD (the
//   next entry it will use); entries HEAD .. TAIL - 1 belong to the hardware.
// - TX: word 1 = frame length in bytes (DA .. payload, 1..TXF_BYTES). The
//   frame is fetched whole into the TX FIFO, then sent (store and forward,
//   so the MAC never underruns). After the MAC's tx_done the hardware writes
//   word 1 = {1 done, 1'b0, underrun, bad_len, 12'd0, len} and advances
//   TX_HEAD. A length of 0 or above TXF_BYTES is not sent (bad_len).
// - RX: word 1 = buffer size in bytes. Received frames (without FCS) wait in
//   the RX FIFO (RXF_BYTES, up to 4 frames). Each one takes the descriptor
//   at RX_HEAD: its first min(len, size) bytes are written to the buffer,
//   (rounded up to a word, so up to 3 bytes past SIZE when it is not a
//   multiple of 4), then word 1 = {1 done, trunc, 10'd0, stat[3:0], len} with the MAC's
//   rx_stat {pause, phy_err, len_err, crc_err} and trunc when the frame was
//   longer than the buffer. A frame that does not fit in the RX FIFO, or
//   arrives with 4 frames waiting or with RX_EN off, is dropped (RX_DROP).
//   With no descriptor free the frames wait in the FIFO.
// - Interrupts: TX (a TX descriptor completed), RX (an RX descriptor
//   completed), DROP (a frame dropped), ERR (an AXI error response; ERR
//   stays set in STATUS until CMD.clr_err).
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module GbE_DMA_top #(
  parameter logic [3:0] AXI_ID = 4'd10,
  parameter int TXF_BYTES = 2048,
  parameter int RXF_BYTES = 4096
) (
  input  logic        clk,
  input  logic        rst_n,
  // MAC configuration
  input  logic [4:0]  cfg_div,
  input  logic [47:0] cfg_mac,
  input  logic        cfg_promisc,
  input  logic        cfg_pause_en,
  // GMII
  output logic [7:0]  gtxd,
  output logic        gtx_en,
  output logic        gtx_er,
  input  logic [7:0]  grxd,
  input  logic        grx_dv,
  input  logic        grx_er,
  // rings
  input  logic        tx_en,
  input  logic        rx_en,
  input  logic [31:0] tx_base,
  input  logic [15:0] tx_num,
  input  logic [15:0] tx_tail,
  output logic [15:0] tx_head,
  input  logic [31:0] rx_base,
  input  logic [15:0] rx_num,
  input  logic [15:0] rx_tail,
  output logic [15:0] rx_head,
  input  logic        clr_err,
  output logic        err,
  output logic        tx_paused,
  output logic [15:0] tx_frames,
  output logic [15:0] rx_frames,
  output logic [15:0] rx_drop,
  output logic        tx_irq,
  output logic        rx_irq,
  output logic        drop_irq,
  output logic        err_irq,
  // AXI4 manager (m_*): 32-bit address and data, 4-bit ID
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
  localparam int TW  = TXF_BYTES / 4;              // TX FIFO words
  localparam int RW  = RXF_BYTES / 4;              // RX FIFO words
  localparam int TAW = $clog2(TW);
  localparam int RAW = $clog2(RW);

  // ------------------------------------------------------------ engine
  logic        e_start, e_rd, e_wr, e_busy, e_done, e_err;
  logic [31:0] e_src, e_dst, e_cyc;
  logic [15:0] e_len;
  logic        rs_valid, rs_ready, ws_valid, ws_ready;
  logic [31:0] rs_data, ws_data;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(e_rd), .wr_en(e_wr), .src(e_src), .dst(e_dst), .len(e_len),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cyc),
    .rs_valid, .rs_data, .rs_ready, .ws_valid, .ws_data, .ws_ready,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  // ------------------------------------------------------------ MAC
  logic        tx_valid, tx_ready, tx_last, tx_done, tx_underrun;
  logic [7:0]  tx_data, rx_data;
  logic        rx_valid, rx_last, rx_frag;
  logic [3:0]  rx_stat;
  Ethernet_top u_mac (
    .clk, .rst_n, .cfg_div, .cfg_mac, .cfg_promisc, .cfg_pause_en,
    .tx_valid, .tx_ready, .tx_data, .tx_last, .tx_done, .tx_underrun, .tx_paused,
    .gtxd, .gtx_en, .gtx_er, .grxd, .grx_dv, .grx_er,
    .rx_valid, .rx_data, .rx_last, .rx_stat, .rx_frag
  );

  // ------------------------------------------------------------ TX FIFO
  logic [31:0]  txf [0:TW-1];
  logic [TAW:0] txf_w, txf_r;
  logic [15:0]  tx_len, tx_bi;     // frame length, next byte to send
  logic         tx_go;             // frame in the FIFO, being sent
  wire  [31:0]  txf_q = txf[txf_r[TAW-1:0]];
  assign tx_valid = tx_go;
  assign tx_data  = txf_q[8 * tx_bi[1:0] +: 8];
  assign tx_last  = (tx_bi == tx_len - 16'd1);

  // ------------------------------------------------------------ RX FIFO
  logic [31:0]  rxf [0:RW-1];
  logic [RAW:0] rxf_w, rxf_r, rxf_w0;          // write, read, frame start
  logic [31:0]  rx_pk;                         // bytes being packed
  logic [1:0]   rx_pos;
  logic [15:0]  rx_cnt;
  logic         rx_in, rx_bad;                 // in a frame / dropping it
  logic [19:0]  rinfo [0:3];                   // {stat, len} of waiting frames
  logic [2:0]   ri_w, ri_r;
  wire  [RAW:0] rx_used = rxf_w - rxf_r;
  wire          ri_full  = (ri_w - ri_r) == 3'd4;
  wire          ri_empty = (ri_w == ri_r);
  wire  [31:0]  rxf_q = rxf[rxf_r[RAW-1:0]];

  // ------------------------------------------------------------ scheduler
  typedef enum logic [3:0] {
    S_IDLE, S_TXD, S_TXB, S_TXS, S_RXD, S_RXB, S_RXDRAIN, S_RXS
  } st_t;
  st_t st;
  logic [31:0] d_addr;            // descriptor address of the current RX op
  logic [31:0] td_addr;           // descriptor address of the TX frame
  logic        tx_ur;             // the MAC underran on this frame
  logic [31:0] d_w0, d_w1;
  logic        d_i;               // descriptor word being fetched
  logic        txs_pend;          // TX frame sent, status to write
  logic [31:0] txs_word;
  logic [31:0] rxs_word;
  logic [15:0] rx_drain;          // RX FIFO words to discard after the copy
  logic        tx_busy;           // a TX descriptor is being processed
  wire  [15:0] tx_nx = (tx_head + 16'd1 == tx_num) ? 16'd0 : tx_head + 16'd1;
  wire  [15:0] rx_nx = (rx_head + 16'd1 == rx_num) ? 16'd0 : rx_head + 16'd1;
  wire  [15:0] ri_len  = rinfo[ri_r[1:0]][15:0];
  wire  [3:0]  ri_stat = rinfo[ri_r[1:0]][19:16];
  wire         rx_ready_job = rx_en && !ri_empty && (rx_head != rx_tail);
  wire         tx_ready_job = tx_en && !tx_busy && (tx_head != tx_tail);
  wire  [15:0] rx_take = (ri_len > d_w1[15:0]) ? d_w1[15:0] : ri_len;
  function automatic logic [15:0] words(input logic [15:0] b);
    words = {2'b00, b[15:2]} + {15'd0, b[1:0] != 2'b00};
  endfunction

  // engine stream routing
  always_comb begin
    rs_ready = 1'b0; ws_valid = 1'b0; ws_data = 32'd0;
    case (st)
      S_TXD, S_RXD: rs_ready = 1'b1;
      S_TXB:        rs_ready = 1'b1;           // the FIFO is empty and the frame fits
      S_TXS:        begin ws_valid = 1'b1; ws_data = txs_word; end
      S_RXS:        begin ws_valid = 1'b1; ws_data = rxs_word; end
      S_RXB:        begin ws_valid = (rxf_w != rxf_r); ws_data = rxf_q; end
      default: ;
    endcase
  end

  logic rx_pop;
  assign rx_pop = (st == S_RXB && ws_valid && ws_ready) || (st == S_RXDRAIN && rx_drain != 16'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; e_start <= 1'b0; e_rd <= 1'b0; e_wr <= 1'b0;
      e_src <= '0; e_dst <= '0; e_len <= '0; d_addr <= '0; td_addr <= '0; tx_ur <= 1'b0; d_w0 <= '0; d_w1 <= '0; d_i <= 1'b0;
      tx_head <= '0; rx_head <= '0; txf_w <= '0; txf_r <= '0; tx_len <= '0; tx_bi <= '0;
      tx_go <= 1'b0; txs_pend <= 1'b0; txs_word <= '0; rxs_word <= '0; tx_busy <= 1'b0;
      rx_drain <= '0; rxf_r <= '0; ri_r <= '0; err <= 1'b0;
      tx_frames <= '0; rx_frames <= '0; tx_irq <= 1'b0; rx_irq <= 1'b0; err_irq <= 1'b0;
    end else begin
      e_start <= 1'b0; tx_irq <= 1'b0; rx_irq <= 1'b0; err_irq <= 1'b0;
      if (clr_err) err <= 1'b0;
      if (e_done && e_err) begin err <= 1'b1; err_irq <= 1'b1; end
      // ---------------- TX byte server
      if (tx_valid && tx_ready) begin
        tx_bi <= tx_bi + 16'd1;
        if (tx_bi[1:0] == 2'd3 || tx_last) txf_r <= txf_r + 1'b1;
        if (tx_last) tx_go <= 1'b0;
      end
      if (tx_done && tx_busy && !tx_go && !txs_pend) begin
        txs_pend <= 1'b1; txs_word <= {1'b1, 1'b0, tx_ur || tx_underrun, 1'b0, 12'd0, tx_len};
      end
      if (tx_underrun) tx_ur <= 1'b1;
      // ---------------- RX FIFO pops
      if (rx_pop) rxf_r <= rxf_r + 1'b1;
      if (st == S_RXDRAIN && rx_drain != 16'd0) rx_drain <= rx_drain - 16'd1;
      // ---------------- scheduler
      case (st)
        S_IDLE: begin
          if (txs_pend) begin                      // TX status write-back
            e_dst <= td_addr + 32'd4; e_len <= 16'd1; e_rd <= 1'b0; e_wr <= 1'b1;
            e_start <= 1'b1; st <= S_TXS;
          end else if (rx_ready_job) begin
            d_addr <= rx_base + {13'd0, rx_head, 3'b000};
            e_src <= rx_base + {13'd0, rx_head, 3'b000}; e_len <= 16'd2; e_rd <= 1'b1; e_wr <= 1'b0;
            e_start <= 1'b1; d_i <= 1'b0; st <= S_RXD;
          end else if (tx_ready_job) begin
            td_addr <= tx_base + {13'd0, tx_head, 3'b000};
            e_src <= tx_base + {13'd0, tx_head, 3'b000}; e_len <= 16'd2; e_rd <= 1'b1; e_wr <= 1'b0;
            e_start <= 1'b1; d_i <= 1'b0; tx_busy <= 1'b1; st <= S_TXD;
          end
        end
        S_TXD, S_RXD: begin
          if (rs_valid) begin
            if (!d_i) d_w0 <= rs_data; else d_w1 <= rs_data;
            d_i <= 1'b1;
          end
          if (e_done && !e_start) begin
            if (st == S_TXD) begin
              tx_len <= d_w1[15:0];
              if (d_w1[15:0] == 16'd0 || d_w1[15:0] > 16'(TXF_BYTES)) begin
                txs_word <= {1'b1, 1'b0, 1'b0, 1'b1, 12'd0, d_w1[15:0]};
                txs_pend <= 1'b1; st <= S_IDLE;
              end else begin
                e_src <= d_w0; e_len <= words(d_w1[15:0]); e_rd <= 1'b1; e_wr <= 1'b0;
                e_start <= 1'b1; st <= S_TXB;
              end
            end else begin
              rx_drain <= words(ri_len) - words(rx_take);
              rxs_word <= {1'b1, ri_len > d_w1[15:0], 10'd0, ri_stat, ri_len};
              if (rx_take == 16'd0) st <= S_RXDRAIN;
              else begin
                e_dst <= d_w0; e_len <= words(rx_take); e_rd <= 1'b0; e_wr <= 1'b1;
                e_start <= 1'b1; st <= S_RXB;
              end
            end
          end
        end
        S_TXB: begin
          if (e_done && !e_start) begin
            tx_bi <= '0; tx_go <= 1'b1; tx_ur <= 1'b0; st <= S_IDLE;   // send; status after tx_done
          end
        end
        S_RXB: if (e_done && !e_start) st <= S_RXDRAIN;
        S_RXDRAIN: if (rx_drain == 16'd0) begin
          e_dst <= d_addr + 32'd4; e_len <= 16'd1; e_rd <= 1'b0; e_wr <= 1'b1;
          e_start <= 1'b1; st <= S_RXS;
        end
        S_RXS: if (e_done && !e_start) begin
          ri_r <= ri_r + 3'd1; rx_head <= rx_nx; rx_frames <= rx_frames + 16'd1;
          rx_irq <= 1'b1; st <= S_IDLE;
        end
        S_TXS: if (e_done && !e_start) begin
          txs_pend <= 1'b0; tx_busy <= 1'b0; tx_head <= tx_nx;
          if (!txs_word[28]) tx_frames <= tx_frames + 16'd1;
          tx_irq <= 1'b1; st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // TX FIFO writes (the engine's read stream in S_TXB)
  always_ff @(posedge clk) if (st == S_TXB && rs_valid) txf[txf_w[TAW-1:0]] <= rs_data;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) txf_w <= '0;
    else if (st == S_TXB && rs_valid) txf_w <= txf_w + 1'b1;

  // ------------------------------------------------------------ RX packer
  wire [RAW:0] rx_free = (RAW + 1)'(RW) - rx_used;
  logic        rx_push;
  logic [31:0] rx_word;
  always_comb begin
    rx_word = rx_pk;
    rx_word[8 * rx_pos +: 8] = rx_data;
  end
  assign rx_push = rx_valid && !rx_bad && (rx_pos == 2'd3 || rx_last);
  always_ff @(posedge clk) if (rx_push && rx_free != '0) rxf[rxf_w[RAW-1:0]] <= rx_word;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxf_w <= '0; rxf_w0 <= '0; rx_pk <= '0; rx_pos <= '0; rx_cnt <= '0;
      rx_in <= 1'b0; rx_bad <= 1'b0; ri_w <= '0; rx_drop <= '0; drop_irq <= 1'b0;
      for (int i = 0; i < 4; i++) rinfo[i] <= '0;
    end else begin
      drop_irq <= 1'b0;
      if (rx_valid) begin
        if (!rx_in) begin                     // first byte: room for a frame record?
          rx_in <= 1'b1; rxf_w0 <= rxf_w;
          rx_bad <= !rx_en || ri_full;
        end
        rx_cnt <= rx_cnt + 16'd1;
        if (rx_pos == 2'd3 || rx_last) begin rx_pk <= '0; rx_pos <= '0; end
        else begin rx_pk <= rx_word; rx_pos <= rx_pos + 2'd1; end
        if (rx_push) begin
          if (rx_free == '0) rx_bad <= 1'b1;   // FIFO full: drop the frame
          else rxf_w <= rxf_w + 1'b1;
        end
        if (rx_last) begin
          rx_in <= 1'b0; rx_cnt <= '0;
          if (rx_bad || (rx_push && rx_free == '0) || (!rx_in && (!rx_en || ri_full))) begin
            rxf_w <= rx_in ? rxf_w0 : rxf_w;   // forget its words
            rx_drop <= rx_drop + 16'd1; drop_irq <= 1'b1;
          end else begin
            rinfo[ri_w[1:0]] <= {rx_stat, rx_cnt + 16'd1};
            ri_w <= ri_w + 3'd1;
          end
        end
      end
    end
  end
  wire _unused = &{1'b0, rx_frag, e_cyc, e_busy};
endmodule
