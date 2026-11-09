// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CI_Plus_Host: DVB Common Interface / CI+ host controller of the STB SoC
// (EN 50221 on a PC Card (PCMCIA) 8-bit bus): CAM power and reset, CIS read
// and COR write in attribute memory, the command interface in I/O space
// with its messages moved over AXI4, and the transport stream routed
// through the CAM (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// Card pins: ci_vcc_en (card power), ci_reset (RESET, high active), ci_cd_n
// (card detect, low = present), the address ci_a[14:0], the data bus
// (ci_d_o / ci_d_oe out, ci_d_i in), the strobes ci_ce_n, ci_reg_n, ci_oe_n,
// ci_we_n, ci_iord_n, ci_iowr_n, ci_wait_n (the card stretches a cycle) and
// ci_ireq_n (READY in memory mode, IREQ# in I/O mode). ci_cd_n, ci_wait_n
// and ci_ireq_n are synchronised with two flops.
// - Power (CMD.power_on, card present, ENABLE): VCC on, RESET high for
// RST_CLKS clocks, then low; once ci_ireq_n (READY) is high the card is
// ready (STATUS.ready, READY interrupt). CMD.power_off, card removal or
// ENABLE off: VCC off, RESET low, I/O mode left; an operation in progress
// ends (its DMA is flushed, STATUS.tx_fail for a TX).
// - Bus cycle: CE# and REG# low with the address (and write data) for
// SETUP + 1 clocks, then the strobe (OE#, WE#, IORD#, IOWR#) low for
// STROBE + 1 clocks and as long as WAIT# is low (seen 2 clocks late through
// its synchroniser, so cards that use WAIT# need STROBE >= 2); read data
// is taken when the strobe ends; then HOLD + 1 clocks with CE# low. A cycle
// whose WAIT# lasts WAIT_MAX clocks (0: no limit) ends at once, reads
// 0xFF (BUS_TO interrupt, TO_CNT).
// - CMD.cis_read: CIS_LEN bytes of attribute memory (even addresses
// 0, 2, 4 ...) are written to memory at CIS_ADDR, 4 per word,
// little-endian (CFG interrupt). CMD.cor_write writes COR_VAL to attribute
// address COR_ADDR and enters I/O mode (STATUS.io_mode, CFG interrupt).
// - Command interface (I/O mode; I/O addresses 0 DATA, 1 COMMAND / STATUS,
// 2 SIZE_LS, 3 SIZE_MS; status bits DA 0x80, FR 0x40; command bits RS 0x08,
// SR 0x04, SW 0x02, HC 0x01). CMD.if_reset: RS set and cleared, then STATUS
// polled until FR (CFG interrupt). CMD.tx_start: TX_LEN bytes from TX_ADDR
// (byte i in word i / 4) are sent: wait for FR, set HC, check FR again
// (else clear HC and start over), write the size, the bytes to DATA, clear
// HC (TX_DONE interrupt). STATUS is polled every POLL_DIV + 1 clocks; after
// FR_MAX polls without FR (0: no limit) the TX ends with STATUS.tx_fail.
// - RX (CTRL.poll, I/O mode, the RX buffer free): STATUS is read every
// POLL_DIV + 1 clocks; with DA set: set SR, read the size, clear SR, read
// that many bytes from DATA. The first RX_MAX go to memory at RX_ADDR (4
// per word); RX_LEN is the size, STATUS.rx_ovf flags a size over RX_MAX.
// The buffer stays full (STATUS.rx_full) until CMD.rx_arm (RX interrupt).
// Commands that arrive while an operation runs wait for it (STATUS.busy);
// a polled RX never starts while a command waits.
// - Transport stream: with CTRL.ts_route, I/O mode and power, the input
// stream goes to the CAM (ci_mo_*) and the output stream comes from it
// (ci_mi_*, packets counted in TS_CNT); otherwise the CAM is bypassed.
// Both are registered once.
// - Interrupts: DET (card detect changed), READY, CFG (CIS read, COR write
// or interface reset ended), TX_DONE, RX, IREQ (ci_ireq_n fell in I/O
// mode), BUS_TO, ERR (an AXI error response, with CFG, TX_DONE or RX).
// ============================================================================
module CI_Plus_Host_top #(
  parameter logic [3:0] AXI_ID = 4'd11
) (
  input  logic        clk,
  input  logic        rst_n,
  // card pins
  output logic        ci_vcc_en,
  output logic        ci_reset,
  input  logic        ci_cd_n,
  output logic [14:0] ci_a,
  output logic [7:0]  ci_d_o,
  output logic        ci_d_oe,
  input  logic [7:0]  ci_d_i,
  output logic        ci_ce_n,
  output logic        ci_reg_n,
  output logic        ci_oe_n,
  output logic        ci_we_n,
  output logic        ci_iord_n,
  output logic        ci_iowr_n,
  input  logic        ci_wait_n,
  input  logic        ci_ireq_n,
  // transport stream: host side and CAM side
  input  logic [7:0]  ts_in_data,
  input  logic        ts_in_valid,
  input  logic        ts_in_sop,
  output logic [7:0]  ts_out_data,
  output logic        ts_out_valid,
  output logic        ts_out_sop,
  output logic [7:0]  ci_mo_data,
  output logic        ci_mo_val,
  output logic        ci_mo_strt,
  input  logic [7:0]  ci_mi_data,
  input  logic        ci_mi_val,
  input  logic        ci_mi_strt,
  // configuration
  input  logic        enable,
  input  logic        ts_route,
  input  logic        poll,
  input  logic [3:0]  setup,
  input  logic [7:0]  strobe,
  input  logic [3:0]  hold,
  input  logic [15:0] wait_max,
  input  logic [15:0] rst_clks,
  input  logic [15:0] poll_div,
  input  logic [15:0] fr_max,
  input  logic [31:0] cis_addr,
  input  logic [15:0] cis_len,
  input  logic [14:0] cor_addr,
  input  logic [7:0]  cor_val,
  input  logic [31:0] tx_addr,
  input  logic [15:0] tx_len,
  input  logic [31:0] rx_addr,
  input  logic [15:0] rx_max,
  // commands (one-clock pulses)
  input  logic        power_on,
  input  logic        power_off,
  input  logic        cis_read,
  input  logic        cor_write,
  input  logic        if_reset,
  input  logic        tx_start,
  input  logic        rx_arm,
  // status
  output logic        powered,
  output logic        ready,
  output logic        io_mode,
  output logic        busy,
  output logic        rx_full,
  output logic        rx_ovf,
  output logic        tx_fail,
  output logic        err,
  output logic        present,
  output logic [7:0]  last_st,
  output logic [15:0] rx_len,
  output logic [15:0] tx_cnt,
  output logic [15:0] rx_cnt,
  output logic [15:0] ts_cnt,
  output logic [15:0] to_cnt,
  // interrupt pulses
  output logic        det,
  output logic        rdy,
  output logic        cfg,
  output logic        tx_done,
  output logic        rx,
  output logic        ireq,
  output logic        bus_to,
  output logic        err_irq,
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
  // ---------------- synchronisers ----------------
  logic [1:0] cd_s, wt_s, iq_s;
  logic       cd_q, iq_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cd_s <= 2'b11; wt_s <= 2'b11; iq_s <= 2'b11; cd_q <= 1'b1; iq_q <= 1'b1;
    end else begin
      cd_s <= {cd_s[0], ci_cd_n}; wt_s <= {wt_s[0], ci_wait_n}; iq_s <= {iq_s[0], ci_ireq_n};
      cd_q <= cd_s[1]; iq_q <= iq_s[1];
    end
  end
  assign present = !cd_s[1];
  assign det     = cd_s[1] != cd_q;
  wire   wait_lo = !wt_s[1];

  // ---------------- power ----------------
  typedef enum logic [1:0] {P_OFF, P_RST, P_WRDY, P_ON} pst_t;
  pst_t        pst;
  logic [15:0] pc;
  wire go_off = power_off || !present || !enable;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_OFF; pc <= '0; ci_vcc_en <= 1'b0; ci_reset <= 1'b0;
    end else begin
      if (pst != P_OFF && go_off) begin
        pst <= P_OFF; ci_vcc_en <= 1'b0; ci_reset <= 1'b0;
      end else begin
        case (pst)
          P_OFF: if (power_on && present && enable) begin
            pst <= P_RST; pc <= '0; ci_vcc_en <= 1'b1; ci_reset <= 1'b1;
          end
          P_RST: begin
            pc <= pc + 16'd1;
            if (pc + 16'd1 >= rst_clks) begin pst <= P_WRDY; ci_reset <= 1'b0; pc <= '0; end
          end
          P_WRDY: begin                            // READY seen after its synchroniser
            if (pc != 16'd3) pc <= pc + 16'd1;
            else if (iq_s[1]) pst <= P_ON;
          end
          default: ;
        endcase
      end
    end
  end
  assign powered = ci_vcc_en;
  assign ready   = (pst == P_ON);
  assign rdy     = (pst == P_WRDY) && pc == 16'd3 && iq_s[1] && !go_off;
  wire   abort   = (pst != P_ON);
  assign ireq    = io_mode && !abort && iq_q && !iq_s[1];

  // ---------------- bus cycle engine ----------------
  typedef enum logic [1:0] {B_IDLE, B_SETUP, B_STRB, B_HOLD} bst_t;
  bst_t        bst;
  logic [7:0]  bc;
  logic [15:0] bw;
  logic        b_go, b_done, b_to;
  logic [1:0]  b_kind;                             // 0 attr rd, 1 attr wr, 2 io rd, 3 io wr
  logic [14:0] b_addr;
  logic [7:0]  b_wd, b_rd;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bst <= B_IDLE; bc <= '0; bw <= '0; b_done <= 1'b0; b_to <= 1'b0; b_rd <= '0;
      ci_a <= '0; ci_d_o <= '0; ci_d_oe <= 1'b0; ci_ce_n <= 1'b1; ci_reg_n <= 1'b1;
      ci_oe_n <= 1'b1; ci_we_n <= 1'b1; ci_iord_n <= 1'b1; ci_iowr_n <= 1'b1;
    end else begin
      b_done <= 1'b0; b_to <= 1'b0;
      if (abort) begin
        bst <= B_IDLE; ci_d_oe <= 1'b0; ci_ce_n <= 1'b1; ci_reg_n <= 1'b1;
        ci_oe_n <= 1'b1; ci_we_n <= 1'b1; ci_iord_n <= 1'b1; ci_iowr_n <= 1'b1;
      end else begin
        case (bst)
          B_IDLE: if (b_go) begin
            bst <= B_SETUP; bc <= {4'd0, setup};
            ci_a <= b_addr; ci_d_o <= b_wd; ci_d_oe <= b_kind[0]; ci_ce_n <= 1'b0; ci_reg_n <= 1'b0;
          end
          B_SETUP: if (bc == 8'd0) begin
            bst <= B_STRB; bc <= strobe; bw <= '0;
            case (b_kind)
              2'd0: ci_oe_n <= 1'b0;
              2'd1: ci_we_n <= 1'b0;
              2'd2: ci_iord_n <= 1'b0;
              default: ci_iowr_n <= 1'b0;
            endcase
          end else bc <= bc - 8'd1;
          B_STRB: if (bc != 8'd0) bc <= bc - 8'd1;
          else if (wait_lo && !(wait_max != 16'd0 && bw + 16'd1 >= wait_max)) bw <= bw + 16'd1;
          else begin
            bst <= B_HOLD; bc <= {4'd0, hold};
            b_rd <= wait_lo ? 8'hFF : ci_d_i; b_to <= wait_lo;
            ci_oe_n <= 1'b1; ci_we_n <= 1'b1; ci_iord_n <= 1'b1; ci_iowr_n <= 1'b1;
          end
          default: if (bc == 8'd0) begin          // B_HOLD
            bst <= B_IDLE; b_done <= 1'b1;
            ci_d_oe <= 1'b0; ci_ce_n <= 1'b1; ci_reg_n <= 1'b1;
          end else bc <= bc - 8'd1;
        endcase
      end
    end
  end
  assign bus_to = b_to;

  // ---------------- AXI engine (one job at a time, one direction) ----------------
  logic        e_start, e_rd, e_busy, e_done, e_err, e_used, e_fin, e_errq;
  logic [31:0] e_addr, e_cycles;
  logic [15:0] e_len, e_left;                      // words of the job, words still to push (writes)
  logic        rs_valid, rs_ready, ws_valid, ws_ready;
  logic [31:0] rs_data, ws_data;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(e_start), .rd_en(e_rd), .wr_en(!e_rd),
    .src(e_addr), .dst(e_addr), .len(e_len),
    .busy(e_busy), .done(e_done), .err(e_err), .cycles(e_cycles),
    .rs_valid(rs_valid), .rs_data(rs_data), .rs_ready(rs_ready),
    .ws_valid(ws_valid), .ws_data(ws_data), .ws_ready(ws_ready),
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  // ---------------- sequencer ----------------
  typedef enum logic [4:0] {
    Q_IDLE, Q_BUS, Q_CIS, Q_CIS_GOT, Q_COR_END, Q_RS0, Q_FR, Q_FR_CHK, Q_GAP,
    Q_TX_HC, Q_TX_FR2, Q_TX_CHK2, Q_TX_SL, Q_TX_SM, Q_TX_D, Q_TX_END,
    Q_RX_ST, Q_RX_CHK, Q_RX_SR, Q_RX_SL, Q_RX_SM, Q_RX_SR0, Q_RX_GO, Q_RX_D, Q_RX_GOT,
    Q_EWAIT, Q_FLUSH
  } qst_t;
  qst_t        qs, q_ret, q_after;
  typedef enum logic [1:0] {J_CFG, J_TX, J_RX} job_t;
  job_t        job;
  logic        p_cis, p_cor, p_rst, p_tx;           // waiting commands
  logic [15:0] qi, q_n, q_store, tries, gap, pt;    // byte index, size, bytes stored, FR polls, gap, RX poll timer
  logic [31:0] pk;                                 // bytes being packed / unpacked
  logic        ws_v;                               // pk is a word for the write stream

  wire   e_open   = e_used && !e_fin;              // the DMA job has not finished
  wire   flush_w  = qs == Q_FLUSH && !e_rd && e_open && e_left != 16'd0;
  assign busy     = (qs != Q_IDLE) || p_cis || p_cor || p_rst || p_tx;
  assign ws_valid = ws_v || flush_w;
  assign ws_data  = ws_v ? pk : 32'h0;
  assign rs_ready = (qs == Q_FLUSH) || (qs == Q_TX_D && qi[1:0] == 2'd0);
  wire [15:0] store_n = (q_n > rx_max) ? rx_max : q_n;
  wire [7:0]  tx_byte = (qi[1:0] == 2'd0) ? rs_data[7:0] : pk[8 * qi[1:0] +: 8];
  wire        free    = !ws_v || ws_ready;          // pk can take the next word

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qs <= Q_IDLE; q_ret <= Q_IDLE; q_after <= Q_IDLE; job <= J_CFG;
      p_cis <= 1'b0; p_cor <= 1'b0; p_rst <= 1'b0; p_tx <= 1'b0;
      qi <= '0; q_n <= '0; q_store <= '0; tries <= '0; gap <= '0; pt <= '0; pk <= '0; ws_v <= 1'b0;
      b_go <= 1'b0; b_kind <= 2'd0; b_addr <= '0; b_wd <= '0;
      e_start <= 1'b0; e_rd <= 1'b0; e_addr <= '0; e_len <= '0; e_left <= '0;
      e_used <= 1'b0; e_fin <= 1'b0; e_errq <= 1'b0;
      io_mode <= 1'b0; rx_full <= 1'b0; rx_ovf <= 1'b0; tx_fail <= 1'b0; err <= 1'b0;
      last_st <= '0; rx_len <= '0; tx_cnt <= '0; rx_cnt <= '0; to_cnt <= '0;
      cfg <= 1'b0; tx_done <= 1'b0; rx <= 1'b0; err_irq <= 1'b0;
    end else begin
      b_go <= 1'b0; e_start <= 1'b0; cfg <= 1'b0; tx_done <= 1'b0; rx <= 1'b0; err_irq <= 1'b0;
      if (e_done) begin e_fin <= 1'b1; if (e_err) e_errq <= 1'b1; end
      if (ws_valid && ws_ready) begin ws_v <= 1'b0; e_left <= e_left - 16'd1; end
      if (b_to && to_cnt != 16'hFFFF) to_cnt <= to_cnt + 16'd1;
      if (pt != 16'd0) pt <= pt - 16'd1;
      // commands
      if (!abort) begin
        if (cis_read) p_cis <= 1'b1;
        if (cor_write) p_cor <= 1'b1;
        if (if_reset && io_mode) p_rst <= 1'b1;
        if (tx_start && io_mode && tx_len != 16'd0) p_tx <= 1'b1;
      end
      if (rx_arm) rx_full <= 1'b0;
      if (power_on && pst == P_OFF) begin err <= 1'b0; rx_full <= 1'b0; rx_ovf <= 1'b0; tx_fail <= 1'b0; end
      case (qs)
        Q_IDLE: if (!abort) begin
          qi <= '0; tries <= '0; e_used <= 1'b0; e_fin <= 1'b0; e_errq <= 1'b0;
          if (p_rst) begin                         // interface reset: RS set
            p_rst <= 1'b0; job <= J_CFG;
            b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h08; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RS0;
          end else if (p_cis) begin
            p_cis <= 1'b0; job <= J_CFG; q_n <= cis_len;
            if (cis_len != 16'd0) begin
              e_rd <= 1'b0; e_addr <= cis_addr; e_len <= (cis_len + 16'd3) >> 2; e_left <= (cis_len + 16'd3) >> 2;
              e_start <= 1'b1; e_used <= 1'b1;
              qs <= Q_CIS;
            end else qs <= Q_EWAIT;
          end else if (p_cor) begin
            p_cor <= 1'b0; job <= J_CFG;
            b_kind <= 2'd1; b_addr <= cor_addr; b_wd <= cor_val; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_COR_END;
          end else if (p_tx) begin
            p_tx <= 1'b0; job <= J_TX; q_n <= tx_len; tx_fail <= 1'b0;
            e_rd <= 1'b1; e_addr <= tx_addr; e_len <= (tx_len + 16'd3) >> 2; e_start <= 1'b1; e_used <= 1'b1;
            qs <= Q_FR; q_after <= Q_TX_HC;
          end else if (poll && io_mode && !rx_full && pt == 16'd0) begin
            job <= J_RX; qs <= Q_RX_ST;
          end
        end
        // one bus cycle, then q_ret
        Q_BUS: if (b_done) qs <= q_ret;
        // CIS read
        Q_CIS: if (free) begin
          b_kind <= 2'd0; b_addr <= {qi[13:0], 1'b0}; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_CIS_GOT;
        end
        Q_CIS_GOT: begin
          pk[8 * qi[1:0] +: 8] <= b_rd;
          if (qi[1:0] == 2'd0) pk[31:8] <= '0;
          if (qi[1:0] == 2'd3 || qi + 16'd1 == q_n) ws_v <= 1'b1;
          qi <= qi + 16'd1;
          if (qi + 16'd1 == q_n) qs <= Q_EWAIT; else qs <= Q_CIS;
        end
        Q_COR_END: begin io_mode <= 1'b1; qs <= Q_EWAIT; end
        // interface reset: RS cleared, then wait for FR
        Q_RS0: begin
          b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h00; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_FR; q_after <= Q_EWAIT;
        end
        // read STATUS until FR, then q_after
        Q_FR: begin
          b_kind <= 2'd2; b_addr <= 15'd1; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_FR_CHK;
        end
        Q_FR_CHK: begin
          last_st <= b_rd; tries <= tries + 16'd1;
          if (b_rd[6]) qs <= q_after;
          else if (fr_max != 16'd0 && tries + 16'd1 >= fr_max) begin
            if (job == J_TX) begin tx_fail <= 1'b1; qs <= Q_FLUSH; end
            else qs <= Q_EWAIT;
          end else begin gap <= poll_div; qs <= Q_GAP; end
        end
        Q_GAP: if (gap == 16'd0) qs <= Q_FR; else gap <= gap - 16'd1;
        // TX
        Q_TX_HC: begin
          b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h01; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_TX_FR2;
        end
        Q_TX_FR2: begin
          b_kind <= 2'd2; b_addr <= 15'd1; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_TX_CHK2;
        end
        Q_TX_CHK2: begin
          last_st <= b_rd;
          if (b_rd[6]) qs <= Q_TX_SL;
          else begin                               // the CAM took the buffer: clear HC, start over
            b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h00; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_FR; q_after <= Q_TX_HC;
          end
        end
        Q_TX_SL: begin
          b_kind <= 2'd3; b_addr <= 15'd2; b_wd <= q_n[7:0]; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_TX_SM;
        end
        Q_TX_SM: begin
          b_kind <= 2'd3; b_addr <= 15'd3; b_wd <= q_n[15:8]; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_TX_D;
        end
        Q_TX_D: if (qi[1:0] != 2'd0 || rs_valid) begin
          if (qi[1:0] == 2'd0) pk <= rs_data;
          b_kind <= 2'd3; b_addr <= 15'd0; b_wd <= tx_byte; b_go <= 1'b1; qs <= Q_BUS;
          qi <= qi + 16'd1;
          if (qi + 16'd1 == q_n) q_ret <= Q_TX_END; else q_ret <= Q_TX_D;
        end
        Q_TX_END: begin
          b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h00; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_EWAIT;
        end
        // RX
        Q_RX_ST: begin
          b_kind <= 2'd2; b_addr <= 15'd1; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RX_CHK;
        end
        Q_RX_CHK: begin
          last_st <= b_rd;
          if (b_rd[7]) begin
            b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h04; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RX_SL;
          end else begin pt <= poll_div; qs <= Q_IDLE; end
        end
        Q_RX_SL: begin
          b_kind <= 2'd2; b_addr <= 15'd2; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RX_SM;
        end
        Q_RX_SM: begin
          q_n[7:0] <= b_rd;
          b_kind <= 2'd2; b_addr <= 15'd3; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RX_SR0;
        end
        Q_RX_SR0: begin
          q_n[15:8] <= b_rd;
          b_kind <= 2'd3; b_addr <= 15'd1; b_wd <= 8'h00; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RX_GO;
        end
        Q_RX_GO: begin
          q_store <= store_n; qs <= Q_RX_D;
          if (store_n != 16'd0) begin
            e_rd <= 1'b0; e_addr <= rx_addr; e_len <= (store_n + 16'd3) >> 2; e_left <= (store_n + 16'd3) >> 2;
            e_start <= 1'b1; e_used <= 1'b1;
          end
        end
        Q_RX_D: if (qi == q_n) qs <= Q_EWAIT;
        else if (free) begin
          b_kind <= 2'd2; b_addr <= 15'd0; b_go <= 1'b1; qs <= Q_BUS; q_ret <= Q_RX_GOT;
        end
        Q_RX_GOT: begin
          if (qi < q_store) begin
            pk[8 * qi[1:0] +: 8] <= b_rd;
            if (qi[1:0] == 2'd0) pk[31:8] <= '0;
            if (qi[1:0] == 2'd3 || qi + 16'd1 == q_store) ws_v <= 1'b1;
          end
          qi <= qi + 16'd1;
          qs <= Q_RX_D;
        end
        // wait for the DMA, then report
        Q_EWAIT: if (!ws_v && !e_open) begin
          qs <= Q_IDLE; pt <= poll_div;
          if (e_errq) err <= 1'b1;
          err_irq <= e_errq;
          case (job)
            J_CFG: cfg <= 1'b1;
            J_TX: begin tx_done <= 1'b1; if (tx_cnt != 16'hFFFF) tx_cnt <= tx_cnt + 16'd1; end
            default: begin
              rx <= 1'b1; rx_full <= 1'b1; rx_len <= q_n; rx_ovf <= q_n > q_store;
              if (rx_cnt != 16'hFFFF) rx_cnt <= rx_cnt + 16'd1;
            end
          endcase
        end
        default: if (!e_open) begin               // Q_FLUSH: let the DMA job finish
          qs <= Q_IDLE; pt <= poll_div;
          if (job == J_TX) tx_done <= 1'b1;
          if (e_errq) err <= 1'b1;
        end
      endcase
      // power lost: the operation ends through Q_FLUSH
      if (abort) begin
        io_mode <= 1'b0; p_cis <= 1'b0; p_cor <= 1'b0; p_rst <= 1'b0; p_tx <= 1'b0; ws_v <= 1'b0;
        if (qs != Q_IDLE && qs != Q_FLUSH) begin
          if (job == J_TX) tx_fail <= 1'b1;
          qs <= Q_FLUSH;
        end
      end
    end
  end

  // ---------------- transport stream ----------------
  wire route = ts_route && io_mode && !abort;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ci_mo_data <= '0; ci_mo_val <= 1'b0; ci_mo_strt <= 1'b0;
      ts_out_data <= '0; ts_out_valid <= 1'b0; ts_out_sop <= 1'b0; ts_cnt <= '0;
    end else begin
      ci_mo_data <= route ? ts_in_data : 8'h00;
      ci_mo_val  <= route && ts_in_valid;
      ci_mo_strt <= route && ts_in_valid && ts_in_sop;
      if (route) begin
        ts_out_data <= ci_mi_data; ts_out_valid <= ci_mi_val; ts_out_sop <= ci_mi_val && ci_mi_strt;
        if (ci_mi_val && ci_mi_strt && ts_cnt != 16'hFFFF) ts_cnt <= ts_cnt + 16'd1;
      end else begin
        ts_out_data <= ts_in_data; ts_out_valid <= ts_in_valid; ts_out_sop <= ts_in_valid && ts_in_sop;
      end
    end
  end
endmodule
