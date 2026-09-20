// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UniPro protocol -- MIPI UniPro 1.x data link layer (educational slice)
//   - 8-bit symbol serial tx/rx (start + 8 data LSB-first + stop, idle=1)
//   - ESC_DL escape (8'h9D, next byte XOR 0x20) + COF (8'h7E) frame delimiting
//   - L2 frame: hdr{tc[1],cport[4],seq[4],len[8]} + payload(<=16B) + CRC16
//     (poly 0x1021, init 0xFFFF, appended hi/lo, rx residue == 0)
//   - PACP control frames (get/set CPort attributes, 16x8 attr registers)
//   - data frame seq management: ACK / NAC -> retransmit <=3, ACK timeout
//   - TC0/TC1 dual TX queues, strict priority (TC1 first)
//   - received CPort0 data uplinks to 32x8 message buffer (cpu port)
// CPU map: wr 0=push TC0, 1=push TC1, 2=PACP_SET{idx,val}, 3=PACP_GET{idx},
//          4=tx_cport
//          rd 4=msg buffer pop, 5=status{msg_cnt,q1_cnt,q0_cnt},
//          6={pacp_cnf,pacp_rsp_valid,pacp_rsp_val} (read clears flags)
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module UniPro_top #(
  parameter int DW = 32,             // cpu data width
  parameter int AW = 32,             // kept for framework compatibility
  parameter int ACK_WAIT = 600       // ACK timeout in clocks
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
  input  logic [DW-1:0] cpu_wdata,
  output logic [DW-1:0] cpu_rdata,
  output logic        irq
);

  localparam logic [7:0] COF    = 8'h7E;   // frame delimiter (custom annot.)
  localparam logic [7:0] ESC_DL = 8'h9D;   // escape symbol  (custom annot.)
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

  function automatic logic [7:0] pay_byte(input logic [31:0] w,
                                          input logic [2:0]  i);
    case (i)
      3'd0:    pay_byte = w[31:24];
      3'd1:    pay_byte = w[23:16];
      3'd2:    pay_byte = w[15:8];
      default: pay_byte = w[7:0];
    endcase
  endfunction

  function automatic logic [7:0] ctl_byte(input logic [23:0] c,
                                          input logic [2:0]  i);
    case (i)
      3'd0:    ctl_byte = c[23:16];
      3'd1:    ctl_byte = c[15:8];
      default: ctl_byte = c[7:0];
    endcase
  endfunction

  // ------------------------------------------------------------------
  // shared storage
  // ------------------------------------------------------------------
  // control-frame FIFO (RX-generated: ACK/NAC/PACP responses)
  logic [23:0] cfifo [0:3];        // {cmd, arg1, arg2}
  logic [1:0]  cf_wr, cf_rd;
  logic [2:0]  cf_cnt;
  logic        cf_pop;             // pulse from TX scheduler
  wire  [23:0] cf_head = cfifo[cf_rd];

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
        RX_STOP: begin
          rxs <= RX_IDLE;
          if (rx_bit) begin
            rxb       <= rsh;
            rxb_valid <= 1'b1;
          end else begin
            e_frm <= 1'b1;          // framing error: missing stop bit
          end
        end
        default: rxs <= RX_IDLE;
      endcase
    end
  end

  // de-framer
  logic [7:0]  fr [0:31];
  logic [5:0]  flen;
  logic [15:0] rcrc;
  logic        esc_d, fdrop, frm_end;
  logic [5:0]  frm_len;   // latched at COF for the frame processor
  logic [15:0] frm_crc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      flen    <= '0;
      rcrc    <= 16'hFFFF;
      esc_d   <= 1'b0;
      fdrop   <= 1'b0;
      frm_end <= 1'b0;
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
        end else if (esc_d) begin
          esc_d <= 1'b0;
          if (flen < 6'd32) begin
            fr[flen[4:0]] <= rxb ^ 8'h20;
            flen <= flen + 6'd1;
            rcrc <= crc16_byte(rcrc, rxb ^ 8'h20);
          end else fdrop <= 1'b1;
        end else if (rxb == ESC_DL) begin
          esc_d <= 1'b1;
        end else begin
          if (flen < 6'd32) begin
            fr[flen[4:0]] <= rxb;
            flen <= flen + 6'd1;
            rcrc <= crc16_byte(rcrc, rxb);
          end else fdrop <= 1'b1;
        end
      end
    end
  end

  // frame processor events to TX/sender block
  logic       ev_ack, ev_nac;
  logic [3:0] ev_ack_seq;

  // expected seq for received data frames
  logic [3:0] exp_seq;
  // control-FIFO push flag (blocking temp inside frame processor)
  logic       push_v;

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
      e_crc  <= 1'b0;
      e_mof  <= 1'b0;
      e_cof  <= 1'b0;
      push_v = 1'b0;

      // ---------------- frame processing ----------------
      if (frm_end) begin
        if (frm_crc != 16'h0000) begin
          e_crc <= 1'b1;                       // CRC error: drop frame
        end else if (frm_len < 6'd5 || fr[2] != {2'b00, frm_len} - 8'd5) begin
          e_crc <= 1'b1;                       // length mismatch: drop
        end else if (fr[0][3:0] == CPORT_CTL) begin
          // ---------------- control frame ----------------
          case (fr[3])
            CC_GET: begin
              if (cf_cnt < 3'd4) begin
                cfifo[cf_wr] <= {CC_GETRSP, fr[4], attr[fr[4][3:0]]};
                cf_wr <= cf_wr + 2'd1;
                push_v = 1'b1;
              end else e_cof <= 1'b1;
            end
            CC_SET: begin
              attr[fr[4][3:0]] <= fr[5];
              if (cf_cnt < 3'd4) begin
                cfifo[cf_wr] <= {CC_SETCNF, fr[4], 8'h00};
                cf_wr <= cf_wr + 2'd1;
                push_v = 1'b1;
              end else e_cof <= 1'b1;
            end
            CC_GETRSP: begin
              pacp_rsp_val   <= fr[5];
              pacp_rsp_valid <= 1'b1;
            end
            CC_SETCNF: pacp_cnf <= 1'b1;
            CC_ACK: begin
              ev_ack     <= 1'b1;
              ev_ack_seq <= fr[4][3:0];
            end
            CC_NAC: ev_nac <= 1'b1;
            default: ;
          endcase
        end else begin
          // ---------------- data frame ----------------
          if (fr[1][3:0] == exp_seq) begin
            if (fr[0][3:0] == 4'h0) begin
              // CPort0 uplink to message buffer
              if (m_cnt + {1'b0, fr[2][4:0]} <= 6'd32) begin
                for (int i = 0; i < 16; i++)
                  if (i[4:0] < fr[2][4:0]) mbuf[m_wr + i[4:0]] <= fr[3+i];
                m_wr    <= m_wr + fr[2][4:0];
                m_cnt   <= m_cnt + {1'b0, fr[2][4:0]};
                exp_seq <= exp_seq + 4'd1;
                if (cf_cnt < 3'd4) begin
                  cfifo[cf_wr] <= {CC_ACK, 4'b0000, exp_seq, 8'h00};
                  cf_wr <= cf_wr + 2'd1;
                  push_v = 1'b1;
                end else e_cof <= 1'b1;
              end else begin
                e_mof <= 1'b1;                 // message buffer overflow
                if (cf_cnt < 3'd4) begin
                  cfifo[cf_wr] <= {CC_NAC, 4'b0000, exp_seq, 8'h00};
                  cf_wr <= cf_wr + 2'd1;
                  push_v = 1'b1;
                end else e_cof <= 1'b1;
              end
            end else begin
              // other CPorts: accept + ACK, payload dropped
              exp_seq <= exp_seq + 4'd1;
              if (cf_cnt < 3'd4) begin
                cfifo[cf_wr] <= {CC_ACK, 4'b0000, exp_seq, 8'h00};
                cf_wr <= cf_wr + 2'd1;
                push_v = 1'b1;
              end else e_cof <= 1'b1;
            end
          end else if (fr[1][3:0] == (exp_seq - 4'd1)) begin
            // duplicate: ACK again, do not accept
            if (cf_cnt < 3'd4) begin
              cfifo[cf_wr] <= {CC_ACK, 4'b0000, fr[1][3:0], 8'h00};
              cf_wr <= cf_wr + 2'd1;
              push_v = 1'b1;
            end else e_cof <= 1'b1;
          end else begin
            // out of sequence: NAC with expected seq
            if (cf_cnt < 3'd4) begin
              cfifo[cf_wr] <= {CC_NAC, 4'b0000, exp_seq, 8'h00};
              cf_wr <= cf_wr + 2'd1;
              push_v = 1'b1;
            end else e_cof <= 1'b1;
          end
        end
      end

      // ----------- control FIFO combined push/pop accounting -----------
      if (cf_pop && (cf_cnt != 0) && !(push_v && cf_cnt == 3'd4))
        cf_rd <= cf_rd + 2'd1;
      case ({push_v, cf_pop && (cf_cnt != 0) && !(push_v && cf_cnt == 3'd4)})
        2'b10:   cf_cnt <= cf_cnt + 3'd1;
        2'b01:   cf_cnt <= cf_cnt - 3'd1;
        default: cf_cnt <= cf_cnt;
      endcase

      // ---------------- cpu reads ----------------
      if (cpu_re) begin
        case (cpu_addr)
          3'd4: if (m_cnt != 0) begin
                  m_rd  <= m_rd + 5'd1;
                  m_cnt <= m_cnt - 6'd1;
                end
          3'd6: begin
                  pacp_rsp_valid <= 1'b0;
                  pacp_cnf       <= 1'b0;
                end
          default: ;
        endcase
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
  logic [9:0]  ser_sh;
  logic [3:0]  ser_cnt;
  logic        ser_valid;
  logic [7:0]  ser_byte;
  wire         ser_ready = !ser_busy && !ser_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ser_busy <= 1'b0;
      ser_sh   <= 10'h3FF;
      ser_cnt  <= '0;
      tx_bit   <= 1'b1;
    end else begin
      if (!ser_busy) begin
        tx_bit <= 1'b1;
        if (ser_valid) begin
          ser_busy <= 1'b1;
          ser_sh   <= {1'b1, ser_byte, 1'b0};
          ser_cnt  <= '0;
          tx_bit   <= 1'b0;               // start bit
        end
      end else begin
        tx_bit <= ser_sh[1];
        ser_sh <= {1'b1, ser_sh[9:1]};
        if (ser_cnt == 4'd8) ser_busy <= 1'b0;  // stop bit driven this cycle
        else                 ser_cnt  <= ser_cnt + 4'd1;
      end
    end
  end

  // ------------------------------------------------------------------
  // TX frame FSM + sender control (single owner of sender state)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    F_IDLE, F_COF1, F_H0, F_H1, F_H2, F_PAY, F_CRCH, F_CRCL, F_COF2
  } fstate_t;
  fstate_t    fstate;
  logic       f_isctl;
  logic       f_tc;
  logic [3:0] f_cport;
  logic [3:0] f_seq;
  logic [7:0] f_len;
  logic [31:0] f_pay;
  logic [23:0] f_ctl;
  logic [2:0] pay_cnt;
  logic       esc_ph;
  logic [15:0] fcrc;
  logic [7:0] f_crch;

  // outstanding data frame (awaiting ACK)
  logic        awaiting;
  logic        cur_q;             // 0=TC0 1=TC1
  logic        cur_tc;
  logic [3:0]  cur_cport;
  logic [31:0] cur_pay;
  logic [3:0]  cur_seq;
  logic [1:0]  retries;
  logic        relaunch;
  logic [9:0]  ack_timer;
  logic [3:0]  tx_seq;

  // cpu PACP request (single pending slot)
  logic        cpu_pacp_pend;
  logic [23:0] cpu_pacp;

  // current content byte + crc-next (combinational)
  logic [7:0]  cur_b;
  logic [15:0] crc_nxt;
  always_comb begin
    case (fstate)
      F_H0:   cur_b = {f_tc, 3'b000, f_cport};
      F_H1:   cur_b = {4'b0000, f_seq};
      F_H2:   cur_b = f_len;
      F_PAY:  cur_b = f_isctl ? ctl_byte(f_ctl, pay_cnt)
                              : pay_byte(f_pay, pay_cnt);
      F_CRCH: cur_b = f_crch;
      F_CRCL: cur_b = fcrc[7:0];
      default: cur_b = 8'h00;
    endcase
  end
  assign crc_nxt = crc16_byte(fcrc, cur_b);

  // frame content states that feed the CRC
  wire f_crc_state = (fstate == F_H0) || (fstate == F_H1) ||
                     (fstate == F_H2) || (fstate == F_PAY);
  wire f_last_pay  = (fstate == F_PAY) && (pay_cnt == f_len[2:0] - 3'd1);
  wire f_h2_last   = (fstate == F_H2) && (f_len == 8'd0);

  logic push0_v, push1_v;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fstate    <= F_IDLE;
      f_isctl   <= 1'b0;
      f_tc      <= 1'b0;
      f_cport   <= '0;
      f_seq     <= '0;
      f_len     <= '0;
      f_pay     <= '0;
      f_ctl     <= '0;
      pay_cnt   <= '0;
      esc_ph    <= 1'b0;
      fcrc      <= 16'hFFFF;
      f_crch    <= '0;
      ser_valid <= 1'b0;
      ser_byte  <= '0;
      awaiting  <= 1'b0;
      cur_q     <= 1'b0;
      cur_tc    <= 1'b0;
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
      e_qof     <= 1'b0;
      push0_v = 1'b0;
      push1_v = 1'b0;

      // ---------------- cpu writes ----------------
      if (cpu_we) begin
        case (cpu_addr)
          3'd0: if (q0_cnt < 4'd8 || pop0) begin
                  q0[q0_wr] <= {tx_cport, cpu_wdata};
                  q0_wr     <= q0_wr + 3'd1;
                  push0_v   = 1'b1;
                end else e_qof <= 1'b1;
          3'd1: if (q1_cnt < 4'd8 || pop1) begin
                  q1[q1_wr] <= {tx_cport, cpu_wdata};
                  q1_wr     <= q1_wr + 3'd1;
                  push1_v   = 1'b1;
                end else e_qof <= 1'b1;
          3'd2: begin
                  cpu_pacp      <= {CC_SET, 4'b0000, cpu_wdata[3:0],
                                    cpu_wdata[15:8]};
                  cpu_pacp_pend <= 1'b1;
                end
          3'd3: begin
                  cpu_pacp      <= {CC_GET, 4'b0000, cpu_wdata[3:0], 8'h00};
                  cpu_pacp_pend <= 1'b1;
                end
          3'd4: tx_cport <= cpu_wdata[3:0];
          default: ;
        endcase
      end

      // queue push/pop accounting (pop pulses originate 1 cycle earlier)
      if (pop0 && (q0_cnt != 0 || push0_v)) q0_rd <= q0_rd + 3'd1;
      if (pop1 && (q1_cnt != 0 || push1_v)) q1_rd <= q1_rd + 3'd1;
      case ({push0_v, pop0 && (q0_cnt != 0 || push0_v)})
        2'b10:   q0_cnt <= q0_cnt + 4'd1;
        2'b01:   q0_cnt <= q0_cnt - 4'd1;
        default: q0_cnt <= q0_cnt;
      endcase
      case ({push1_v, pop1 && (q1_cnt != 0 || push1_v)})
        2'b10:   q1_cnt <= q1_cnt + 4'd1;
        2'b01:   q1_cnt <= q1_cnt - 4'd1;
        default: q1_cnt <= q1_cnt;
      endcase

      // ---------------- ACK / NAC / timeout handling ----------------
      if (awaiting) begin
        if (ack_timer != 10'h3FF) ack_timer <= ack_timer + 10'd1;
        if (ev_ack && ev_ack_seq == cur_seq) begin
          awaiting  <= 1'b0;
          retries   <= '0;
          tx_seq    <= tx_seq + 4'd1;
          if (cur_q) pop1 <= 1'b1; else pop0 <= 1'b1;
        end else if (ev_nac || ack_timer >= ACK_WAIT[9:0]) begin
          if (retries < 2'd3) begin
            retries   <= retries + 2'd1;
            relaunch  <= 1'b1;
            ack_timer <= '0;
          end else begin
            // retransmission budget exhausted: drop frame
            awaiting  <= 1'b0;
            retries   <= '0;
            tx_seq    <= tx_seq + 4'd1;
            e_rex     <= 1'b1;
            if (cur_q) pop1 <= 1'b1; else pop0 <= 1'b1;
          end
        end
      end

      // ---------------- TX frame FSM ----------------
      case (fstate)
        F_IDLE: begin
          if (relaunch) begin
            relaunch <= 1'b0;
            f_isctl  <= 1'b0;
            f_tc     <= cur_tc;
            f_cport  <= cur_cport;
            f_seq    <= cur_seq;
            f_len    <= 8'd4;
            f_pay    <= cur_pay;
            pay_cnt  <= '0;
            esc_ph   <= 1'b0;
            fcrc     <= 16'hFFFF;
            fstate   <= F_COF1;
          end else if (!awaiting) begin
            if (cf_cnt != 0) begin
              cf_pop   <= 1'b1;
              f_isctl  <= 1'b1;
              f_tc     <= 1'b0;
              f_cport  <= CPORT_CTL;
              f_seq    <= 4'h0;
              f_len    <= 8'd3;
              f_ctl    <= cf_head;
              pay_cnt  <= '0;
              esc_ph   <= 1'b0;
              fcrc     <= 16'hFFFF;
              fstate   <= F_COF1;
            end else if (cpu_pacp_pend) begin
              cpu_pacp_pend <= 1'b0;
              f_isctl  <= 1'b1;
              f_tc     <= 1'b0;
              f_cport  <= CPORT_CTL;
              f_seq    <= 4'h0;
              f_len    <= 8'd3;
              f_ctl    <= cpu_pacp;
              pay_cnt  <= '0;
              esc_ph   <= 1'b0;
              fcrc     <= 16'hFFFF;
              fstate   <= F_COF1;
            end else if (q1_cnt != 0 && !pop1 && !pop0) begin
              // strict priority: TC1 first
              f_isctl  <= 1'b0;
              f_tc     <= 1'b1;
              f_cport  <= q1[q1_rd][35:32];
              f_seq    <= tx_seq;
              f_len    <= 8'd4;
              f_pay    <= q1[q1_rd][31:0];
              cur_q    <= 1'b1;
              cur_tc   <= 1'b1;
              cur_cport<= q1[q1_rd][35:32];
              cur_pay  <= q1[q1_rd][31:0];
              cur_seq  <= tx_seq;
              pay_cnt  <= '0;
              esc_ph   <= 1'b0;
              fcrc     <= 16'hFFFF;
              fstate   <= F_COF1;
            end else if (q0_cnt != 0 && !pop0 && !pop1) begin
              f_isctl  <= 1'b0;
              f_tc     <= 1'b0;
              f_cport  <= q0[q0_rd][35:32];
              f_seq    <= tx_seq;
              f_len    <= 8'd4;
              f_pay    <= q0[q0_rd][31:0];
              cur_q    <= 1'b0;
              cur_tc   <= 1'b0;
              cur_cport<= q0[q0_rd][35:32];
              cur_pay  <= q0[q0_rd][31:0];
              cur_seq  <= tx_seq;
              pay_cnt  <= '0;
              esc_ph   <= 1'b0;
              fcrc     <= 16'hFFFF;
              fstate   <= F_COF1;
            end
          end
        end

        F_COF1: if (ser_ready) begin
          ser_valid <= 1'b1;
          ser_byte  <= COF;
          fstate    <= F_H0;
        end

        F_H0, F_H1, F_H2, F_PAY, F_CRCH, F_CRCL: begin
          if (ser_ready) begin
            if (!esc_ph) begin
              // commit byte to CRC (except CRC field states)
              if (f_crc_state) begin
                fcrc <= crc_nxt;
                if (f_last_pay || f_h2_last) f_crch <= crc_nxt[15:8];
              end
              if (cur_b == COF || cur_b == ESC_DL) begin
                ser_valid <= 1'b1;
                ser_byte  <= ESC_DL;
                esc_ph    <= 1'b1;
              end else begin
                ser_valid <= 1'b1;
                ser_byte  <= cur_b;
                // advance
                case (fstate)
                  F_H0: fstate <= F_H1;
                  F_H1: fstate <= F_H2;
                  F_H2: begin
                    pay_cnt <= '0;
                    fstate  <= (f_len == 8'd0) ? F_CRCH : F_PAY;
                  end
                  F_PAY: begin
                    if (pay_cnt == f_len[2:0] - 3'd1) fstate <= F_CRCH;
                    else pay_cnt <= pay_cnt + 3'd1;
                  end
                  F_CRCH: fstate <= F_CRCL;
                  default: fstate <= F_COF2;   // F_CRCL
                endcase
              end
            end else begin
              // second half of escape pair
              ser_valid <= 1'b1;
              ser_byte  <= cur_b ^ 8'h20;
              esc_ph    <= 1'b0;
              case (fstate)
                F_H0: fstate <= F_H1;
                F_H1: fstate <= F_H2;
                F_H2: begin
                  pay_cnt <= '0;
                  fstate  <= (f_len == 8'd0) ? F_CRCH : F_PAY;
                end
                F_PAY: begin
                  if (pay_cnt == f_len[2:0] - 3'd1) fstate <= F_CRCH;
                  else pay_cnt <= pay_cnt + 3'd1;
                end
                F_CRCH: fstate <= F_CRCL;
                default: fstate <= F_COF2;     // F_CRCL
              endcase
            end
          end
        end

        F_COF2: if (ser_ready) begin
          ser_valid <= 1'b1;
          ser_byte  <= COF;
          fstate    <= F_IDLE;
          if (!f_isctl) begin
            awaiting  <= 1'b1;               // start ACK wait
            ack_timer <= '0;
          end
        end

        default: fstate <= F_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // cpu read port
  // ------------------------------------------------------------------
  always_comb begin
    case (cpu_addr)
      3'd4:    cpu_rdata = {{(DW-8){1'b0}}, mbuf[m_rd]};
      3'd5:    cpu_rdata = {{(DW-16){1'b0}}, 2'b00, m_cnt, q1_cnt, q0_cnt};
      3'd6:    cpu_rdata = {{(DW-10){1'b0}}, pacp_cnf, pacp_rsp_valid,
                            pacp_rsp_val};
      default: cpu_rdata = '0;
    endcase
  end

endmodule
