// SPDX-License-Identifier: Apache-2.0
// ONFI NAND host controller: concurrent SVA against an independent
// reference model, plus functional coverage.
//  * When a command is taken the model lists its steps (command and
//    address bytes, waits, ready waits, data in, data out, status read)
//    from its own table, then plays them: one clock to start each step,
//    write and read cycles of 2 * TP clocks, waits of their parameter
//    length, a ready wait on the twice-synchronized R/B#, data steps that
//    wait for the streams.
//  * Every pin (CE#, CLE, ALE, WE#, RE#, DQ and its enable), cmd_ready,
//    wr_ready, the read register, done, status and the event pulses are
//    compared on every clock.
`include "cov_macros.svh"
module ONFI_sva #(
  parameter int TP = 2, TWB = 6, TWHR = 8, TADL = 10, TRR = 3, TBUSY = 2048, LW = 12
)(
  input logic          clk, rst_n,
  input logic          cmd_valid, cmd_ready,
  input logic [2:0]    cmd_op,
  input logic [23:0]   cmd_row,
  input logic [15:0]   cmd_col,
  input logic [LW-1:0] cmd_len,
  input logic          wr_valid, wr_ready,
  input logic [7:0]    wr_data,
  input logic          rd_valid, rd_ready,
  input logic [7:0]    rd_data,
  input logic          done,
  input logic [7:0]    status,
  input logic          ev_fail, ev_timeout,
  input logic          ce_n, cle, ale, we_n, re_n,
  input logic [7:0]    dq_o,
  input logic          dq_oe,
  input logic [7:0]    dq_i,
  input logic          rb_n
);
  `COV_CLOCKING(clk, !rst_n)
  // steps
  localparam int K_C = 0, K_A = 1, K_W = 2, K_B = 3, K_DI = 4, K_DO = 5, K_ST = 6;
  // phases
  localparam int P_IDLE = 0, P_NEXT = 1, P_WR = 2, P_RD = 3, P_WAIT = 4, P_BUSY = 5;

  int          k_ty [$], k_v [$];
  int          ph, cnt, m_op;
  bit          s1, s2;
  bit          o_ce, o_cle, o_ale, o_we, o_re, o_oe, o_rv, o_done, o_fail, o_to;
  logic [7:0]  o_dq, o_rd, o_st;

  task automatic add(input int t, input int v);
    k_ty.push_back(t); k_v.push_back(v);
  endtask
  task automatic build(input logic [2:0] op, input logic [23:0] row, input logic [15:0] col, input int len);
    k_ty.delete(); k_v.delete();
    case (op)
      0: begin add(K_C, 'hFF); add(K_W, TWB); add(K_B, 0); end
      1: begin add(K_C, 'h90); add(K_A, col[7:0]); add(K_W, TWHR); add(K_DO, len); end
      2: begin add(K_C, 'h70); add(K_W, TWHR); add(K_ST, 0); end
      3: begin
        add(K_C, 'h00); add(K_A, col[7:0]); add(K_A, col[15:8]); add(K_A, row[7:0]); add(K_A, row[15:8]); add(K_A, row[23:16]);
        add(K_C, 'h30); add(K_W, TWB); add(K_B, 0); add(K_W, TRR); add(K_DO, len);
      end
      4: begin
        add(K_C, 'h80); add(K_A, col[7:0]); add(K_A, col[15:8]); add(K_A, row[7:0]); add(K_A, row[15:8]); add(K_A, row[23:16]);
        add(K_W, TADL); add(K_DI, len); add(K_C, 'h10); add(K_W, TWB); add(K_B, 0);
        add(K_C, 'h70); add(K_W, TWHR); add(K_ST, 0);
      end
      5: begin
        add(K_C, 'h60); add(K_A, row[7:0]); add(K_A, row[15:8]); add(K_A, row[23:16]); add(K_C, 'hD0);
        add(K_W, TWB); add(K_B, 0); add(K_C, 'h70); add(K_W, TWHR); add(K_ST, 0);
      end
      6: begin add(K_C, 'hEE); add(K_A, col[7:0]); add(K_W, TWB); add(K_B, 0); add(K_W, TRR); add(K_DO, 4); end
      default: begin add(K_C, 'hEF); add(K_A, col[7:0]); add(K_W, TADL); add(K_DI, 4); add(K_W, TWB); add(K_B, 0); end
    endcase
  endtask

  // coverage
  bit v_op [0:7], v_len0, v_len_big, v_wr_stall, v_rd_stall, v_to [0:7], v_fail_pg, v_fail_er, v_rdy_now, v_busy_long;
  bit v_id20, v_st_busy, v_st_noise, v_cmd_wait, v_back2back;
  int busy_n;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit          c_av, c_dv, c_wv, c_rv, c_sv;
  int          c_op, c_len, c_dk;
  logic [23:0] c_row;
  logic [7:0]  c_wd, c_rd, c_sd;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph = P_IDLE; cnt = 0; m_op = 0; s1 = 0; s2 = 0;
      k_ty.delete(); k_v.delete();
      {o_cle, o_ale, o_oe, o_rv, o_done, o_fail, o_to} = '0;
      {o_ce, o_we, o_re} = 3'b111;
      o_dq = 0; o_rd = 0; o_st = 0;
      {c_av, c_dv, c_wv, c_rv, c_sv} = '0; c_op = 0; c_len = 0; c_dk = 0; c_row = 0; c_wd = 0; c_rd = 0; c_sd = 0;
    end else begin : b_step
      bit o_s2, o_rv0;
      o_s2 = s2; o_rv0 = o_rv;
      s2 = s1; s1 = rb_n;
      if (o_done && cmd_valid) v_back2back = 1;
      o_done = 0; o_fail = 0; o_to = 0;
      {c_av, c_dv, c_wv, c_rv, c_sv} = '0;
      if (o_rv && rd_ready) o_rv = 0;
      case (ph)
        P_IDLE:
          if (cmd_valid) begin
            m_op = cmd_op;
            v_op[cmd_op] = 1;
            c_av = 1; c_op = cmd_op; c_len = cmd_len; c_row = cmd_row;
            if ((cmd_op == 1 || cmd_op == 3 || cmd_op == 4) && cmd_len == 0) v_len0 = 1;
            if (cmd_len[LW-1] && (cmd_op == 3 || cmd_op == 4)) v_len_big = 1;
            if (cmd_op == 1 && cmd_col[7:0] == 8'h20) v_id20 = 1;
            build(cmd_op, cmd_row, cmd_col, cmd_len);
            o_ce = 0; ph = P_NEXT;
          end
        P_NEXT:
          if (k_ty.size() == 0) begin
            ph = P_IDLE; o_ce = 1; o_oe = 0; o_done = 1;
            o_fail = o_st[0] && (m_op == 4 || m_op == 5);
            if (o_fail) begin if (m_op == 4) v_fail_pg = 1; else v_fail_er = 1; end
            c_dv = 1; c_dk = o_fail ? (m_op == 4 ? 8 : 9) : m_op;
          end else
            case (k_ty[0])
              K_C, K_A: begin
                o_cle = k_ty[0] == K_C; o_ale = k_ty[0] == K_A; o_we = 0; o_oe = 1; o_dq = k_v[0]; cnt = 0; ph = P_WR;
              end
              K_W: begin cnt = k_v[0] - 1; ph = P_WAIT; end
              K_B: begin cnt = 0; ph = P_BUSY; end
              K_DI:
                if (k_v[0] == 0) begin void'(k_ty.pop_front()); void'(k_v.pop_front()); end
                else if (wr_valid) begin
                  o_dq = wr_data; o_we = 0; o_oe = 1; cnt = 0; ph = P_WR; k_v[0]--;
                  c_wv = 1; c_wd = wr_data;
                end else v_wr_stall = 1;
              K_DO:
                if (k_v[0] == 0) begin void'(k_ty.pop_front()); void'(k_v.pop_front()); end
                else if (!o_rv0) begin o_re = 0; o_oe = 0; cnt = 0; ph = P_RD; end
                else v_rd_stall = 1;
              default: begin o_re = 0; o_oe = 0; cnt = 0; ph = P_RD; end   // K_ST
            endcase
        P_WR: begin
          if (cnt == TP - 1) o_we = 1;
          if (cnt == 2 * TP - 1) begin
            o_cle = 0; o_ale = 0; ph = P_NEXT;
            if (k_ty[0] != K_DI) begin void'(k_ty.pop_front()); void'(k_v.pop_front()); end
          end
          cnt++;
        end
        P_RD: begin
          if (cnt == TP - 1) begin
            o_re = 1;
            if (k_ty[0] == K_ST) begin
              o_st = dq_i; c_sv = 1; c_sd = dq_i;
              if (!dq_i[6]) v_st_busy = 1;
              if (dq_i[4:1] != 0) v_st_noise = 1;
            end else begin
              o_rv = 1; o_rd = dq_i; k_v[0]--; c_rv = 1; c_rd = dq_i;
            end
          end
          if (cnt == 2 * TP - 1) begin
            ph = P_NEXT;
            if (k_ty[0] == K_ST) begin void'(k_ty.pop_front()); void'(k_v.pop_front()); end
          end
          cnt++;
        end
        P_WAIT:
          if (cnt == 0) begin ph = P_NEXT; void'(k_ty.pop_front()); void'(k_v.pop_front()); end
          else cnt--;
        default:                                       // P_BUSY
          if (o_s2) begin
            if (cnt == 0) v_rdy_now = 1;
            if (cnt > 100) v_busy_long = 1;
            ph = P_NEXT; void'(k_ty.pop_front()); void'(k_v.pop_front());
          end else if (cnt == TBUSY - 1) begin
            ph = P_IDLE; o_ce = 1; o_oe = 0; o_done = 1; o_to = 1; v_to[m_op] = 1;
            c_dv = 1; c_dk = 10 + m_op;
          end else cnt++;
      endcase
      if (cmd_valid && ph != P_IDLE) v_cmd_wait = 1;
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_pins, {ce_n, cle, ale, we_n, re_n, dq_oe} == {o_ce, o_cle, o_ale, o_we, o_re, o_oe} && (!dq_oe || dq_o == o_dq))
  `SVA_INV(a_host, cmd_ready == (ph == P_IDLE) &&
                   wr_ready == (ph == P_NEXT && k_ty.size() != 0 && k_ty[0] == K_DI && k_v[0] != 0))
  `SVA_INV(a_read, rd_valid == o_rv && (!o_rv || rd_data == o_rd))
  `SVA_INV(a_done, {done, ev_fail, ev_timeout} == {o_done, o_fail, o_to} && status == o_st)
  `SVA_RST(a_reset, !rst_n, {ce_n, cle, ale, we_n, re_n, dq_oe} == 6'b100110 && !rd_valid && !done && cmd_ready &&
                          !ev_fail && !ev_timeout && status == 0)

  // ---------------- functional coverage ----------------
  // completion kind (every op OK, program / erase fail, timeouts),
  // read-page / program length class, row class, data-in / data-out /
  // status byte classes
  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : (v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA ? 2 : 3));
  endfunction
  covergroup cg_onfi @(negedge clk);
    option.per_instance = 1;
    cp_done: coverpoint c_dk iff (rst_n && c_dv)
      { bins ok[] = {[0:7]}; bins prog_fail = {8}; bins erase_fail = {9};
        bins to_reset = {10}; bins to_read_page = {13}; bins to_erase = {15}; }
    cp_len: coverpoint (c_op == 4 ? 4 : 0) + (c_len == 0 ? 0 : (c_len < 100 ? 1 : (c_len < 2048 ? 2 : 3)))
            iff (rst_n && c_av && (c_op == 3 || c_op == 4))
      { bins rd_zero = {0}; bins rd_short = {1}; bins rd_long = {2}; bins rd_top = {3};
        bins pg_zero = {4}; bins pg_short = {5}; bins pg_long = {6}; bins pg_top = {7}; }
    cp_row: coverpoint c_row == 0 ? 0 : (c_row == 24'hFFFFFF ? 1 : 2) iff (rst_n && c_av && c_op inside {[3:5]})
      { bins zero = {0}; bins max = {1}; bins other = {2}; }
    cp_din: coverpoint dcls(c_wd) iff (rst_n && c_wv) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_dout: coverpoint dcls(c_rd) iff (rst_n && c_rv) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_status: coverpoint c_sd iff (rst_n && c_sv)
      { bins ready = {8'hE0}; bins fail = {8'hE1}; bins busy = {[0:8'hBF]}; bins ready_noise = {[8'hE2:8'hFF]}; }
  endgroup
  cg_onfi u_cg_onfi = new;

  `FC(op_reset, v_op[0])
  `FC(op_read_id, v_op[1])
  `FC(op_read_status, v_op[2])
  `FC(op_read_page, v_op[3])
  `FC(op_program, v_op[4])
  `FC(op_erase, v_op[5])
  `FC(op_get_features, v_op[6])
  `FC(op_set_features, v_op[7])
  `FC(read_id_onfi_signature, v_id20)
  `FC(zero_length, v_len0)
  `FC(long_transfer, v_len_big)
  `FC(write_stream_stall, v_wr_stall)
  `FC(read_register_full, v_rd_stall)
  `FC(ready_at_once, v_rdy_now)
  `FC(long_busy, v_busy_long)
  `FC(timeout_reset, v_to[0])
  `FC(timeout_read_page, v_to[3])
  `FC(timeout_erase, v_to[5])
  `FC(program_fail, v_fail_pg)
  `FC(erase_fail, v_fail_er)
  `FC(status_while_busy, v_st_busy)
  `FC(status_reserved_bits, v_st_noise)
  `FC(command_waits, v_cmd_wait)
  `FC(back_to_back_commands, v_back2back)
  `FC_RST(reset_in_command, rst_n && !ce_n ##1 !rst_n)
endmodule

bind ONFI_top ONFI_sva #(.TP(TP), .TWB(TWB), .TWHR(TWHR), .TADL(TADL), .TRR(TRR), .TBUSY(TBUSY), .LW(LW)) u_sva (.*);
