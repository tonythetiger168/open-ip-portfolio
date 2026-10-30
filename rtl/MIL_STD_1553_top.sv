// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIL_STD_1553_top v1.0: MIL-STD-1553B terminal: bus controller (BC) or
// remote terminal (RT), dual-redundant buses A / B
// ----------------------------------------------------------------------------
//  - Line coding (both directions): 1 Mbit/s Manchester II, 20-bit-time
//    words: a 3-bit-time sync (command / status: + then -, data: - then +,
//    1.5 bit times each), 16 data bits MSB first ('1' = + then -), odd
//    parity. The transceiver interface is a {p, n} pair per bus and
//    direction: p = 1 the line is positive, n = 1 negative, both 0 idle.
//    cfg_half = PCLK cycles per 0.5 us (at least 4).
//  - Decoder (one per bus): a level that held for 2.5..3.5 half bits and
//    flips to the opposite level is a sync; the 34 half bits after it are
//    sampled in their middles. A Manchester error (equal halves, idle or
//    both levels), a broken sync or even parity makes a word error. Words
//    the terminal itself is sending are not decoded.
//  - RT (cfg_bc = 0): answers commands to cfg_rt_addr, and broadcasts (RT
//    31) when cfg_bcast_en. Receive commands take 1..32 data words
//    (contiguous) into mem {0, SA, word}; transmit commands send the status
//    word and the data words from mem {1, SA, word}. RT-to-RT transfers as
//    the receiver (its receive command followed by the transmit command of
//    another RT, whose status and data it checks) or as the transmitter.
//    The status word goes out 2.5 us after the last word (a 4.5 us response
//    time); a contiguous extra word cancels it. Mode codes (SA 0 or 31):
//    1 synchronize, 2 transmit status word, 3 initiate self test,
//    4 / 5 transmitter shutdown / override (of the other bus), 6 / 7 inhibit
//    / override the terminal flag, 8 reset RT, 16 transmit vector word,
//    17 synchronize with data word, 18 transmit last command, 19 transmit
//    BIT word; every other code is illegal (message error, status only).
//    Status word: address, message error, service request, broadcast
//    command received, busy, subsystem flag, terminal flag. With
//    cfg_busy the RT stores no data and sends no data words. Errors (word,
//    word count, illegal, RT-RT timeout / address) set the message error
//    bit and suppress the status word of that message, except illegal
//    commands, which are answered. A valid command to the RT on either bus
//    supersedes the message in progress. rt_msg reports every message.
//  - BC (cfg_bc = 1): one message per bc_start, of type bc_type: 0 BC-RT
//    (data from mem {1, 0, word}), 1 RT-BC (data into mem {0, 0, word}),
//    2 RT-RT (bc_cmd1 the receive, bc_cmd2 the transmit command), 3 mode
//    code without data, 4 mode code with data from the RT, 5 mode code with
//    a data word from mem {1, 0, 0}. The response must start (its sync
//    middle) within cfg_resp_timeout half bits after the last word; the
//    status word's address is checked, a status with the message error or
//    busy bit carries no data. bc_done reports the status words, the data
//    word count and the errors: no response, address, word error, word
//    count. Broadcast commands expect no status.
//  - Message buffer: 2048 x 16 words inside, address {T/R, SA, word}. The
//    host reads and writes it through host_*; a host write to the word the
//    terminal writes on the same clock is dropped (the terminal's wins).
// ============================================================================
module MIL_STD_1553_dec (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [7:0]  half,
  input  logic        rx_p,
  input  logic        rx_n,
  output logic        start,              // the middle of a sync: a word begins
  output logic        cmd,                // its sync is a command / status sync
  output logic        done,               // the word ended (ok: a good word)
  output logic        ok,
  output logic [15:0] data,
  output logic        busy
);
  logic [1:0]  s1, s2, lq;                // {p, n}: synchroniser, level before
  logic [9:0]  run;                       // clocks the level lq lasted
  logic [7:0]  hc;                        // clock in the half bit
  logic [5:0]  hi;                        // half bit: 0..2 sync, 3..36 data and parity
  logic        f, bad;
  logic [16:0] sh;
  wire         pos = s2 == 2'b10;
  wire         neg = s2 == 2'b01;
  // a sync: the level before lasted 2.5..3.5 half bits (5 / 2 and 7 / 2 halves; 2 run against 5 / 7 half)
  wire         sync = !busy && ((lq == 2'b10 && neg) || (lq == 2'b01 && pos)) &&
                      {run, 1'b0} >= 11'd5 * 11'(half) && {run, 1'b0} <= 11'd7 * 11'(half);
  wire         h_end = hc == half - 8'd1;
  wire         smp  = hc == {1'b0, half[7:1]};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1 <= '0; s2 <= '0; lq <= '0; run <= '0; hc <= '0; hi <= '0; f <= 1'b0; bad <= 1'b0; sh <= '0;
      start <= 1'b0; cmd <= 1'b0; done <= 1'b0; ok <= 1'b0; data <= '0; busy <= 1'b0;
    end else begin
      s1 <= {rx_p, rx_n}; s2 <= s1; lq <= s2;
      start <= 1'b0; done <= 1'b0;
      if (s2 != lq) run <= 10'd1;
      else if (run != '1) run <= run + 10'd1;
      if (sync) begin
        busy <= 1'b1; start <= 1'b1; cmd <= lq == 2'b10; hc <= 8'd1; hi <= '0; bad <= 1'b0;
      end else if (busy) begin
        hc <= h_end ? 8'd0 : hc + 8'd1;
        if (h_end) hi <= hi + 6'd1;
        if (smp) begin
          if (hi == 6'd1 && s2 != (cmd ? 2'b01 : 2'b10)) bad <= 1'b1;          // the sync's second half
          if (hi >= 6'd3) begin
            if (!pos && !neg) bad <= 1'b1;
            if (hi[0]) f <= pos;
            else begin
              if (pos == f) bad <= 1'b1;
              sh <= {sh[15:0], f};
            end
          end
        end
        if (h_end && hi == 6'd36) begin
          busy <= 1'b0; done <= 1'b1; ok <= !bad && ^sh; data <= sh[16:1];
          run <= '0;                                                           // the next sync starts now
        end
      end
    end
  end
endmodule

module MIL_STD_1553_enc (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [7:0]  half,
  input  logic        load,               // a word: when idle, or on the last clock of a word (contiguous)
  input  logic        abort,
  input  logic        w_cmd,
  input  logic [15:0] w_data,
  output logic        act,
  output logic        last,
  output logic        lvl                 // 1 positive, 0 negative (while act)
);
  logic [7:0]  hc;
  logic [5:0]  hi;                        // half bit 0..39
  logic        c;
  logic [16:0] w;                         // data and parity
  logic [4:0]  bi;
  assign last = act && hi == 6'd39 && hc == half - 8'd1;
  always_comb begin
    bi  = 5'd16 - 5'((hi - 6'd6) >> 1);
    lvl = hi < 6'd3 ? c : hi < 6'd6 ? !c : w[bi] ^ hi[0];
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act <= 1'b0; hc <= '0; hi <= '0; c <= 1'b0; w <= '0;
    end else if (abort) act <= 1'b0;
    else if (load && (!act || last)) begin
      act <= 1'b1; hc <= '0; hi <= '0; c <= w_cmd; w <= {w_data, ~^w_data};
    end else if (act) begin
      if (hc == half - 8'd1) begin
        hc <= '0;
        if (hi == 6'd39) act <= 1'b0; else hi <= hi + 6'd1;
      end else hc <= hc + 8'd1;
    end
  end
endmodule

module MIL_STD_1553_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [7:0]  cfg_half,           // clocks per 0.5 us, 4..255
  input  logic        cfg_bc,             // 1 bus controller, 0 remote terminal
  input  logic [7:0]  cfg_resp_timeout,   // half bits from the last word to the response's sync
  // ---- buses (transceiver side)
  output logic        tx_a_p,
  output logic        tx_a_n,
  output logic        tx_b_p,
  output logic        tx_b_n,
  input  logic        rx_a_p,
  input  logic        rx_a_n,
  input  logic        rx_b_p,
  input  logic        rx_b_n,
  // ---- host port of the message buffer (2048 x 16, address {T/R, SA, word})
  input  logic        host_rd,            // host_rdata the clock after
  input  logic        host_wr,
  input  logic [10:0] host_addr,
  input  logic [15:0] host_wdata,
  output logic [15:0] host_rdata,
  // ---- remote terminal
  input  logic [4:0]  cfg_rt_addr,
  input  logic        cfg_bcast_en,
  input  logic        cfg_sr,             // status: service request
  input  logic        cfg_busy,           // status: busy
  input  logic        cfg_ssf,            // status: subsystem flag
  input  logic        cfg_tf,             // status: terminal flag (unless inhibited)
  input  logic [15:0] cfg_vector,
  input  logic [15:0] cfg_bit_word,
  output logic        rt_msg,             // a message ended
  output logic [15:0] rt_msg_cmd,
  output logic        rt_msg_bus,         // 0 A, 1 B
  output logic        rt_msg_err,         // the message error bit was set
  output logic [2:0]  rt_msg_why,         // 0 none, 1 word, 2 word count, 3 illegal, 4 RT-RT
  output logic        rt_msg_bcast,
  output logic [5:0]  rt_msg_cnt,         // data words received / sent
  output logic        mc_sync,
  output logic        mc_selftest,
  output logic        mc_reset,
  output logic        mc_sync_data,
  output logic [15:0] mc_data,
  output logic [1:0]  rt_tx_shut,         // transmitter shut down, per bus
  output logic        rt_tf_inh,
  // ---- bus controller
  input  logic        bc_start,
  input  logic [2:0]  bc_type,
  input  logic        bc_bus,
  input  logic [15:0] bc_cmd1,
  input  logic [15:0] bc_cmd2,
  output logic        bc_busy,
  output logic        bc_done,
  output logic        bc_err_noresp,
  output logic        bc_err_addr,
  output logic        bc_err_word,
  output logic        bc_err_wc,
  output logic [15:0] bc_stat1,
  output logic [15:0] bc_stat2,
  output logic [5:0]  bc_cnt
);
  // =========================================================================
  // message buffer
  // =========================================================================
  logic        mem_rd, mem_wr;
  logic [10:0] mem_addr;
  logic [15:0] mem_wdata, mem_rdata;
  logic [15:0] ram [0:2047];
  always_ff @(posedge clk) begin
    if (mem_wr) ram[mem_addr] <= mem_wdata;
    if (host_wr && !(mem_wr && mem_addr == host_addr)) ram[host_addr] <= host_wdata;
    if (mem_rd) mem_rdata <= ram[mem_addr];
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) host_rdata <= '0;
    else if (host_rd) host_rdata <= ram[host_addr];

  // =========================================================================
  // decoders, encoder
  // =========================================================================
  logic [1:0]  d_start, d_cmd, d_done, d_ok, d_busy;
  logic [31:0] d_data;                  // {B, A}
  MIL_STD_1553_dec u_dec_a (.clk, .rst_n, .half(cfg_half), .rx_p(rx_a_p), .rx_n(rx_a_n),
    .start(d_start[0]), .cmd(d_cmd[0]), .done(d_done[0]), .ok(d_ok[0]), .data(d_data[15:0]), .busy(d_busy[0]));
  MIL_STD_1553_dec u_dec_b (.clk, .rst_n, .half(cfg_half), .rx_p(rx_b_p), .rx_n(rx_b_n),
    .start(d_start[1]), .cmd(d_cmd[1]), .done(d_done[1]), .ok(d_ok[1]), .data(d_data[31:16]), .busy(d_busy[1]));

  logic        e_load, e_abort, e_cmd, e_act, e_last, e_lvl;
  logic [15:0] e_word;
  logic        tx_bus;
  MIL_STD_1553_enc u_enc (.clk, .rst_n, .half(cfg_half), .load(e_load), .abort(e_abort), .w_cmd(e_cmd),
    .w_data(e_word), .act(e_act), .last(e_last), .lvl(e_lvl));
  assign tx_a_p = e_act && !tx_bus && e_lvl;
  assign tx_a_n = e_act && !tx_bus && !e_lvl;
  assign tx_b_p = e_act && tx_bus && e_lvl;
  assign tx_b_n = e_act && tx_bus && !e_lvl;

  // words the terminal hears from itself are dropped
  logic [1:0] own;
  logic [1:0] w_ok, w_bad, w_go;          // a good / bad word from another terminal, a word starts
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) own <= '0;
    else for (int b = 0; b < 2; b++)
      if (d_start[b]) own[b] <= e_act && tx_bus == 1'(b);
  end
  always_comb
    for (int b = 0; b < 2; b++) begin
      w_ok[b]  = d_done[b] && d_ok[b] && !own[b];
      w_bad[b] = d_done[b] && !d_ok[b] && !own[b];
      w_go[b]  = d_start[b] && !(e_act && tx_bus == 1'(b));
    end

  // n half bits in clocks (gaps: 4 = 2 us without a word, 5 = the RT's 2.5 us before its status)
  function automatic logic [15:0] hb(input logic [7:0] n, input logic [7:0] h);
    hb = 16'(n) * 16'(h);
  endfunction
  function automatic logic [5:0] wcount(input logic [4:0] wc);
    wcount = wc == 5'd0 ? 6'd32 : {1'b0, wc};
  endfunction

  // =========================================================================
  // remote terminal
  // =========================================================================
  typedef enum logic [2:0] {RS_IDLE, RS_RXD, RS_RTST, RS_GAP, RS_TX} rs_t;
  rs_t         rs;
  logic        rb;                        // bus of the message
  wire  [15:0] wr_ = rb ? d_data[31:16] : d_data[15:0];
  logic [15:0] rcmd, last_cmd;
  logic [5:0]  rwc, rn, tn;               // words expected, received, data words to send
  logic        rtrt;                      // receiving an RT-RT transfer
  logic [4:0]  rtrt_addr;
  logic        me, bcr;                   // status bits of the last message
  logic        r_mode, r_resp, r_store, r_illegal;
  logic [15:0] tm_r;
  logic [5:0]  ti;                        // words loaded into the encoder
  logic [15:0] nxt_w;
  logic        nxt_mem, rd_q;             // memory read now, read data now
  // the status word: address, message error, instrumentation 0, service request, reserved,
  // broadcast received, busy, subsystem flag, dynamic bus control 0, terminal flag
  function automatic logic [15:0] status(input logic [4:0] a, input logic m, input logic s, input logic b,
                                         input logic bz, input logic f, input logic t);
    status = {a, m, 1'b0, s, 3'b000, b, bz, f, 1'b0, t};
  endfunction
  // a command to this RT on bus b
  logic [1:0]  hit;
  always_comb
    for (int b = 0; b < 2; b++)
      hit[b] = !cfg_bc && w_ok[b] && d_cmd[b] &&
               (d_data[16 * b + 11 +: 5] == cfg_rt_addr || (d_data[16 * b + 11 +: 5] == 5'd31 && cfg_bcast_en));
  // a command arriving now, unless it is the RT-RT transmit command / status the receiver expects
  wire         rtrt_word = rs == RS_RXD && !rtrt && rn == 6'd0 && hit[rb] == 1'b0;
  wire         new_cmd = hit[0] || hit[1];
  wire         nb = hit[0] ? 1'b0 : 1'b1;
  wire  [15:0] nc = nb ? d_data[31:16] : d_data[15:0];
  wire  [4:0]  nsa = nc[9:5];
  wire  [4:0]  ncode = nc[4:0];
  wire         nbc = nc[15:11] == 5'd31;
  wire         nmode = nsa == 5'd0 || nsa == 5'd31;
  // mode code classes
  wire         m_tx_nodata = nc[10] && ncode >= 5'd1 && ncode <= 5'd8;
  wire         m_tx_data   = nc[10] && (ncode == 5'd16 || ncode == 5'd18 || ncode == 5'd19);
  wire         m_rx_data   = !nc[10] && ncode >= 5'd16;
  wire         m_bc_ok     = (m_tx_nodata && ncode != 5'd2) || (!nc[10] && ncode == 5'd17);
  wire         m_keep      = nmode && nc[10] && (ncode == 5'd2 || ncode == 5'd18);   // status and last command untouched

  // end of a message: report it
  task automatic report(input logic err, input logic [2:0] w, input logic [5:0] cnt);
    rt_msg <= 1'b1; rt_msg_cmd <= rcmd; rt_msg_bus <= rb; rt_msg_err <= err; rt_msg_why <= w;
    rt_msg_bcast <= rcmd[15:11] == 5'd31; rt_msg_cnt <= cnt;
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= RS_IDLE; rb <= 1'b0; rcmd <= '0; last_cmd <= '0; rwc <= '0; rn <= '0; rtrt <= 1'b0;
      rtrt_addr <= '0; me <= 1'b0; bcr <= 1'b0; r_mode <= 1'b0; r_resp <= 1'b0; r_store <= 1'b0;
      r_illegal <= 1'b0; tm_r <= '0; ti <= '0; nxt_w <= '0; nxt_mem <= 1'b0; rd_q <= 1'b0; tn <= '0;
      rt_msg <= 1'b0; rt_msg_cmd <= '0; rt_msg_bus <= 1'b0; rt_msg_err <= 1'b0; rt_msg_why <= '0;
      rt_msg_bcast <= 1'b0; rt_msg_cnt <= '0;
      mc_sync <= 1'b0; mc_selftest <= 1'b0; mc_reset <= 1'b0; mc_sync_data <= 1'b0; mc_data <= '0;
      rt_tx_shut <= '0; rt_tf_inh <= 1'b0;
    end else begin
      rt_msg <= 1'b0; mc_sync <= 1'b0; mc_selftest <= 1'b0; mc_reset <= 1'b0; mc_sync_data <= 1'b0;
      tm_r <= tm_r + 16'd1;
      rd_q <= nxt_mem;
      if (rd_q) nxt_w <= mem_rdata;
      nxt_mem <= 1'b0;
      if (cfg_bc) rs <= RS_IDLE;
      else if (new_cmd) begin
        // ---- a command: start a message (superseding the one in progress)
        rb <= nb; rcmd <= nc; rn <= '0; tn <= '0; rtrt <= 1'b0; tm_r <= '0;
        if (!m_keep) begin last_cmd <= nc; me <= 1'b0; bcr <= nbc; end
        r_mode <= nmode; r_resp <= !nbc; r_store <= !cfg_busy; r_illegal <= 1'b0;
        if (!nmode) begin
          rwc <= wcount(nc[4:0]);
          if (!nc[10]) rs <= RS_RXD;                                       // receive data
          else if (nbc) begin                                              // broadcast transmit: illegal
            me <= 1'b1; rs <= RS_IDLE; rt_msg <= 1'b1; rt_msg_cmd <= nc; rt_msg_bus <= nb; rt_msg_err <= 1'b1;
            rt_msg_why <= 3'd3; rt_msg_bcast <= 1'b1; rt_msg_cnt <= '0;
          end else begin rs <= RS_GAP; tn <= cfg_busy ? 6'd0 : wcount(nc[4:0]); end
        end else begin
          // mode codes
          if ((nbc && !m_bc_ok) || !(m_tx_nodata || m_tx_data || (m_rx_data && ncode == 5'd17))) begin
            me <= 1'b1; r_illegal <= 1'b1;
          end
          if (m_rx_data) begin rwc <= 6'd1; rs <= RS_RXD; r_store <= 1'b0; end
          else begin
            rs <= RS_GAP; rwc <= '0;
            tn <= (m_tx_data && !nbc) ? 6'd1 : 6'd0;
            nxt_w <= ncode == 5'd16 ? cfg_vector : ncode == 5'd18 ? last_cmd : cfg_bit_word;
            if (!(nbc && !m_bc_ok) && m_tx_nodata) begin
              if (ncode == 5'd1) mc_sync <= 1'b1;
              if (ncode == 5'd3) mc_selftest <= 1'b1;
              if (ncode == 5'd4) rt_tx_shut[!nb] <= 1'b1;
              if (ncode == 5'd5) rt_tx_shut[!nb] <= 1'b0;
              if (ncode == 5'd6) rt_tf_inh <= 1'b1;
              if (ncode == 5'd7) rt_tf_inh <= 1'b0;
            end
            if (nbc && !m_bc_ok) begin                                     // illegal broadcast: no status
              rs <= RS_IDLE; rt_msg <= 1'b1; rt_msg_cmd <= nc; rt_msg_bus <= nb; rt_msg_err <= 1'b1;
              rt_msg_why <= 3'd3; rt_msg_bcast <= 1'b1; rt_msg_cnt <= '0;
            end else if (nbc) begin                                        // broadcast mode code: done
              rs <= RS_IDLE; rt_msg <= 1'b1; rt_msg_cmd <= nc; rt_msg_bus <= nb; rt_msg_err <= 1'b0;
              rt_msg_why <= '0; rt_msg_bcast <= 1'b1; rt_msg_cnt <= '0;
              if (ncode == 5'd8) begin mc_reset <= 1'b1; rt_tx_shut <= '0; rt_tf_inh <= 1'b0; end
            end
          end
        end
      end else begin
        case (rs)
          RS_RXD: begin
            if (w_bad[rb]) begin
              me <= 1'b1; rs <= RS_IDLE; report(1'b1, 3'd1, rn);
            end else if (w_ok[rb] && d_cmd[rb]) begin
              if (rtrt_word && wr_[10] && wr_[15:11] != 5'd31) begin
                rtrt <= 1'b1; rtrt_addr <= wr_[15:11]; rs <= RS_RTST; tm_r <= '0;   // RT-RT, the transmitter's status next
              end else begin
                me <= 1'b1; rs <= RS_IDLE; report(1'b1, 3'd2, rn);
              end
            end else if (w_ok[rb]) begin
              rn <= rn + 6'd1; tm_r <= '0;
              if (r_mode) begin mc_sync_data <= !r_illegal; mc_data <= wr_; end
              if (rn + 6'd1 == rwc) rs <= RS_GAP;
            end else if (!d_busy[rb] && tm_r >= hb(8'd4, cfg_half)) begin
              me <= 1'b1; rs <= RS_IDLE; report(1'b1, 3'd2, rn);             // too few words
            end
          end
          RS_RTST: begin
            if (w_ok[rb] && d_cmd[rb] && wr_[15:11] == rtrt_addr) begin
              rs <= RS_RXD; tm_r <= '0;
            end else if (w_ok[rb] || w_bad[rb] || (!d_busy[rb] && tm_r >= hb(cfg_resp_timeout, cfg_half))) begin
              me <= 1'b1; rs <= RS_IDLE; report(1'b1, 3'd4, 6'd0);
            end
          end
          RS_GAP: begin
            if (w_go[rb]) begin                                              // a word follows: word count error
              me <= 1'b1; rs <= RS_IDLE; report(1'b1, 3'd2, rn);
            end else if (tm_r >= hb(8'd5, cfg_half)) begin
              if (!r_resp) begin
                rs <= RS_IDLE; report(r_illegal, r_illegal ? 3'd3 : 3'd0, rn);
              end else if (rt_tx_shut[rb]) begin
                rs <= RS_IDLE; report(r_illegal, r_illegal ? 3'd3 : 3'd0, rcmd[10] ? 6'd0 : rn);
              end else begin
                rs <= RS_TX; ti <= '0;
                if (!r_mode && tn != 6'd0) nxt_mem <= 1'b1;                   // first data word
              end
            end
          end
          RS_TX: begin
            if (e_load && ti != 6'd0 && !r_mode && ti < tn) nxt_mem <= 1'b1;
            if (e_load) ti <= ti + 6'd1;
            if (!e_act && ti != 6'd0 && !e_load) begin
              rs <= RS_IDLE; report(r_illegal, r_illegal ? 3'd3 : 3'd0, rcmd[10] ? tn : rn);
              if (r_mode && rcmd[4:0] == 5'd8 && !r_illegal) begin mc_reset <= 1'b1; rt_tx_shut <= '0; rt_tf_inh <= 1'b0; end
            end
          end
          default: ;
        endcase
      end
    end
  end

  // =========================================================================
  // bus controller
  // =========================================================================
  typedef enum logic [2:0] {BS_IDLE, BS_TX, BS_WAIT, BS_RXD, BS_CHK} bs_t;
  bs_t         bs;
  logic [2:0]  b_type;
  logic [15:0] b_c1, b_c2;
  logic [5:0]  b_nw, b_ti, b_n;           // words to send, sent, data words expected
  logic        b_ph2;                     // RT-RT: the receiver's status next
  logic [15:0] tm_b;
  logic [15:0] b_nxt;
  logic        b_mem, b_mq;
  logic        bc_bus_q;
  wire  [15:0] wb_ = bc_bus_q ? d_data[31:16] : d_data[15:0];
  wire         b_bc1 = b_c1[15:11] == 5'd31;
  wire  [4:0]  b_exp = (b_type == 3'd2 && !b_ph2) ? b_c2[15:11] : b_c1[15:11];
  wire         b_last_tx = b_ti == b_nw;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bs <= BS_IDLE; b_type <= '0; b_c1 <= '0; b_c2 <= '0; b_nw <= '0; b_ti <= '0; b_n <= '0; b_ph2 <= 1'b0;
      tm_b <= '0; b_nxt <= '0; b_mem <= 1'b0; b_mq <= 1'b0;
      bc_busy <= 1'b0; bc_done <= 1'b0; bc_err_noresp <= 1'b0; bc_err_addr <= 1'b0; bc_err_word <= 1'b0;
      bc_err_wc <= 1'b0; bc_stat1 <= '0; bc_stat2 <= '0; bc_cnt <= '0;
    end else begin
      bc_done <= 1'b0;
      tm_b <= tm_b + 16'd1;
      b_mq <= b_mem;
      if (b_mq) b_nxt <= mem_rdata;
      b_mem <= 1'b0;
      case (bs)
        BS_IDLE:
          if (bc_start && cfg_bc) begin
            bs <= BS_TX; bc_busy <= 1'b1; b_type <= bc_type; b_c1 <= bc_cmd1; b_c2 <= bc_cmd2; b_ti <= '0;
            b_ph2 <= 1'b0; bc_cnt <= '0; bc_stat1 <= '0; bc_stat2 <= '0;
            bc_err_noresp <= 1'b0; bc_err_addr <= 1'b0; bc_err_word <= 1'b0; bc_err_wc <= 1'b0;
            b_nw <= bc_type == 3'd0 ? 6'd1 + wcount(bc_cmd1[4:0]) : bc_type == 3'd2 || bc_type == 3'd5 ? 6'd2 : 6'd1;
            b_mem <= bc_type == 3'd0 || bc_type == 3'd5;                    // first data word
            b_nxt <= bc_cmd2;
          end
        BS_TX: begin
          if (e_load && b_ti != 6'd0 && b_type == 3'd0 && b_ti + 6'd1 < b_nw) b_mem <= 1'b1;
          if (e_load) b_ti <= b_ti + 6'd1;
          if (!e_act && b_last_tx && !e_load) begin
            tm_b <= '0;
            if (b_bc1 && b_type != 3'd2) begin bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1; end
            else bs <= BS_WAIT;
          end
        end
        BS_WAIT: begin
          if (w_ok[bc_bus_q] && d_cmd[bc_bus_q]) begin
            if (b_ph2) bc_stat2 <= wb_; else bc_stat1 <= wb_;
            if (wb_[15:11] != b_exp) begin
              bc_err_addr <= 1'b1; bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1;
            end else begin
              tm_b <= '0;
              b_n <= (b_ph2 || b_type == 3'd0 || b_type == 3'd3 || b_type == 3'd5 ||
                      wb_[10] || wb_[3]) ? 6'd0 :
                     b_type == 3'd1 ? wcount(b_c1[4:0]) : b_type == 3'd2 ? wcount(b_c2[4:0]) : 6'd1;
              if (b_ph2 || b_type == 3'd0 || b_type == 3'd3 || b_type == 3'd5 || wb_[10] || wb_[3])
                bs <= BS_CHK;
              else bs <= BS_RXD;
              if (b_type == 3'd2 && !b_ph2) b_ph2 <= 1'b1;
            end
          end else if (w_bad[bc_bus_q] || w_ok[bc_bus_q]) begin
            bc_err_word <= 1'b1; bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1;
          end else if (!d_busy[bc_bus_q] && tm_b >= hb(cfg_resp_timeout, cfg_half)) begin
            bc_err_noresp <= 1'b1; bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1;
          end
        end
        BS_RXD: begin
          if (w_bad[bc_bus_q] || (w_ok[bc_bus_q] && d_cmd[bc_bus_q])) begin
            if (w_bad[bc_bus_q]) bc_err_word <= 1'b1; else bc_err_wc <= 1'b1;
            bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1;
          end else if (w_ok[bc_bus_q]) begin
            bc_cnt <= bc_cnt + 6'd1; tm_b <= '0;
            if (bc_cnt + 6'd1 == b_n) bs <= (b_type == 3'd2 && !b_bc1) ? BS_WAIT : BS_CHK;
          end else if (!d_busy[bc_bus_q] && tm_b >= hb(8'd4, cfg_half)) begin
            bc_err_wc <= 1'b1; bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1;
          end
        end
        BS_CHK: begin
          if (w_go[bc_bus_q]) bc_err_wc <= 1'b1;                              // an extra word
          if (w_go[bc_bus_q] || tm_b >= hb(8'd4, cfg_half)) begin bs <= BS_IDLE; bc_busy <= 1'b0; bc_done <= 1'b1; end
        end
      endcase
      if (!cfg_bc) begin bs <= BS_IDLE; bc_busy <= 1'b0; end
    end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) bc_bus_q <= 1'b0;
    else if (bs == BS_IDLE && bc_start) bc_bus_q <= bc_bus;

  // =========================================================================
  // encoder and memory port
  // =========================================================================
  always_comb begin
    e_load = 1'b0; e_cmd = 1'b1; e_word = '0; e_abort = 1'b0;
    if (cfg_bc) begin
      tx_bus = bc_bus_q;
      e_load = bs == BS_TX && b_ti != b_nw && (!e_act || e_last);
      e_cmd  = b_ti == 6'd0 || (b_ti == 6'd1 && b_type == 3'd2);
      e_word = b_ti == 6'd0 ? b_c1 : b_nxt;
    end else begin
      tx_bus = rb;
      e_load = rs == RS_TX && ti <= tn && (!e_act || e_last);
      e_cmd  = ti == 6'd0;
      e_word = ti == 6'd0 ? status(cfg_rt_addr, me, cfg_sr, bcr, cfg_busy, cfg_ssf, cfg_tf && !rt_tf_inh) : nxt_w;
      e_abort = rs == RS_TX && new_cmd;
    end
    mem_rd = 1'b0; mem_wr = 1'b0; mem_addr = '0; mem_wdata = '0;
    if (cfg_bc) begin
      if (b_mem) begin mem_rd = 1'b1; mem_addr = {1'b1, 5'd0, 5'(b_ti == 6'd0 ? 6'd0 : b_ti - 6'd1)}; end
      else if (bs == BS_RXD && w_ok[bc_bus_q] && !d_cmd[bc_bus_q]) begin
        mem_wr = 1'b1; mem_addr = {1'b0, 5'd0, bc_cnt[4:0]}; mem_wdata = wb_;
      end
    end else begin
      if (nxt_mem) begin mem_rd = 1'b1; mem_addr = {1'b1, rcmd[9:5], 5'(ti == 6'd0 ? 6'd0 : ti - 6'd1)}; end
      else if (rs == RS_RXD && w_ok[rb] && !d_cmd[rb] && r_store && !new_cmd) begin
        mem_wr = 1'b1; mem_addr = {1'b0, rcmd[9:5], rn[4:0]}; mem_wdata = wr_;
      end
    end
  end
endmodule
