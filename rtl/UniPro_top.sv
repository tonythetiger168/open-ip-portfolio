// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UniPro protocol -- MIPI UniPro 1.x data link layer (educational slice)
//   - 8-bit symbol serial tx/rx (start + 8 data LSB-first + stop, idle=1,
//     1 bit/clk); a missing stop bit is a framing error
//   - ESC_DL escape (8'h9D, next byte XOR 0x20) + COF (8'h7E) frame delimiting;
//     a frame over 32 bytes is dropped silently
//   - L2 frame: hdr{tc[1],cport[4],seq[4],len[8]} + payload(<=16B) + CRC16
//     (poly 0x1021, init 0xFFFF, appended hi/lo, rx residue == 0).  A bad
//     residue, len != bytes - 5, len > 16 or a control frame with len != 3 is
//     dropped with an error.
//   - Control frames (CPort 15): GET/SET of 16x8 attributes, GET response,
//     SET confirm, ACK{seq}, NAC{expected seq}; unknown commands are ignored
//   - Data frames: one outstanding frame awaiting ACK; NAC or ACK timeout
//     resends it (<=3 resends), then it is dropped with an error.  ACK, NAC
//     and PACP frames still go out while a data frame is outstanding.
//   - Receive side: in-sequence data is ACKed (CPort0 payload goes to a
//     32x8 message buffer; no room -> NAC + error), the previous sequence
//     number is re-ACKed (duplicate), anything else is NACed
//   - TC0/TC1 transmit queues (8 entries), strict priority (TC1 first)
// CPU map: wr 0=push TC0, 1=push TC1, 2=PACP SET{val[15:8],idx[3:0]},
//          3=PACP GET{idx[3:0]}, 4=tx_cport
//          rd 4=message buffer pop, 5=status (below),
//          6={pacp_cnf,pacp_rsp_valid,pacp_rsp_val} (read clears flags)
//          status = {pacp_cnf, pacp_rsp_valid, tx busy, PACP request pending,
//                    data frame outstanding, resends[1:0], control FIFO
//                    count[2:0], rx expected seq[3:0], tx seq[3:0],
//                    msg count[5:0], TC1 count[3:0], TC0 count[3:0]}
// irq: 1-clk pulse on CRC/length error, framing error, message buffer
//      overflow, control FIFO overflow, resend budget exhausted, queue overflow
// IP design implementation v2.0 -- Apache-2.0
// ============================================================================
module UniPro_top #(
  parameter int ACK_WAIT = 600       // ACK timeout in clocks (after the frame)
)(
  input  logic        clk,
  input  logic        rst_n,
  // UniPro serial line (symbol stream)
  input  logic        rx_bit,
  output logic        tx_bit,
  // cpu port
  input  logic        cpu_we,
  input  logic        cpu_re,
  input  logic [2:0]  cpu_addr,
  input  logic [31:0] cpu_wdata,
  output logic [31:0] cpu_rdata,
  output logic        irq
);

  localparam logic [7:0] COF    = 8'h7E;   // frame delimiter
  localparam logic [7:0] ESC_DL = 8'h9D;   // escape symbol
  localparam logic [3:0] CPORT_CTL = 4'hF; // control frames CPort
  // control frame commands
  localparam logic [7:0] CC_GET    = 8'd0;
  localparam logic [7:0] CC_SET    = 8'd1;
  localparam logic [7:0] CC_GETRSP = 8'd2;
  localparam logic [7:0] CC_SETCNF = 8'd3;
  localparam logic [7:0] CC_ACK    = 8'd4;
  localparam logic [7:0] CC_NAC    = 8'd5;

  // ------------------------------------------------------------------
  // CRC16 (poly 0x1021, init 0xFFFF), byte-wise update
  // ------------------------------------------------------------------
  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    begin
      c = crc ^ {data, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      crc16_byte = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // shared storage
  // ------------------------------------------------------------------
  // control-frame FIFO (RX-generated): {code, arg1, arg2},
  // code 0 GET response, 1 SET confirm, 2 ACK, 3 NAC (command = code + 2)
  logic [17:0] cfifo [0:3];
  logic [1:0]  cf_wr, cf_rd;
  logic [2:0]  cf_cnt;
  logic        cf_pop;             // pulse from TX scheduler

  // attribute file 16x8 + PACP response capture
  logic [7:0]  attr [0:15];
  logic [7:0]  pacp_rsp_val;
  logic        pacp_rsp_valid, pacp_cnf;

  // message buffer 32x8 (CPort0 uplink)
  logic [7:0]  mbuf [0:31];
  logic [4:0]  m_wr, m_rd;
  logic [5:0]  m_cnt;

  // error pulses
  logic        e_crc, e_frm, e_mof, e_cof;
  logic        e_rex, e_qof;

  assign irq = e_crc | e_frm | e_mof | e_cof | e_rex | e_qof;

  // ------------------------------------------------------------------
  // RX path: symbol deserializer -> ESC/COF de-framer -> frame processor
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {RX_IDLE, RX_DATA, RX_STOP} rxs_t;
  rxs_t       rxs;
  logic [2:0] rbitcnt;
  logic [7:0] rsh;
  logic       rxb_valid;
  logic [7:0] rxb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxs       <= RX_IDLE;
      rbitcnt   <= '0;
      rsh       <= '0;
      rxb_valid <= 1'b0;
      rxb       <= '0;
      e_frm     <= 1'b0;
    end else begin
      rxb_valid <= 1'b0;
      e_frm     <= 1'b0;
      case (rxs)
        RX_IDLE: if (!rx_bit) begin rxs <= RX_DATA; rbitcnt <= '0; end
        RX_DATA: begin
          rsh[rbitcnt] <= rx_bit;
          if (rbitcnt == 3'd7) rxs <= RX_STOP;
          else                 rbitcnt <= rbitcnt + 3'd1;
        end
        default: begin                // RX_STOP
          rxs <= RX_IDLE;
          if (rx_bit) begin
            rxb       <= rsh;
            rxb_valid <= 1'b1;
          end else begin
            e_frm <= 1'b1;            // framing error: missing stop bit
          end
        end
      endcase
    end
  end

  // de-framer: bytes 0..18 (header + payload) are kept, CRC bytes only
  // feed the residue
  logic [7:0]  fr [0:18];
  logic [5:0]  flen;
  logic [15:0] rcrc;
  logic        esc_d, fdrop, frm_end;
  logic [5:0]  frm_len;   // latched at COF for the frame processor
  logic [15:0] frm_crc;
  wire  [7:0]  rx_db = esc_d ? rxb ^ 8'h20 : rxb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      flen    <= '0;
      rcrc    <= 16'hFFFF;
      esc_d   <= 1'b0;
      fdrop   <= 1'b0;
      frm_end <= 1'b0;
      frm_len <= '0;
      frm_crc <= '0;
    end else begin
      frm_end <= 1'b0;
      if (rxb_valid) begin
        if (rxb == COF) begin
          if ((flen != 0) && !fdrop) begin
            frm_end <= 1'b1;
            frm_len <= flen;
            frm_crc <= rcrc;
          end
          flen  <= '0;
          rcrc  <= 16'hFFFF;
          esc_d <= 1'b0;
          fdrop <= 1'b0;
        end else if (rxb == ESC_DL && !esc_d) begin
          esc_d <= 1'b1;
        end else begin
          esc_d <= 1'b0;
          if (flen == 6'd32) fdrop <= 1'b1;
          else begin
            if (flen < 6'd19) fr[flen[4:0]] <= rx_db;
            flen <= flen + 6'd1;
            rcrc <= crc16_byte(rcrc, rx_db);
          end
        end
      end
    end
  end

  // frame processor events to the sender
  logic       ev_ack, ev_nac;
  logic [3:0] ev_ack_seq;
  logic [3:0] exp_seq;            // expected seq of received data frames

  wire        f_ctl_frm = fr[0][3:0] == CPORT_CTL;
  wire        len_bad   = frm_len < 6'd5 || fr[2] != {2'b00, frm_len} - 8'd5 ||
                          fr[2] > 8'd16 || (f_ctl_frm && fr[2] != 8'd3);
  wire        frm_ok    = frm_end && frm_crc == 16'h0000 && !len_bad;
  wire [3:0]  r_seq     = fr[1][3:0];
  wire [4:0]  r_len     = fr[2][4:0];
  wire        m_room    = m_cnt + {1'b0, r_len} <= 6'd32;
  wire        r_up      = fr[0][3:0] == 4'h0;   // CPort0 uplink

  // control-FIFO entry produced by this frame, bytes taken by the buffer
  logic        push_v;
  logic [17:0] push_d;
  logic [4:0]  m_add;
  always_comb begin
    push_v = 1'b0;
    push_d = '0;
    m_add  = '0;
    if (frm_ok) begin
      if (f_ctl_frm) begin
        if (fr[3] == CC_GET) begin
          push_v = 1'b1;
          push_d = {2'd0, fr[4], attr[fr[4][3:0]]};
        end else if (fr[3] == CC_SET) begin
          push_v = 1'b1;
          push_d = {2'd1, fr[4], 8'h00};
        end
      end else if (r_seq == exp_seq) begin     // in sequence: ACK, or NAC if no room
        push_v = 1'b1;
        push_d = {(r_up && !m_room) ? 2'd3 : 2'd2, 4'b0000, exp_seq, 8'h00};
        if (r_up && m_room) m_add = r_len;
      end else begin                           // duplicate: ACK again; else NAC{expected}
        push_v = 1'b1;
        push_d = (r_seq == exp_seq - 4'd1) ? {2'd2, 4'b0000, r_seq, 8'h00}
                                           : {2'd3, 4'b0000, exp_seq, 8'h00};
      end
    end
  end
  wire cf_push = push_v && cf_cnt != 3'd4;
  wire m_pop   = cpu_re && cpu_addr == 3'd4 && m_cnt != 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exp_seq        <= '0;
      m_wr           <= '0;
      m_rd           <= '0;
      m_cnt          <= '0;
      cf_wr          <= '0;
      cf_rd          <= '0;
      cf_cnt         <= '0;
      pacp_rsp_val   <= '0;
      pacp_rsp_valid <= 1'b0;
      pacp_cnf       <= 1'b0;
      ev_ack         <= 1'b0;
      ev_nac         <= 1'b0;
      ev_ack_seq     <= '0;
      e_crc          <= 1'b0;
      e_mof          <= 1'b0;
      e_cof          <= 1'b0;
      for (int i = 0; i < 16; i++) attr[i] <= 8'h00;
    end else begin
      ev_ack <= 1'b0;
      ev_nac <= 1'b0;
      e_crc  <= frm_end && !frm_ok;            // CRC / length error: frame dropped
      e_mof  <= frm_ok && !f_ctl_frm && r_seq == exp_seq && r_up && !m_room;
      e_cof  <= push_v && !cf_push;            // control FIFO overflow

      if (frm_ok && f_ctl_frm)
        case (fr[3])
          CC_SET:    attr[fr[4][3:0]] <= fr[5];
          CC_GETRSP: begin
            pacp_rsp_val   <= fr[5];
            pacp_rsp_valid <= 1'b1;
          end
          CC_SETCNF: pacp_cnf <= 1'b1;
          CC_ACK: begin
            ev_ack     <= 1'b1;
            ev_ack_seq <= fr[4][3:0];
          end
          CC_NAC:    ev_nac <= 1'b1;
          default: ;                           // GET (answered via FIFO), unknown
        endcase
      if (frm_ok && !f_ctl_frm && r_seq == exp_seq && (!r_up || m_room))
        exp_seq <= exp_seq + 4'd1;
      for (int i = 0; i < 16; i++)
        if (i[4:0] < m_add) mbuf[m_wr + i[4:0]] <= fr[3+i];
      m_wr <= m_wr + m_add;

      // control FIFO
      if (cf_push) begin
        cfifo[cf_wr] <= push_d;
        cf_wr <= cf_wr + 2'd1;
      end
      if (cf_pop) cf_rd <= cf_rd + 2'd1;
      cf_cnt <= cf_cnt + {2'd0, cf_push} - {2'd0, cf_pop};

      // message buffer count / cpu pops
      if (m_pop) m_rd <= m_rd + 5'd1;
      m_cnt <= m_cnt + {1'b0, m_add} - {5'd0, m_pop};
      if (cpu_re && cpu_addr == 3'd6) begin    // read clears the PACP flags
        pacp_rsp_valid <= 1'b0;
        pacp_cnf       <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // TX data queues: 8x36 {cport[3:0], payload[31:0]}, TC0 and TC1
  // ------------------------------------------------------------------
  logic [35:0] q0 [0:7];
  logic [35:0] q1 [0:7];
  logic [2:0]  q0_wr, q0_rd, q1_wr, q1_rd;
  logic [3:0]  q0_cnt, q1_cnt;
  logic [3:0]  tx_cport;
  logic        pop0, pop1;       // pulses from sender control

  // ------------------------------------------------------------------
  // symbol serializer: start(0) + 8 data bits LSB first + stop(1)
  // ------------------------------------------------------------------
  logic        ser_busy;
  logic [7:0]  ser_sh;
  logic [3:0]  ser_cnt;
  logic        ser_valid;
  logic [7:0]  ser_byte;
  wire         ser_ready = !ser_busy && !ser_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ser_busy <= 1'b0;
      ser_sh   <= 8'h00;
      ser_cnt  <= '0;
      tx_bit   <= 1'b1;
    end else if (!ser_busy) begin
      tx_bit <= !ser_valid;               // idle 1, or the start bit
      if (ser_valid) begin
        ser_busy <= 1'b1;
        ser_sh   <= ser_byte;
        ser_cnt  <= '0;
      end
    end else begin
      tx_bit <= ser_sh[0] || ser_cnt[3];  // data bits, then the stop bit
      ser_sh <= ser_sh >> 1;
      if (ser_cnt == 4'd8) ser_busy <= 1'b0;  // stop bit driven this cycle
      else                 ser_cnt  <= ser_cnt + 4'd1;
    end
  end

  // ------------------------------------------------------------------
  // TX frame FSM + sender control (single owner of sender state)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    F_IDLE, F_COF1, F_H0, F_H1, F_H2, F_PAY, F_CRCH, F_CRCL, F_COF2
  } fstate_t;
  fstate_t     fstate;
  logic        f_isctl;
  logic        f_tc;
  logic [3:0]  f_cport;
  logic [3:0]  f_seq;
  logic [31:0] f_pay;
  logic [18:0] f_ctl;             // {cmd[2:0], arg1, arg2}
  logic [1:0]  pay_cnt;
  logic        esc_ph;
  logic [15:0] fcrc;

  // outstanding data frame (awaiting ACK)
  logic        out;
  logic        cur_q;             // 0=TC0 1=TC1 (also the frame's TC)
  logic [3:0]  cur_cport;
  logic [31:0] cur_pay;
  logic [3:0]  cur_seq;
  logic [1:0]  retries;
  logic        relaunch;
  logic [9:0]  ack_timer;
  logic [3:0]  tx_seq;

  // cpu PACP request (single pending slot): {set, idx, val}
  logic        cpu_pacp_pend;
  logic [12:0] cpu_pacp;

  // current content byte (combinational)
  logic [7:0]  cur_b;
  always_comb begin
    case (fstate)
      F_H0:   cur_b = {f_tc, 3'b000, f_cport};
      F_H1:   cur_b = {4'b0000, f_seq};
      F_H2:   cur_b = {5'd0, !f_isctl, f_isctl, f_isctl};   // len 4 / 3
      F_PAY:  cur_b = f_isctl ? (pay_cnt == 2'd0 ? {5'd0, f_ctl[18:16]} :
                                 pay_cnt == 2'd1 ? f_ctl[15:8] : f_ctl[7:0])
                              : f_pay[{~pay_cnt, 3'b000} +: 8];
      F_CRCH: cur_b = fcrc[15:8];
      F_CRCL: cur_b = fcrc[7:0];
      default: cur_b = 8'h00;
    endcase
  end

  wire byte_st   = (fstate == F_H0) || (fstate == F_H1) || (fstate == F_H2) ||
                   (fstate == F_PAY) || (fstate == F_CRCH) || (fstate == F_CRCL);
  wire need_esc  = cur_b == COF || cur_b == ESC_DL;
  wire b_done    = ser_ready && (esc_ph || !need_esc);   // byte fully sent
  wire pay_last  = pay_cnt == {1'b1, !f_isctl};
  wire sending   = fstate != F_IDLE && !f_isctl;         // data frame on the wire
  wire q_free    = !out && !pop0 && !pop1;               // next data frame may start

  wire pacp_wr = cpu_we && (cpu_addr == 3'd2 || cpu_addr == 3'd3);
  wire push0_v = cpu_we && cpu_addr == 3'd0 && (q0_cnt < 4'd8 || pop0);
  wire push1_v = cpu_we && cpu_addr == 3'd1 && (q1_cnt < 4'd8 || pop1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fstate    <= F_IDLE;
      f_isctl   <= 1'b0;
      f_tc      <= 1'b0;
      f_cport   <= '0;
      f_seq     <= '0;
      f_pay     <= '0;
      f_ctl     <= '0;
      pay_cnt   <= '0;
      esc_ph    <= 1'b0;
      fcrc      <= 16'hFFFF;
      ser_valid <= 1'b0;
      ser_byte  <= '0;
      out       <= 1'b0;
      cur_q     <= 1'b0;
      cur_cport <= '0;
      cur_pay   <= '0;
      cur_seq   <= '0;
      retries   <= '0;
      relaunch  <= 1'b0;
      ack_timer <= '0;
      tx_seq    <= '0;
      cf_pop    <= 1'b0;
      pop0      <= 1'b0;
      pop1      <= 1'b0;
      q0_wr     <= '0; q0_rd <= '0; q0_cnt <= '0;
      q1_wr     <= '0; q1_rd <= '0; q1_cnt <= '0;
      tx_cport  <= '0;
      cpu_pacp_pend <= 1'b0;
      cpu_pacp  <= '0;
      e_rex     <= 1'b0;
      e_qof     <= 1'b0;
    end else begin
      ser_valid <= 1'b0;
      cf_pop    <= 1'b0;
      pop0      <= 1'b0;
      pop1      <= 1'b0;
      e_rex     <= 1'b0;
      e_qof     <= cpu_we && ((cpu_addr == 3'd0 && !push0_v) || (cpu_addr == 3'd1 && !push1_v));

      // ---------------- cpu writes ----------------
      if (cpu_we) begin
        case (cpu_addr)
          3'd0: if (push0_v) begin
                  q0[q0_wr] <= {tx_cport, cpu_wdata};
                  q0_wr     <= q0_wr + 3'd1;
                end
          3'd1: if (push1_v) begin
                  q1[q1_wr] <= {tx_cport, cpu_wdata};
                  q1_wr     <= q1_wr + 3'd1;
                end
          3'd2: cpu_pacp <= {1'b1, cpu_wdata[3:0], cpu_wdata[15:8]};
          3'd3: cpu_pacp <= {1'b0, cpu_wdata[3:0], 8'h00};
          3'd4: tx_cport <= cpu_wdata[3:0];
          default: ;
        endcase
      end

      // queue accounting (pop pulses come from the sender one cycle later)
      if (pop0) q0_rd <= q0_rd + 3'd1;
      if (pop1) q1_rd <= q1_rd + 3'd1;
      q0_cnt <= q0_cnt + {3'd0, push0_v} - {3'd0, pop0};
      q1_cnt <= q1_cnt + {3'd0, push1_v} - {3'd0, pop1};

      // ---------------- ACK / NAC / timeout handling ----------------
      if (out && ev_ack && ev_ack_seq == cur_seq) begin
        out      <= 1'b0;
        relaunch <= 1'b0;
        retries  <= '0;
        tx_seq   <= tx_seq + 4'd1;
        if (cur_q) pop1 <= 1'b1; else pop0 <= 1'b1;
      end else if (out && !relaunch && !sending) begin
        if (ev_nac || ack_timer == 10'(ACK_WAIT - 1)) begin
          ack_timer <= '0;
          if (retries != 2'd3) begin
            retries  <= retries + 2'd1;
            relaunch <= 1'b1;
          end else begin                       // resend budget exhausted: drop
            out     <= 1'b0;
            retries <= '0;
            tx_seq  <= tx_seq + 4'd1;
            e_rex   <= 1'b1;
            if (cur_q) pop1 <= 1'b1; else pop0 <= 1'b1;
          end
        end else ack_timer <= ack_timer + 10'd1;
      end

      // ---------------- byte transmission ----------------
      if (byte_st && ser_ready) begin
        ser_valid <= 1'b1;
        if (!esc_ph && (fstate != F_CRCH) && (fstate != F_CRCL))
          fcrc <= crc16_byte(fcrc, cur_b);
        if (!esc_ph && need_esc) begin
          ser_byte <= ESC_DL;
          esc_ph   <= 1'b1;
        end else begin
          ser_byte <= esc_ph ? cur_b ^ 8'h20 : cur_b;
          esc_ph   <= 1'b0;
        end
      end

      // a new cpu request wins over the launch of the pending one
      if (pacp_wr) cpu_pacp_pend <= 1'b1;
      else if (fstate == F_IDLE && !relaunch && cf_cnt == 3'd0) cpu_pacp_pend <= 1'b0;

      // ---------------- TX frame FSM ----------------
      case (fstate)
        F_IDLE: begin
          pay_cnt <= '0;
          fcrc    <= 16'hFFFF;
          if (relaunch) begin                  // resend the outstanding frame
            relaunch <= 1'b0;
            f_isctl  <= 1'b0;
            f_tc     <= cur_q;
            f_cport  <= cur_cport;
            f_seq    <= cur_seq;
            f_pay    <= cur_pay;
            fstate   <= F_COF1;
          end else if (cf_cnt != 0) begin       // ACK / NAC / PACP response
            cf_pop   <= 1'b1;
            f_isctl  <= 1'b1;
            f_tc     <= 1'b0;
            f_cport  <= CPORT_CTL;
            f_seq    <= 4'h0;
            f_ctl    <= {cfifo[cf_rd][17:16] + 3'd2, cfifo[cf_rd][15:0]};
            fstate   <= F_COF1;
          end else if (cpu_pacp_pend) begin     // PACP request from the cpu
            f_isctl  <= 1'b1;
            f_tc     <= 1'b0;
            f_cport  <= CPORT_CTL;
            f_seq    <= 4'h0;
            f_ctl    <= {2'b00, cpu_pacp[12], 4'b0000, cpu_pacp[11:0]};
            fstate   <= F_COF1;
          end else if (q_free && q1_cnt != 0) begin   // strict priority: TC1 first
            f_isctl  <= 1'b0;
            f_tc     <= 1'b1;
            f_cport  <= q1[q1_rd][35:32];
            f_seq    <= tx_seq;
            f_pay    <= q1[q1_rd][31:0];
            out      <= 1'b1;
            ack_timer<= '0;
            cur_q    <= 1'b1;
            cur_cport<= q1[q1_rd][35:32];
            cur_pay  <= q1[q1_rd][31:0];
            cur_seq  <= tx_seq;
            fstate   <= F_COF1;
          end else if (q_free && q0_cnt != 0) begin
            f_isctl  <= 1'b0;
            f_tc     <= 1'b0;
            f_cport  <= q0[q0_rd][35:32];
            f_seq    <= tx_seq;
            f_pay    <= q0[q0_rd][31:0];
            out      <= 1'b1;
            ack_timer<= '0;
            cur_q    <= 1'b0;
            cur_cport<= q0[q0_rd][35:32];
            cur_pay  <= q0[q0_rd][31:0];
            cur_seq  <= tx_seq;
            fstate   <= F_COF1;
          end
        end
        F_COF1: if (ser_ready) begin
          ser_valid <= 1'b1;
          ser_byte  <= COF;
          fstate    <= F_H0;
        end
        F_H0:   if (b_done) fstate <= F_H1;
        F_H1:   if (b_done) fstate <= F_H2;
        F_H2:   if (b_done) fstate <= F_PAY;
        F_PAY:  if (b_done) begin
          if (pay_last) fstate <= F_CRCH;
          else pay_cnt <= pay_cnt + 2'd1;
        end
        F_CRCH: if (b_done) fstate <= F_CRCL;
        F_CRCL: if (b_done) fstate <= F_COF2;
        default: if (ser_ready) begin           // F_COF2
          ser_valid <= 1'b1;
          ser_byte  <= COF;
          fstate    <= F_IDLE;
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // cpu read port
  // ------------------------------------------------------------------
  always_comb begin
    case (cpu_addr)
      3'd4:    cpu_rdata = {24'd0, mbuf[m_rd]};
      3'd5:    cpu_rdata = {pacp_cnf, pacp_rsp_valid, fstate != F_IDLE, cpu_pacp_pend,
                            out, retries, cf_cnt, exp_seq, tx_seq, m_cnt, q1_cnt, q0_cnt};
      3'd6:    cpu_rdata = {22'd0, pacp_cnf, pacp_rsp_valid, pacp_rsp_val};
      default: cpu_rdata = '0;
    endcase
  end

endmodule
