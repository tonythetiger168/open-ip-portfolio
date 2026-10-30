// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// IO_LINK_top v1.0: IO-Link (IEC 61131-9 / SDCI) master port and device data
// link layer, selected by cfg_master
// ----------------------------------------------------------------------------
//  - Physical layer side: txd / tx_en drive the C/Q transceiver, rxd is the
//    received line (UART level: 1 idle). The line is only read while tx_en
//    is low, so the own transmission is never received.
//  - UART: start bit, 8 data bits LSB first, even parity, one stop bit;
//    cfg_bit clocks per bit (COM1 4.8, COM2 38.4, COM3 230.4 kbit/s).
//    The receiver samples in the middle of each bit.
//  - Wake-up request (WURQ): the master drives the line low for cfg_wurq
//    clocks (80 us); a device accepts a low pulse of cfg_wurq +- 1/16
//    (75..85 us) and pulses d_wurq. The break octet it causes is dropped.
//  - M-sequence, master to device: MC {R/W (1 read), channel (0 process,
//    1 page, 2 diagnosis, 3 ISDU), address}, CKT {M-sequence type
//    cfg_mtype, checksum}, cfg_pdout_len PD octets, and on a write
//    cfg_od_len OD octets. Device to master: on a read cfg_od_len OD
//    octets, cfg_pdin_len PD octets, then CKS {event flag, PD invalid,
//    checksum}. Lengths are 0..32 (larger values act as 32).
//  - Checksum: the XOR of 0x52 and every octet of the message (its own
//    6 checksum bits 0), compressed to 6 bits:
//    c5 = x7^x5^x3^x1, c4 = x6^x4^x2^x0, c3 = x7^x6, c2 = x5^x4,
//    c1 = x3^x2, c0 = x1^x0.
//  - Message buffer, 256 x 8, host port (host_rdata the clock after
//    host_rd; a host write to the address the core writes in the same
//    clock is dropped):
//      0x00 tx PD (master: PD out, device: PD in)   0x20 tx OD
//      0x40 rx PD (master: PD in, device: PD out)   0x60 rx OD
//      0x80 device parameter page (page channel reads, address + i mod 32)
//      0xA0..0xFF free
//  - Master: m_start sends the message for m_mc, then waits for the reply
//    (up to cfg_resp_timeout bit times of silence after its own last
//    octet and between reply octets). The reply is stored as it comes;
//    m_done ends every request with m_err_timeout (silence), m_err_uart
//    (parity / framing, the reply is not read further) or m_err_cks;
//    m_cks / m_cnt hold the CKS octet and the octets received. m_wurq
//    sends a wake-up request (m_done, no error).
//  - Device: stores PD out at 0x40 and written OD at 0x60 as they come;
//    a complete message pulses d_msg with d_msg_mc and d_msg_why
//    (0 ok, 1 parity / framing, 2 checksum, 3 M-sequence type, 4 more
//    than 16 bit times between two octets). After an error it waits for
//    16 idle bit times. Only a message without error is answered,
//    cfg_ta bit times (1..15, 0 acts as 1) after its last stop bit;
//    reads take the OD from the page (channel 1) or 0x20.
// ============================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// UART receiver: start on a falling edge, samples in the middle of each bit
// ---------------------------------------------------------------------------
module IO_LINK_urx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] cfg_bit,
  input  logic        en,
  input  logic        rxd,
  output logic        busy,
  output logic        valid,        // at the stop bit's middle
  output logic [7:0]  data,
  output logic        perr,
  output logic        ferr
);
  logic        prev;
  logic [15:0] cnt;
  logic [3:0]  bi;                  // 0 start, 1..8 data, 9 parity, 10 stop
  logic [8:0]  sh;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev <= 1'b1; cnt <= '0; bi <= '0; sh <= '0; busy <= 1'b0;
      valid <= 1'b0; data <= '0; perr <= 1'b0; ferr <= 1'b0;
    end else begin
      valid <= 1'b0;
      prev <= rxd;
      if (!en) begin
        busy <= 1'b0; prev <= 1'b1;
      end else if (!busy) begin
        if (prev && !rxd) begin busy <= 1'b1; bi <= '0; cnt <= {1'b0, cfg_bit[15:1]}; end
      end else if (cnt > 16'd1) begin
        cnt <= cnt - 16'd1;
      end else begin
        cnt <= cfg_bit;
        if (bi == 4'd0) begin
          if (rxd) busy <= 1'b0;                                   // a glitch
          bi <= 4'd1;
        end else if (bi == 4'd10) begin
          busy <= 1'b0; valid <= 1'b1;
          data <= sh[7:0]; perr <= ^sh; ferr <= !rxd;
        end else begin
          sh <= {rxd, sh[8:1]}; bi <= bi + 4'd1;
        end
      end
    end
  end
endmodule

// ---------------------------------------------------------------------------
// UART transmitter
// ---------------------------------------------------------------------------
module IO_LINK_utx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] cfg_bit,
  input  logic        ld,
  input  logic [7:0]  d,
  output logic        txd,
  output logic        busy,
  output logic        done          // the stop bit ended
);
  logic [15:0] cnt;
  logic [3:0]  bi;
  logic [9:0]  sh;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= '0; bi <= '0; sh <= '1; busy <= 1'b0; done <= 1'b0; txd <= 1'b1;
    end else begin
      done <= 1'b0;
      if (ld && !busy) begin
        busy <= 1'b1; txd <= 1'b0; cnt <= cfg_bit; bi <= '0;
        sh <= {1'b1, ^d, d};
      end else if (busy) begin
        if (cnt > 16'd1) cnt <= cnt - 16'd1;
        else begin
          cnt <= cfg_bit;
          if (bi == 4'd10) begin busy <= 1'b0; done <= 1'b1; end
          else begin txd <= sh[0]; sh <= {1'b1, sh[9:1]}; bi <= bi + 4'd1; end
        end
      end
    end
  end
endmodule

// ---------------------------------------------------------------------------
module IO_LINK_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cfg_master,         // 1 master port, 0 device
  input  logic [15:0] cfg_bit,            // clocks per bit, >= 4
  input  logic [15:0] cfg_wurq,           // clocks of the wake-up request
  input  logic [1:0]  cfg_mtype,          // M-sequence type in CKT
  input  logic [5:0]  cfg_pdout_len,
  input  logic [5:0]  cfg_pdin_len,
  input  logic [5:0]  cfg_od_len,
  // line
  output logic        txd,
  output logic        tx_en,
  input  logic        rxd,
  // message buffer
  input  logic        host_rd,
  input  logic        host_wr,
  input  logic [7:0]  host_addr,
  input  logic [7:0]  host_wdata,
  output logic [7:0]  host_rdata,
  // master
  input  logic [7:0]  cfg_resp_timeout,   // bit times of silence
  input  logic        m_wurq,
  input  logic        m_start,
  input  logic [7:0]  m_mc,
  output logic        m_busy,
  output logic        m_done,
  output logic        m_err_timeout,
  output logic        m_err_uart,
  output logic        m_err_cks,
  output logic [7:0]  m_cks,
  output logic [6:0]  m_cnt,
  // device
  input  logic [3:0]  cfg_ta,             // response delay, bit times
  input  logic        cfg_event,          // CKS event flag
  input  logic        cfg_pd_invalid,     // CKS PD status
  output logic        d_wurq,
  output logic        d_msg,
  output logic [7:0]  d_msg_mc,
  output logic [2:0]  d_msg_why
);
  // ---------------- helpers ----------------
  function automatic logic [5:0] lim(input logic [5:0] n);
    lim = n > 6'd32 ? 6'd32 : n;
  endfunction
  function automatic logic [5:0] comp(input logic [7:0] x);
    comp = {x[7] ^ x[5] ^ x[3] ^ x[1], x[6] ^ x[4] ^ x[2] ^ x[0], x[7] ^ x[6], x[5] ^ x[4],
            x[3] ^ x[2], x[1] ^ x[0]};
  endfunction
  wire [5:0] n_pdo = lim(cfg_pdout_len);
  wire [5:0] n_pdi = lim(cfg_pdin_len);
  wire [5:0] n_od  = lim(cfg_od_len);

  // ---------------- line ----------------
  logic s1, s2;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin s1 <= 1'b1; s2 <= 1'b1; end
    else begin s1 <= rxd; s2 <= s1; end

  logic       u_ld;
  logic [7:0] u_d;
  logic       u_txd, u_busy, u_done;
  IO_LINK_utx u_tx (.clk, .rst_n, .cfg_bit, .ld(u_ld), .d(u_d), .txd(u_txd), .busy(u_busy), .done(u_done));
  logic       r_busy, r_valid, r_perr, r_ferr;
  logic [7:0] r_data;
  IO_LINK_urx u_rx (.clk, .rst_n, .cfg_bit, .en(!tx_en), .rxd(s2), .busy(r_busy), .valid(r_valid),
                    .data(r_data), .perr(r_perr), .ferr(r_ferr));
  wire r_break = r_valid && r_ferr && r_data == 8'h00 && !r_perr;
  wire r_bad   = r_valid && (r_perr || r_ferr);

  // bit-time ticks, restarted by bt_clr
  logic        bt_clr, bt_tick;
  logic [15:0] bt;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin bt <= '0; bt_tick <= 1'b0; end
    else begin
      bt_tick <= 1'b0;
      if (bt_clr) bt <= '0;
      else if (bt + 16'd1 >= cfg_bit) begin bt <= '0; bt_tick <= 1'b1; end
      else bt <= bt + 16'd1;
    end

  // ---------------- message buffer ----------------
  logic [7:0] ram [0:255];
  logic       mem_wr;
  logic [7:0] mem_waddr, mem_wdata, mem_raddr;
  wire  [7:0] mem_rdata = ram[mem_raddr];
  always_ff @(posedge clk) begin
    if (mem_wr) ram[mem_waddr] <= mem_wdata;
    if (host_wr && !(mem_wr && mem_waddr == host_addr)) ram[host_addr] <= host_wdata;
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) host_rdata <= '0;
    else if (host_rd) host_rdata <= ram[host_addr];

  // ---------------- shared message state ----------------
  typedef enum logic [2:0] {S_IDLE, S_WURQ, S_SUM, S_TX, S_RX, S_TA, S_DROP} st_t;
  st_t         st;
  logic [7:0]  mc, ckt, acc;
  logic [6:0]  oi;                         // octet index
  logic [6:0]  n_tx;                       // octets to send
  logic [15:0] wc;                         // WURQ clocks
  logic [7:0]  sil;                        // bit times of silence
  logic [15:0] lowc;                       // device: clocks the line is low
  logic        tx_on;
  logic        role_q;                       // cfg_master of the previous clock

  // octet oi of the master's message or the device's reply (payload from the buffer)
  wire        m_rd    = mc[7];
  wire [6:0]  m_pl    = {1'b0, n_pdo} + (m_rd ? 7'd0 : {1'b0, n_od});      // master payload
  wire [5:0]  rd_od   = m_rd ? n_od : 6'd0;                                 // OD octets in the reply
  wire [6:0]  d_pl    = {1'b0, rd_od} + {1'b0, n_pdi};                     // device payload
  // buffer address of payload octet k: master (PD out, then OD), device (OD, then PD in)
  wire [6:0] m_k  = st == S_SUM ? oi : oi - 7'd2;
  wire [6:0] m_j  = m_k - {1'b0, n_pdo};
  wire [6:0] d_j  = oi - {1'b0, rd_od};
  wire [4:0] d_pg = mc[4:0] + oi[4:0];
  always_comb begin
    if (cfg_master) mem_raddr = m_k < {1'b0, n_pdo} ? {1'b0, m_k} : {3'b001, m_j[4:0]};
    else if (oi >= {1'b0, rd_od}) mem_raddr = {3'b000, d_j[4:0]};
    else if (mc[6:5] == 2'd1) mem_raddr = {3'b100, d_pg};
    else mem_raddr = {3'b001, oi[4:0]};
  end

  // reply / message octet oi received: where it goes
  wire [6:0] rx_k  = oi;                                                     // master: reply octet
  wire [6:0] m_rn  = {1'b0, rd_od} + {1'b0, n_pdi} + 7'd1;                 // reply octets
  wire [6:0] d_k   = oi - 7'd2;                                              // device: payload octet
  wire [6:0] m_pi  = rx_k - {1'b0, rd_od};                                 // master: PD in octet
  wire [6:0] d_oi  = d_k - {1'b0, n_pdo};                                   // device: OD octet
  wire [6:0] d_n   = 7'd2 + {1'b0, n_pdo} + (mc[7] ? 7'd0 : {1'b0, n_od});   // message octets

  always_comb begin
    mem_wr = 1'b0; mem_waddr = '0; mem_wdata = r_data;
    if (st == S_RX && r_valid && !r_bad) begin
      if (cfg_master) begin
        if (rx_k < m_rn - 7'd1) begin
          mem_wr = 1'b1;
          mem_waddr = rx_k < {1'b0, rd_od} ? {3'b011, rx_k[4:0]} : {3'b010, m_pi[4:0]};
        end
      end else if (oi >= 7'd2) begin
        mem_wr = 1'b1;
        mem_waddr = d_k < {1'b0, n_pdo} ? {3'b010, d_k[4:0]} : {3'b011, d_oi[4:0]};
      end
    end
  end

  // device report
  task automatic report(input logic [7:0] c, input logic [2:0] why);
    d_msg <= 1'b1; d_msg_mc <= c; d_msg_why <= why;
  endtask
  // device: CKT and checksum with octet oi >= 1 just received
  wire [7:0] d_ck  = oi == 7'd1 ? r_data : ckt;
  wire [7:0] d_acc = acc ^ (oi == 7'd1 ? {r_data[7:6], 6'd0} : r_data);

  always_comb begin
    u_ld = 1'b0; u_d = mem_rdata;
    if (st == S_TX && !u_busy && !u_done && oi < n_tx) begin
      u_ld = 1'b1;
      if (cfg_master) u_d = oi == 7'd0 ? mc : oi == 7'd1 ? ckt : mem_rdata;
      else if (oi == n_tx - 7'd1) u_d = {cfg_event, cfg_pd_invalid, comp(acc ^ {cfg_event, cfg_pd_invalid, 6'd0})};
    end
  end
  assign tx_en = tx_on;
  assign txd   = st == S_WURQ ? 1'b0 : u_txd;
  assign bt_clr = r_busy || r_valid || u_done || !(st == S_RX || st == S_TA || st == S_DROP);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; mc <= '0; ckt <= '0; acc <= '0; oi <= '0; n_tx <= '0; wc <= '0; sil <= '0;
      lowc <= '0; tx_on <= 1'b0; role_q <= 1'b0;
      m_busy <= 1'b0; m_done <= 1'b0; m_err_timeout <= 1'b0; m_err_uart <= 1'b0; m_err_cks <= 1'b0;
      m_cks <= '0; m_cnt <= '0;
      d_wurq <= 1'b0; d_msg <= 1'b0; d_msg_mc <= '0; d_msg_why <= '0;
    end else begin
      m_done <= 1'b0; d_wurq <= 1'b0; d_msg <= 1'b0;
      if (bt_tick && sil != 8'hFF) sil <= sil + 8'd1;
      if (r_valid || u_done) sil <= '0;
      role_q <= cfg_master;
      if (cfg_master != role_q) begin                                  // role changed: start over
        st <= S_IDLE; oi <= '0; tx_on <= 1'b0; m_busy <= 1'b0;
      end else if (cfg_master) begin
        // ======================= master =======================
        case (st)
          S_IDLE: begin
            if (m_wurq) begin
              st <= S_WURQ; tx_on <= 1'b1; wc <= cfg_wurq; m_busy <= 1'b1;
            end else if (m_start) begin
              st <= S_SUM; mc <= m_mc; oi <= '0; acc <= 8'h52 ^ m_mc ^ {cfg_mtype, 6'd0};
              m_busy <= 1'b1; m_err_timeout <= 1'b0; m_err_uart <= 1'b0; m_err_cks <= 1'b0;
              m_cks <= '0; m_cnt <= '0;
            end
          end
          S_WURQ: begin
            if (wc > 16'd1) wc <= wc - 16'd1;
            else begin st <= S_IDLE; tx_on <= 1'b0; m_busy <= 1'b0; m_done <= 1'b1; end
          end
          S_SUM: begin
            if (oi < m_pl) begin acc <= acc ^ mem_rdata; oi <= oi + 7'd1; end
            else begin
              ckt <= {cfg_mtype, comp(acc)}; st <= S_TX; oi <= '0; n_tx <= m_pl + 7'd2; tx_on <= 1'b1;
            end
          end
          S_TX: begin
            if (u_ld) oi <= oi + 7'd1;
            if (u_done && oi == n_tx) begin
              st <= S_RX; tx_on <= 1'b0; oi <= '0; acc <= 8'h52; sil <= '0;
            end
          end
          default: begin                                               // S_RX
            if (r_valid) begin
              m_cnt <= m_cnt + 7'd1; oi <= oi + 7'd1;
              acc <= acc ^ r_data;
              if (r_bad) begin
                m_err_uart <= 1'b1; st <= S_IDLE; oi <= '0; m_busy <= 1'b0; m_done <= 1'b1;
              end else if (oi == m_rn - 7'd1) begin
                m_cks <= r_data;
                if (comp(acc ^ {r_data[7:6], 6'd0}) != r_data[5:0]) m_err_cks <= 1'b1;
                st <= S_IDLE; oi <= '0; m_busy <= 1'b0; m_done <= 1'b1;
              end
            end else if (!r_busy && sil >= cfg_resp_timeout) begin
              m_err_timeout <= 1'b1; st <= S_IDLE; oi <= '0; m_busy <= 1'b0; m_done <= 1'b1;
            end
          end
        endcase
      end else begin
        // ======================= device =======================
        lowc <= (s2 || tx_on) ? 16'd0 : (&lowc ? lowc : lowc + 16'd1);
        if (s2 && lowc != 16'd0 && lowc >= cfg_wurq - {4'd0, cfg_wurq[15:4]} &&
            {1'b0, lowc} <= {1'b0, cfg_wurq} + {5'd0, cfg_wurq[15:4]}) begin
          d_wurq <= 1'b1; st <= S_IDLE; oi <= '0; tx_on <= 1'b0;
        end else case (st)
          S_IDLE, S_RX: begin
            if (r_break) begin
              st <= S_IDLE; oi <= '0;
            end else if (r_bad) begin
              report(oi == 7'd0 ? r_data : mc, 3'd1); st <= S_DROP; oi <= '0;
            end else if (r_valid) begin
              st <= S_RX;
              if (oi == 7'd0) begin
                mc <= r_data; acc <= 8'h52 ^ r_data; oi <= 7'd1;
              end else begin
                if (oi == 7'd1) ckt <= r_data;
                acc <= d_acc; oi <= oi + 7'd1;
                if (oi + 7'd1 == d_n) begin                              // the message is complete
                  st <= S_IDLE; oi <= '0;
                  if (d_ck[7:6] != cfg_mtype) report(mc, 3'd3);
                  else if (comp(d_acc) != d_ck[5:0]) report(mc, 3'd2);
                  else begin report(mc, 3'd0); st <= S_TA; sil <= '0; end
                end
              end
            end else if (st == S_RX && !r_busy && sil >= 8'd16) begin
              report(mc, 3'd4); st <= S_IDLE; oi <= '0;
            end
          end
          S_DROP: begin
            if (!r_busy && sil >= 8'd16) begin st <= S_IDLE; oi <= '0; end
          end
          S_TA: begin
            if (sil >= {4'd0, cfg_ta} && (sil != 8'd0)) begin
              st <= S_TX; tx_on <= 1'b1; oi <= '0; acc <= 8'h52; n_tx <= d_pl + 7'd1;
            end
          end
          default: begin                                               // S_TX
            if (u_ld) begin oi <= oi + 7'd1; if (oi != n_tx - 7'd1) acc <= acc ^ u_d; end
            if (u_done && oi == n_tx) begin st <= S_IDLE; tx_on <= 1'b0; oi <= '0; end
          end
        endcase
      end
    end
  end
endmodule
