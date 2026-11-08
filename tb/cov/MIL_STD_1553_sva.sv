// SPDX-License-Identifier: Apache-2.0
// MIL-STD-1553B terminal: concurrent SVA against an independent word-level
// model of both buses, plus functional coverage.
//  * Word decoder model (one per bus): works on the times of the level
//    changes, not on samples: a change after a level that lasted 2.5..3.5
//    half bits is a sync, each data bit is the direction of the change in its
//    middle (within a quarter half bit of where it is due), a change to idle /
//    both levels breaks the word, and the parity is checked over the 17 bits.
//    A word is the terminal's own when its transmitter drives that bus.
//  * RT model: the last command to the RT per bus and the words that follow
//    it. Every word the RT sends is checked (the status word: sync, address,
//    reserved bits, SR / busy / SSF bits, a 4.5 us response time; data words:
//    the memory words read for it, the vector or BIT word), every memory
//    write (the word just received, at {0, SA, index}), and every rt_msg
//    report (the command, the number of words the RT sent: none after an
//    error or a broadcast, the status only for an illegal command, and the
//    word count).
//  * BC model: from bc_start the words the BC sends (command words, data
//    from memory reads in order), and at bc_done its words, the status
//    word against the first word that came back, no response only when no
//    word came back, the data word count.
`include "cov_macros.svh"
module MIL_STD_1553_sva_dec (
  input  logic        clk, rst_n,
  input  logic [7:0]  half,
  input  logic        p, n,
  output bit          ws,                 // a word starts (the middle of its sync)
  output bit          wv,                 // a word ended
  output bit          wcmd, wok,
  output logic [15:0] wd,
  output longint      wstart, wend
);
  longint      now, tlc, t0;
  logic [1:0]  lp;
  bit          inw, bad, c;
  bit [16:0]   bits, got;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      now = 0; tlc = 0; t0 = 0; lp = 2'b00; inw = 0; bad = 0; c = 0; bits = '0; got = '0;
      ws <= 0; wv <= 0; wcmd <= 0; wok <= 0; wd <= '0; wstart <= 0; wend <= 0;
    end else begin
      logic [1:0] l;
      longint h, d, r;
      now++; h = half; l = {p, n};
      ws <= 0; wv <= 0;
      if (inw && now - t0 == 37 * h) begin                       // the word ends here
        inw = 0; tlc = now;
        wv <= 1; wcmd <= c; wd <= bits[16:1]; wok <= !bad && &got && ^bits; wend <= now;
      end
      if (l != lp) begin
        d = now - tlc;
        if (!inw) begin
          if (((lp == 2'b10 && l == 2'b01) || (lp == 2'b01 && l == 2'b10)) && 2 * d >= 5 * h && 2 * d <= 7 * h) begin
            inw = 1; t0 = now; c = lp == 2'b10; bad = 0; got = '0; bits = '0;
            ws <= 1; wstart <= now;
          end
        end else begin
          r = now - t0;
          if (l == 2'b00 || l == 2'b11) bad = 1;
          else
            for (int i = 0; i < 17; i++) begin
              longint e;
              e = (2 * i + 4) * h;                                   // the middle of bit i
              if (4 * (r > e ? r - e : e - r) <= h) begin bits[16 - i] = l == 2'b01; got[i] = 1; end
            end
        end
        tlc = now; lp = l;
      end
    end
  end
endmodule

module MIL_STD_1553_sva (
  input  logic        clk, rst_n,
  input  logic [7:0]  cfg_half,
  input  logic        cfg_bc,
  input  logic [7:0]  cfg_resp_timeout,
  input  logic        tx_a_p, tx_a_n, tx_b_p, tx_b_n,
  input  logic        rx_a_p, rx_a_n, rx_b_p, rx_b_n,
  input  logic        mem_rd, mem_wr,
  input  logic [10:0] mem_addr,
  input  logic [15:0] mem_wdata, mem_rdata,
  input  logic [4:0]  cfg_rt_addr,
  input  logic        cfg_bcast_en, cfg_sr, cfg_busy, cfg_ssf, cfg_tf,
  input  logic [15:0] cfg_vector, cfg_bit_word,
  input  logic        rt_msg,
  input  logic [15:0] rt_msg_cmd,
  input  logic        rt_msg_bus, rt_msg_err,
  input  logic [2:0]  rt_msg_why,
  input  logic        rt_msg_bcast,
  input  logic [5:0]  rt_msg_cnt,
  input  logic        mc_sync, mc_selftest, mc_reset, mc_sync_data,
  input  logic [15:0] mc_data,
  input  logic [1:0]  rt_tx_shut,
  input  logic        rt_tf_inh,
  input  logic        bc_start,
  input  logic [2:0]  bc_type,
  input  logic        bc_bus,
  input  logic [15:0] bc_cmd1, bc_cmd2,
  input  logic        bc_busy, bc_done, bc_err_noresp, bc_err_addr, bc_err_word, bc_err_wc,
  input  logic [15:0] bc_stat1, bc_stat2,
  input  logic [5:0]  bc_cnt
);
  `COV_CLOCKING(clk, !rst_n)

  // ---- word decoders on both buses
  bit          ws [0:1], wv [0:1], wcmd [0:1], wok [0:1];
  logic [15:0] wd [0:1];
  longint      wst [0:1], wen [0:1];
  MIL_STD_1553_sva_dec u_da (.clk, .rst_n, .half(cfg_half), .p(rx_a_p), .n(rx_a_n), .ws(ws[0]), .wv(wv[0]),
    .wcmd(wcmd[0]), .wok(wok[0]), .wd(wd[0]), .wstart(wst[0]), .wend(wen[0]));
  MIL_STD_1553_sva_dec u_db (.clk, .rst_n, .half(cfg_half), .p(rx_b_p), .n(rx_b_n), .ws(ws[1]), .wv(wv[1]),
    .wcmd(wcmd[1]), .wok(wok[1]), .wd(wd[1]), .wstart(wst[1]), .wend(wen[1]));
  wire  [1:0]  drv = {tx_b_p | tx_b_n, tx_a_p | tx_a_n};

  function automatic int nw(input logic [4:0] wc);
    return wc == 0 ? 32 : wc;
  endfunction
  function automatic bit is_mode(input logic [15:0] c);
    return c[9:5] == 5'd0 || c[9:5] == 5'd31;
  endfunction

  longint      now;
  bit          own [0:1];                 // the word in progress on the bus is the terminal's
  longint      prev_end [0:1];            // end of the last word from another terminal
  // RT model
  bit          have [0:1], rtrt [0:1];
  longint      mcmd_t [0:1];
  logic [15:0] mcmd [0:1];
  int          n_dw [0:1], n_dut [0:1], n_rd;
  logic [15:0] last_dw;
  bit          last_dw_bus;
  logic [15:0] rq [$];                    // memory words read for the RT / BC to send
  bit          rd_q;
  int          chk_cnt;                   // a report to check, clocks to wait
  logic [15:0] chk_cmd;
  bit          chk_bus, chk_err, chk_bc;
  logic [2:0]  chk_why;
  logic [5:0]  chk_n;
  // BC model
  bit          bc_on, bc_bus_m;
  logic [2:0]  bc_ty;
  logic [15:0] bc_c1, bc_c2;
  int          bc_k, bc_oth, bc_odata;
  logic [15:0] bc_first;
  bit          bc_first_ok;
  // error flags (one clock) and coverage flags
  bit          e_tx_both, e_stat, e_resp, e_data, e_wr, e_msg_cmd, e_msg_words, e_msg_cnt, e_bc_word, e_bc_done,
               e_two_bus;
  bit          f_rx_good, f_tx_good, f_rtrt_rx, f_rtrt_tx, f_bc_rx, f_err_word, f_err_wc, f_err_ill, f_err_rtrt,
               f_mode [0:31], f_busy, f_shut, f_super, f_bc_ty [0:5], f_bc_noresp, f_bc_addr, f_bc_word, f_bc_wc,
               f_bc_bcast, f_bus_b_rt, f_bus_b_bc, f_wc32, f_wc1, f_abort;
  int          c_resp, c_bc_ty, c_bc_bus;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      now = 0; n_rd = 0; rq.delete(); rd_q = 0; chk_cnt = 0; bc_on = 0; bc_k = 0; bc_oth = 0; bc_odata = 0;
      for (int b = 0; b < 2; b++) begin
        own[b] = 0; prev_end[b] = 0; have[b] = 0; rtrt[b] = 0; mcmd[b] = '0; mcmd_t[b] = 0; n_dw[b] = 0; n_dut[b] = 0;
      end
      last_dw = '0; last_dw_bus = 0; c_resp = -1;
    end else begin
      {e_tx_both, e_stat, e_resp, e_data, e_wr, e_msg_cmd, e_msg_words, e_msg_cnt, e_bc_word, e_bc_done, e_two_bus} = '0;
      {f_rx_good, f_tx_good, f_rtrt_rx, f_rtrt_tx, f_bc_rx, f_err_word, f_err_wc, f_err_ill, f_err_rtrt, f_busy, f_shut,
       f_super, f_bc_noresp, f_bc_addr, f_bc_word, f_bc_wc, f_bc_bcast, f_bus_b_rt, f_bus_b_bc, f_wc32, f_wc1, f_abort} = '0;
      foreach (f_mode[i]) f_mode[i] = 0;
      foreach (f_bc_ty[i]) f_bc_ty[i] = 0;
      c_resp = -1; c_bc_ty = -1;
      now++;
      e_tx_both = (tx_a_p && tx_a_n) || (tx_b_p && tx_b_n);
      e_two_bus = drv == 2'b11;
      // memory reads: the word comes the clock after
      if (rd_q) rq.push_back(mem_rdata);
      rd_q = mem_rd;
      // ---- words
      for (int b = 0; b < 2; b++) begin
        if (ws[b]) own[b] = drv[b];
        if (wv[b]) begin
          if (!own[b]) begin
            // from another terminal
            if (!cfg_bc && wok[b] && wcmd[b] && (wd[b][15:11] == cfg_rt_addr || (wd[b][15:11] == 5'd31 && cfg_bcast_en))) begin
              if (have[0] || have[1]) f_super = n_dw[b] != 0 && mcmd[b][10] == 1'b0;
              have[b] = 1; mcmd[b] = wd[b]; mcmd_t[b] = now; n_dw[b] = 0; n_dut[b] = 0; n_rd = 0; rq.delete(); rtrt[b] = 0;
            end else if (!cfg_bc && wok[b] && wcmd[b] && have[b] && !mcmd[b][10] && n_dw[b] == 0 && wd[b][10]) begin
              rtrt[b] = 1;                                                // the transmit command of an RT-RT transfer
            end else if (!cfg_bc && wok[b] && !wcmd[b]) begin
              n_dw[b]++; last_dw = wd[b]; last_dw_bus = b;
            end
            if (bc_on && b == bc_bus_m && bc_k != 0) begin
              if (bc_oth == 0) begin bc_first = wd[b]; bc_first_ok = wok[b] && wcmd[b]; end
              else if (wok[b] && !wcmd[b]) bc_odata++;
              bc_oth++;
            end
            prev_end[b] = wen[b];
          end else if (cfg_bc) begin
            // the BC's own words
            if (bc_on && b == bc_bus_m) begin
              logic [15:0] ex;
              bit          ec;
              ec = bc_k == 0 || (bc_k == 1 && bc_ty == 3'd2);
              ex = bc_k == 0 ? bc_c1 : ec ? bc_c2 : (rq.size() ? rq.pop_front() : 16'hxxxx);
              if (!wok[b] || wcmd[b] != ec || wd[b] !== ex) begin
                e_bc_word = 1; $display("MODEL %m: BC word %0d: %h ok %b cmd %b, expected %h cmd %b", bc_k, wd[b], wok[b], wcmd[b], ex, ec);
              end
              bc_k++;
            end else e_bc_word = 1;
          end else begin
            // the RT's own words
            n_dut[b]++;
            if (n_dut[b] == 1) begin
              longint rt;
              rt = wst[b] - (prev_end[b] - cfg_half);                // middle of the last parity bit to the middle of the sync
              c_resp = int'(rt);
              if (!wok[b] || !wcmd[b] || wd[b][15:11] != cfg_rt_addr || wd[b][9] || wd[b][7:5] != 0 || wd[b][1] ||
                  wd[b][8] != cfg_sr || wd[b][3] != cfg_busy || wd[b][2] != cfg_ssf) e_stat = 1;
              if (rt < 8 * cfg_half || rt > 24 * cfg_half) e_resp = 1;
            end else begin
              logic [15:0] ex;
              ex = !is_mode(mcmd[b]) ? (rq.size() ? rq.pop_front() : 16'hxxxx) :
                   mcmd[b][4:0] == 5'd16 ? cfg_vector : mcmd[b][4:0] == 5'd19 ? cfg_bit_word : wd[b];
              if (!wok[b] && have[1 - b] && mcmd_t[1 - b] > wst[b]) f_abort = 1;          // cut short by a command on the other bus
              else if (!wok[b] || wcmd[b] || wd[b] !== ex) begin
                e_data = 1; $display("MODEL %m: RT data word %h ok %b cmd %b, expected %h (command %h)", wd[b], wok[b], wcmd[b], ex, mcmd[b]);
              end
            end
          end
        end
      end
      // ---- RT memory port
      if (!cfg_bc && mem_wr)
        if (mem_addr !== {1'b0, mcmd[last_dw_bus][9:5], 5'(n_dw[last_dw_bus] - 1)} || mem_wdata !== last_dw) begin
          e_wr = 1; $display("MODEL %m: write %h %h, expected %h %h", mem_addr, mem_wdata, {1'b0, mcmd[last_dw_bus][9:5], 5'(n_dw[last_dw_bus] - 1)}, last_dw);
        end
      // ---- RT report: checked a few clocks later (the last word's end may land on the same clock)
      if (chk_cnt > 1) chk_cnt--;
      if (rt_msg) begin
        chk_cnt = 4; chk_cmd = rt_msg_cmd; chk_bus = rt_msg_bus; chk_err = rt_msg_err; chk_why = rt_msg_why;
        chk_bc = rt_msg_bcast; chk_n = rt_msg_cnt;
        if (!have[rt_msg_bus] || mcmd[rt_msg_bus] !== rt_msg_cmd || rt_msg_bcast != (rt_msg_cmd[15:11] == 5'd31) ||
            rt_msg_err != (rt_msg_why != 0)) e_msg_cmd = 1;
      end else if (chk_cnt == 1) begin
        int ex;
        bit md, tx_data;
        chk_cnt = 0;
        md = is_mode(chk_cmd);
        tx_data = chk_cmd[10] && (md ? (chk_cmd[4:0] == 5'd16 || chk_cmd[4:0] == 5'd18 || chk_cmd[4:0] == 5'd19) : 1'b1);
        ex = chk_bc || (chk_err && chk_why != 3) || rt_tx_shut[chk_bus] ? 0 :
             chk_why == 3 ? 1 : tx_data ? 1 + chk_n : 1;
        if (n_dut[chk_bus] != ex) begin
          e_msg_words = 1; $display("MODEL %m: RT sent %0d words for %h (why %0d), expected %0d", n_dut[chk_bus], chk_cmd, chk_why, ex);
        end
        if (!chk_err && !md && chk_n != (chk_cmd[10] ? (cfg_busy || rt_tx_shut[chk_bus] ? 0 : nw(chk_cmd[4:0])) : nw(chk_cmd[4:0]))) e_msg_cnt = 1;
        if (!chk_err && !md && !chk_cmd[10] && n_dw[chk_bus] < chk_n) e_msg_cnt = 1;
        if (e_msg_cnt) $display("MODEL %m: RT count %0d for %h, %0d data words seen", chk_n, chk_cmd, n_dw[chk_bus]);
        // coverage
        f_rx_good = !chk_err && !md && !chk_cmd[10]; f_tx_good = !chk_err && !md && chk_cmd[10] && !chk_bc;
        f_err_word = chk_why == 1; f_err_wc = chk_why == 2; f_err_ill = chk_why == 3; f_err_rtrt = chk_why == 4;
        if (md && !chk_err) f_mode[chk_cmd[4:0]] = 1;
        f_busy = cfg_busy && !md; f_shut = rt_tx_shut[chk_bus] && !chk_bc; f_bus_b_rt = chk_bus;
        f_wc32 = !md && chk_n == 6'd32; f_wc1 = !md && chk_n == 6'd1;
        f_rtrt_rx = !chk_err && !md && !chk_cmd[10] && rtrt[chk_bus];
      end
      // ---- BC
      if (cfg_bc && bc_start && !bc_busy) begin
        bc_on = 1; bc_bus_m = bc_bus; bc_ty = bc_type; bc_c1 = bc_cmd1; bc_c2 = bc_cmd2; bc_k = 0; bc_oth = 0; bc_odata = 0;
        bc_first_ok = 0; rq.delete();
      end
      if (cfg_bc && bc_done) begin
        int ex;
        ex = bc_ty == 3'd0 ? 1 + nw(bc_c1[4:0]) : bc_ty == 3'd2 || bc_ty == 3'd5 ? 2 : 1;
        if (bc_k != ex) e_bc_done = 1;
        if (bc_err_noresp && bc_oth != (bc_ty == 3'd2 && bc_oth != 0 ? 1 + bc_cnt : 0)) e_bc_done = 1;   // RT-RT: the receiver's status missing
        if (!bc_err_noresp && !bc_err_word && bc_c1[15:11] != 5'd31 && bc_oth != 0 && bc_stat1 !== bc_first) e_bc_done = 1;
        if (!bc_err_noresp && !bc_err_word && bc_c1[15:11] != 5'd31 && bc_oth != 0 && !bc_first_ok) e_bc_done = 1;
        if (bc_err_addr && bc_stat1[15:11] == (bc_ty == 3'd2 ? bc_c2[15:11] : bc_c1[15:11])) e_bc_done = 1;
        if (bc_cnt > bc_odata) e_bc_done = 1;
        if (e_bc_done) $display("MODEL %m: BC done: %0d words sent, %0d back (first %h ok %b, %0d data), errors %b%b%b%b stat1 %h cnt %0d",
                                bc_k, bc_oth, bc_first, bc_first_ok, bc_odata, bc_err_noresp, bc_err_addr, bc_err_word, bc_err_wc, bc_stat1, bc_cnt);
        f_bc_ty[bc_ty < 6 ? bc_ty : 0] = !bc_err_noresp && !bc_err_addr && !bc_err_word && !bc_err_wc;
        if (f_bc_ty[bc_ty < 6 ? bc_ty : 0]) begin c_bc_ty = bc_ty; c_bc_bus = bc_bus_m; end
        f_bc_noresp = bc_err_noresp; f_bc_addr = bc_err_addr; f_bc_word = bc_err_word; f_bc_wc = bc_err_wc;
        f_bc_bcast = bc_c1[15:11] == 5'd31; f_bus_b_bc = bc_bus_m; f_bc_rx = bc_cnt != 0;
        f_rtrt_tx = bc_ty == 3'd2 && bc_stat2 != 0;
        bc_on = 0;
      end
    end
  end

  `SVA_INV(a_tx_not_both_levels, !e_tx_both)
  `SVA_INV(a_tx_one_bus, !e_two_bus)
  `SVA_INV(a_rt_status_word, !e_stat)
  `SVA_INV(a_rt_response_time, !e_resp)
  `SVA_INV(a_rt_data_words, !e_data)
  `SVA_INV(a_rt_memory_write, !e_wr)
  `SVA_INV(a_rt_report_command, !e_msg_cmd)
  `SVA_INV(a_rt_report_words_sent, !e_msg_words)
  `SVA_INV(a_rt_report_count, !e_msg_cnt)
  `SVA_INV(a_bc_words_sent, !e_bc_word)
  `SVA_INV(a_bc_result, !e_bc_done)
  `SVA_IMP(a_bc_done_pulse, bc_done, !bc_busy)
  `SVA_IMP(a_bc_errors_exclusive, bc_done, $countones({bc_err_noresp, bc_err_addr, bc_err_word, bc_err_wc}) <= 1)
  `SVA_IMP(a_rt_quiet_in_bc_mode, cfg_bc, !rt_msg)
  `SVA_IMP(a_bc_quiet_in_rt_mode, !cfg_bc, !bc_busy && !bc_done)
  `SVA_IMP(a_rt_why_range, rt_msg, rt_msg_why <= 3'd4)

  `FC(rt_receive, f_rx_good)
  `FC(rt_transmit, f_tx_good)
  `FC(rt_rt_to_rt_receiver, f_rtrt_rx)
  `FC(rt_word_error, f_err_word)
  `FC(rt_word_count_error, f_err_wc)
  `FC(rt_illegal_command, f_err_ill)
  `FC(rt_rt_to_rt_error, f_err_rtrt)
  `FC(rt_busy, f_busy)
  `FC(rt_shut_down_bus, f_shut)
  `FC(rt_superseded, f_super)
  `FC(rt_transmission_cut_short, f_abort)
  `FC(rt_on_bus_b, f_bus_b_rt)
  `FC(rt_32_words, f_wc32)
  `FC(rt_1_word, f_wc1)
  `FC(mode_synchronize, f_mode[1])
  `FC(mode_transmit_status, f_mode[2])
  `FC(mode_self_test, f_mode[3])
  `FC(mode_transmitter_shutdown, f_mode[4])
  `FC(mode_override_shutdown, f_mode[5])
  `FC(mode_inhibit_tf, f_mode[6])
  `FC(mode_override_inhibit_tf, f_mode[7])
  `FC(mode_reset, f_mode[8])
  `FC(mode_vector, f_mode[16])
  `FC(mode_sync_with_data, f_mode[17])
  `FC(mode_last_command, f_mode[18])
  `FC(mode_bit_word, f_mode[19])
  `FC(bc_bc_to_rt, f_bc_ty[0])
  `FC(bc_rt_to_bc, f_bc_ty[1])
  `FC(bc_rt_to_rt, f_bc_ty[2] && f_rtrt_tx)
  `FC(bc_mode_no_data, f_bc_ty[3])
  `FC(bc_mode_tx_data, f_bc_ty[4])
  `FC(bc_mode_rx_data, f_bc_ty[5])
  `FC(bc_no_response, f_bc_noresp)
  `FC(bc_address_error, f_bc_addr)
  `FC(bc_word_error, f_bc_word)
  `FC(bc_word_count_error, f_bc_wc)
  `FC(bc_broadcast, f_bc_bcast)
  `FC(bc_on_bus_b, f_bus_b_bc)
  `FC(bc_received_data, f_bc_rx)

  covergroup cg_1553 @(negedge clk);
    option.per_instance = 1;
    cp_bc_ty: coverpoint c_bc_ty iff (c_bc_ty >= 0) { bins bc_rt = {0}; bins rt_bc = {1}; bins rt_rt = {2}; bins mode = {3};
                                                       bins mode_tx = {4}; bins mode_rx = {5}; }
    cp_bc_bus: coverpoint c_bc_bus iff (c_bc_ty >= 0) { bins a = {0}; bins b = {1}; }
    x_bc: cross cp_bc_ty, cp_bc_bus;
  endgroup
  cg_1553 u_cg_1553 = new;
endmodule

bind MIL_STD_1553_top MIL_STD_1553_sva u_sva (.*);
