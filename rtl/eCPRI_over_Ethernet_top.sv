// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// eCPRI over Ethernet -- eCPRI message layer slice (node side)
//   - Ethernet frame parse/generate: DMAC + SMAC + Ethertype 0xAEFE +
//     payload + FCS (CRC-32/ISO-HDLC reflected, init/xorout 0xFFFFFFFF,
//     FCS sent LSB-byte first; rx residue check == 0xDEBB20E3).
//     Preamble/SFD/IFG are handled by the external MAC (byte stream i/f).
//   - Every frame is a minimum-size (64 byte) Ethernet frame: an eCPRI
//     payload is at most 40 bytes, so TX zero-pads to 60 bytes + FCS and RX
//     requires exactly 64 bytes. tx_en drops for at least one cycle between
//     frames.
//   - RX address filter: DMAC must be the node's own MAC (cfg_smac) or
//     broadcast; other frames and non-0xAEFE frames are dropped silently.
//   - eCPRI common header {rev[4]=1,rsvd[3],c[1], msgtype[8], payload_size[16]}
//   - msgtype 0: IQ data -- pc_id[16] + seq_id[16] + IQ bytes (<=32B, must be
//     a multiple of 4) packed big-endian into a 32x32 IQ buffer (cpu pop);
//     seq_id gap tracking per link
//   - msgtype 4: generic memory transfer -- remote_addr[32] + rw[8]
//     (1=write + data[32], 0=read) against a 64x32 memory (byte address,
//     word aligned, < 256); read triggers a response frame (rw=2)
//   - msgtype 5: remote reset -- reset_id[16] + op[8] (1=request, plus
//     optional vendor bytes); drives reset_op and answers op=2 (response)
//   - msgtype 6: event indication -- event_id + type + seq + n_elem and
//     n_elem x 8-byte elements (payload_size == 4 + 8*n_elem, n_elem <= 4).
//     type 0 (fault) is answered with type 1 (fault ack), type 3 (sync
//     request) with type 4 (sync ack); type 1 matching the last injected
//     fault clears ack_wait; types 2/4/5 are recorded only.
//   - cpu fault injection queues a fault indication frame (one element,
//     element id 0xFFFF, raise/cease + 12-bit fault number, own seq).
//   - rx_smac (cpu regs 10/11) holds the source MAC of the last accepted
//     message.
//   - errors (sticky irq): bad FCS; bad length / revision / payload shape;
//     concatenated message (c=1); unsupported msgtype; IQ buffer or TX
//     queue overflow and injection while one is still pending.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module eCPRI_over_Ethernet_top (
  input  logic        clk,
  input  logic        rst_n,
  // Ethernet MAC byte stream (no preamble/SFD)
  input  logic [7:0]  rx_d,
  input  logic        rx_dv,
  output logic [7:0]  tx_d,
  output logic        tx_en,
  // remote reset operation output (msgtype 5)
  output logic [15:0] reset_op,
  // cpu port
  input  logic        cpu_we,
  input  logic        cpu_re,
  input  logic [3:0]  cpu_addr,
  input  logic [31:0] cpu_wdata,
  output logic [31:0] cpu_rdata,
  output logic        irq
);

  localparam logic [15:0] ET_ECPRI    = 16'hAEFE;
  localparam logic [7:0]  ECPRI_REV   = 8'h10;     // rev=1, c=0
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB20E3;
  localparam int          PAY_MAX     = 40;        // max supported payload
  localparam logic [6:0]  FRAME_LEN   = 7'd64;     // incl. FCS

  // message types
  localparam logic [7:0] MT_IQ   = 8'd0;
  localparam logic [7:0] MT_MEM  = 8'd4;
  localparam logic [7:0] MT_RST  = 8'd5;
  localparam logic [7:0] MT_EVT  = 8'd6;

  // tx descriptor kinds; field f / data d per kind:
  //   RDRESP : f[5:0] word address,           d = memory word
  //   RSTRESP: f[15:0] reset id
  //   EVTACK : f[16] sync (type 4, else 1), f[15:8] event id, f[7:0] seq
  //   EVTIND : f[20] cease, f[19:8] fault number, f[7:0] event id
  localparam logic [1:0] TK_RDRESP  = 2'd0;
  localparam logic [1:0] TK_RSTRESP = 2'd1;
  localparam logic [1:0] TK_EVTACK  = 2'd2;
  localparam logic [1:0] TK_EVTIND  = 2'd3;

  // ------------------------------------------------------------------
  // CRC-32/ISO-HDLC (reflected poly 0xEDB88320), byte update
  // ------------------------------------------------------------------
  function automatic logic [31:0] crc32_byte(input logic [31:0] crc,
                                             input logic [7:0]  d);
    logic [31:0] c;
    begin
      c = crc ^ {24'h0, d};
      for (int i = 0; i < 8; i++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32_byte = c;
    end
  endfunction

  // byte i (0 = first on the wire) of a MAC address
  function automatic logic [7:0] mac_byte(input logic [47:0] m,
                                          input logic [2:0]  i);
    case (i)
      3'd0:    mac_byte = m[47:40];
      3'd1:    mac_byte = m[39:32];
      3'd2:    mac_byte = m[31:24];
      3'd3:    mac_byte = m[23:16];
      3'd4:    mac_byte = m[15:8];
      default: mac_byte = m[7:0];
    endcase
  endfunction

  // tx frame message type / payload size per descriptor kind
  function automatic logic [7:0] kind_mt(input logic [1:0] k);
    case (k)
      TK_RDRESP:  kind_mt = MT_MEM;
      TK_RSTRESP: kind_mt = MT_RST;
      default:    kind_mt = MT_EVT;
    endcase
  endfunction

  function automatic logic [5:0] kind_len(input logic [1:0] k);
    case (k)
      TK_RDRESP:  kind_len = 6'd9;
      TK_RSTRESP: kind_len = 6'd3;
      TK_EVTACK:  kind_len = 6'd4;
      default:    kind_len = 6'd12;
    endcase
  endfunction

  // ------------------------------------------------------------------
  // registers
  // ------------------------------------------------------------------
  logic [47:0] cfg_dmac, cfg_smac;
  // rx
  logic [7:0]  rx_pay [0:PAY_MAX-1];
  logic [6:0]  rx_cnt;              // byte index inside frame (saturating)
  logic [7:0]  rx_et_hi;
  logic [7:0]  rx_mt;
  logic [15:0] rx_psize;
  logic [31:0] rx_crc;
  logic [47:0] rx_sa;               // SMAC of the frame being received
  logic [47:0] rx_smac;             // SMAC of the last accepted message
  logic        rx_da_me, rx_da_bc;  // DMAC matches own MAC / broadcast so far
  logic        rx_drop_et;          // wrong ethertype: silent drop
  logic        rx_bad_rev;          // eCPRI revision != 1
  logic        rx_drop_c;           // concatenated message: drop + irq
  // message state
  logic [15:0] last_pc, last_seq;
  logic        seq_valid;
  logic [7:0]  seq_gap_cnt;
  logic [7:0]  last_event, last_eseq;
  logic [2:0]  last_etype;
  logic [7:0]  rx_ok_cnt, rx_err_cnt;
  // IQ buffer 32x32
  logic [31:0] iq_mem [0:31];
  logic [4:0]  iq_wptr, iq_rptr;
  logic [5:0]  iq_cnt;
  // remote memory 64x32
  logic [31:0] rmem [0:63];
  // tx descriptor fifo (4 deep)
  logic [1:0]  tq_kind [0:3];
  logic [20:0] tq_f [0:3];
  logic [31:0] tq_d [0:3];
  logic [1:0]  tq_wptr, tq_rptr;
  logic [2:0]  tq_cnt;
  // cpu fault injection
  logic        inj_pend;
  logic [20:0] inj_f;
  logic        ack_wait;
  logic [7:0]  ind_id, ind_seq;     // last fault indication sent
  logic [7:0]  tx_seq;
  // tx serializer
  typedef enum logic [1:0] {TX_IDLE, TX_HDR, TX_PAY, TX_FCS} txst_t;
  txst_t       tx_st;
  logic [1:0]  tx_kind;
  logic [20:0] tx_f;
  logic [31:0] tx_dat;
  logic [7:0]  tx_sq;               // seq of the frame being sent
  logic [5:0]  tx_idx;              // byte index within phase
  logic [31:0] tx_crc, tx_fcs;
  // irq sticky bits
  logic        irq_fcs, irq_type, irq_malf, irq_ovf, irq_concat;

  logic        iq_pop;

  assign iq_pop = cpu_re && (cpu_addr == 4'd4) && (iq_cnt != 6'd0);
  assign irq = irq_fcs | irq_type | irq_malf | irq_ovf | irq_concat;

  // ------------------------------------------------------------------
  // RX: byte-stream field capture
  // ------------------------------------------------------------------
  logic        rx_dv_q;
  logic [6:0]  ridx;
  logic [7:0]  own_b;               // own MAC byte at the current DMAC index
  assign ridx  = rx_dv_q ? rx_cnt : 7'd0;
  assign own_b = mac_byte(cfg_smac, ridx[2:0]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_dv_q    <= 1'b0;
      rx_cnt     <= 7'd0;
      rx_et_hi   <= 8'd0;
      rx_mt      <= 8'd0;
      rx_psize   <= 16'd0;
      rx_crc     <= 32'hFFFF_FFFF;
      rx_sa      <= 48'd0;
      rx_da_me   <= 1'b0;
      rx_da_bc   <= 1'b0;
      rx_drop_et <= 1'b0;
      rx_bad_rev <= 1'b0;
      rx_drop_c  <= 1'b0;
    end else begin
      rx_dv_q <= rx_dv;
      if (rx_dv) begin
        rx_cnt <= (ridx == 7'h7F) ? 7'h7F : ridx + 7'd1;
        rx_crc <= crc32_byte((ridx == 7'd0) ? 32'hFFFF_FFFF : rx_crc, rx_d);
        if (ridx < 7'd6) begin
          rx_da_me <= (ridx == 7'd0 || rx_da_me) && (rx_d == own_b);
          rx_da_bc <= (ridx == 7'd0 || rx_da_bc) && (rx_d == 8'hFF);
        end
        case (ridx)
          7'd0    : begin
                      rx_drop_et <= 1'b1;            // until 0xAEFE seen
                      rx_bad_rev <= 1'b0;
                      rx_drop_c  <= 1'b0;
                    end
          7'd6    : rx_sa[47:40] <= rx_d;
          7'd7    : rx_sa[39:32] <= rx_d;
          7'd8    : rx_sa[31:24] <= rx_d;
          7'd9    : rx_sa[23:16] <= rx_d;
          7'd10   : rx_sa[15:8]  <= rx_d;
          7'd11   : rx_sa[7:0]   <= rx_d;
          7'd12   : rx_et_hi       <= rx_d;
          7'd13   : rx_drop_et     <= ({rx_et_hi, rx_d} != ET_ECPRI);
          7'd14   : begin
                      rx_bad_rev <= (rx_d[7:4] != ECPRI_REV[7:4]);
                      rx_drop_c  <= rx_d[0];          // concatenation unsupported
                    end
          7'd15   : rx_mt          <= rx_d;
          7'd16   : rx_psize[15:8] <= rx_d;
          7'd17   : rx_psize[7:0]  <= rx_d;
          default : if (ridx < 7'd58) rx_pay[6'(ridx - 7'd18)] <= rx_d;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // RX: end-of-frame checks + message dispatch
  // ------------------------------------------------------------------
  logic        rx_fend, rx_mine, rx_take;
  logic        len_ok, fcs_ok, msg_ok, msg_malf, mt_known;
  logic [3:0]  iq_nw;
  logic [5:0]  iq_avail;
  logic [3:0]  iq_put;               // words stored: min(iq_nw, iq_avail)
  logic [31:0] raddr;

  assign raddr    = {rx_pay[0], rx_pay[1], rx_pay[2], rx_pay[3]};
  assign rx_fend  = rx_dv_q && !rx_dv;
  assign rx_mine  = (rx_da_me || rx_da_bc) && !rx_drop_et;
  assign len_ok   = (rx_cnt == FRAME_LEN) && (rx_psize <= 16'd40);
  assign fcs_ok   = (rx_crc == CRC_RESIDUE);
  assign mt_known = (rx_mt == MT_IQ) || (rx_mt == MT_MEM) ||
                    (rx_mt == MT_RST) || (rx_mt == MT_EVT);
  // payload shape per message type
  always_comb begin
    case (rx_mt)
      MT_IQ:   msg_malf = (rx_psize < 16'd4) || (rx_psize[1:0] != 2'b00) ||
                          (rx_psize > 16'd36);
      MT_MEM:  msg_malf = !((rx_psize == 16'd5 && rx_pay[4] == 8'h00) ||
                            (rx_psize == 16'd9 && rx_pay[4] == 8'h01)) ||
                          (raddr[31:8] != 24'd0) || (raddr[1:0] != 2'b00);
      MT_RST:  msg_malf = (rx_psize < 16'd3) || (rx_pay[2] != 8'h01);
      default: msg_malf = (rx_pay[3] > 8'd4) || (rx_pay[1] > 8'd5) ||
                          (rx_psize != {5'd0, rx_pay[3], 3'b000} + 16'd4);
    endcase
  end
  // frame accepted for dispatch
  assign rx_take = rx_fend && rx_mine && fcs_ok && len_ok && !rx_bad_rev &&
                   !rx_drop_c && mt_known;
  assign msg_ok  = rx_take && !msg_malf;

  assign iq_nw    = rx_psize[5:2] - 4'd1;              // (psize-4)/4
  assign iq_avail = 6'd32 - iq_cnt + {5'd0, iq_pop};
  assign iq_put   = ({2'b00, iq_nw} > iq_avail) ? iq_avail[3:0] : iq_nw;

  // tx descriptor queue push request from rx dispatch
  logic        rx_push;
  logic [1:0]  rx_push_kind;
  logic [16:0] rx_push_f;

  always_comb begin
    rx_push      = 1'b0;
    rx_push_kind = TK_RDRESP;
    rx_push_f    = {11'd0, raddr[7:2]};
    if (msg_ok) begin
      case (rx_mt)
        MT_MEM: rx_push = (rx_pay[4] == 8'h00);
        MT_RST: begin
                  rx_push      = 1'b1;
                  rx_push_kind = TK_RSTRESP;
                  rx_push_f    = {1'b0, rx_pay[0], rx_pay[1]};
                end
        MT_EVT: begin
                  rx_push      = (rx_pay[1] == 8'd0) || (rx_pay[1] == 8'd3);
                  rx_push_kind = TK_EVTACK;
                  rx_push_f    = {rx_pay[1][0], rx_pay[0], rx_pay[2]};
                end
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // RX dispatch + message state + memories (sequential)
  // ------------------------------------------------------------------
  logic tq_pop, tq_full, tq_push, inj_push, inj_load;
  assign tq_full  = (tq_cnt == 3'd4) && !tq_pop;
  assign inj_push = inj_pend && !rx_push && !tq_full;
  assign tq_push  = (rx_push || inj_pend) && !tq_full;
  assign inj_load = cpu_we && (cpu_addr == 4'd7);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_dmac    <= 48'hAABB_CCDD_EEFF;
      cfg_smac    <= 48'h1122_3344_5566;
      last_pc     <= 16'd0;
      last_seq    <= 16'd0;
      seq_valid   <= 1'b0;
      seq_gap_cnt <= 8'd0;
      last_event  <= 8'd0;
      last_etype  <= 3'd0;
      last_eseq   <= 8'd0;
      rx_ok_cnt   <= 8'd0;
      rx_err_cnt  <= 8'd0;
      reset_op    <= 16'd0;
      rx_smac     <= 48'd0;
      iq_wptr     <= 5'd0;
      iq_rptr     <= 5'd0;
      iq_cnt      <= 6'd0;
      tq_wptr     <= 2'd0;
      tq_cnt      <= 3'd0;
      inj_pend    <= 1'b0;
      inj_f       <= 21'd0;
      ack_wait    <= 1'b0;
      irq_fcs     <= 1'b0;
      irq_type    <= 1'b0;
      irq_malf    <= 1'b0;
      irq_ovf     <= 1'b0;
      irq_concat  <= 1'b0;
      for (int i = 0; i < 64; i++) rmem[i] <= 32'd0;
    end else begin
      // ---------------- cpu writes
      if (cpu_we) begin
        case (cpu_addr)
          4'd0   : cfg_dmac[31:0]  <= cpu_wdata;
          4'd1   : cfg_dmac[47:32] <= cpu_wdata[15:0];
          4'd2   : cfg_smac[31:0]  <= cpu_wdata;
          4'd3   : cfg_smac[47:32] <= cpu_wdata[15:0];
          4'd8   : begin
                     if (cpu_wdata[0]) irq_fcs    <= 1'b0;
                     if (cpu_wdata[1]) irq_type   <= 1'b0;
                     if (cpu_wdata[2]) irq_malf   <= 1'b0;
                     if (cpu_wdata[3]) irq_ovf    <= 1'b0;
                     if (cpu_wdata[4]) irq_concat <= 1'b0;
                   end
          4'd9   : if (cpu_wdata[0]) reset_op <= 16'd0;
          default: ;
        endcase
      end
      // ---------------- IQ buffer pop
      if (iq_pop) iq_rptr <= iq_rptr + 5'd1;
      // ---------------- end-of-frame handling
      if (rx_fend && rx_mine) begin
        if (!fcs_ok)                 irq_fcs    <= 1'b1;
        else if (!len_ok || rx_bad_rev) irq_malf <= 1'b1;
        else if (rx_drop_c)          irq_concat <= 1'b1;
        else if (!mt_known)          irq_type   <= 1'b1;
        else if (msg_malf)           irq_malf   <= 1'b1;
        if (msg_ok) rx_ok_cnt  <= rx_ok_cnt + 8'd1;
        else        rx_err_cnt <= rx_err_cnt + 8'd1;
      end
      if (msg_ok) begin
        rx_smac <= rx_sa;
        case (rx_mt)
          // ---------------- msgtype 0: IQ data
          MT_IQ: begin
            for (int w = 0; w < 8; w++)
              if (w < iq_put)
                iq_mem[iq_wptr + w[4:0]] <= {rx_pay[4+4*w], rx_pay[5+4*w],
                                             rx_pay[6+4*w], rx_pay[7+4*w]};
            if ({2'b00, iq_nw} > iq_avail) irq_ovf <= 1'b1;
            iq_wptr <= iq_wptr + {1'b0, iq_put};
            // seq_id tracking
            if (seq_valid && ({rx_pay[0], rx_pay[1]} == last_pc) &&
                ({rx_pay[2], rx_pay[3]} != (last_seq + 16'd1)))
              seq_gap_cnt <= seq_gap_cnt + 8'd1;
            last_pc   <= {rx_pay[0], rx_pay[1]};
            last_seq  <= {rx_pay[2], rx_pay[3]};
            seq_valid <= 1'b1;
          end
          // ---------------- msgtype 4: memory write (reads answer via tq)
          MT_MEM: if (rx_pay[4] == 8'h01)
                    rmem[raddr[7:2]] <= {rx_pay[5], rx_pay[6], rx_pay[7], rx_pay[8]};
          // ---------------- msgtype 5: remote reset request
          MT_RST: reset_op <= {rx_pay[0], rx_pay[1]};
          // ---------------- msgtype 6: event indication
          default: begin
            last_event <= rx_pay[0];
            last_etype <= rx_pay[1][2:0];
            last_eseq  <= rx_pay[2];
            if (rx_pay[1] == 8'd1 && rx_pay[0] == ind_id && rx_pay[2] == ind_seq)
              ack_wait <= 1'b0;
          end
        endcase
      end
      // ---------------- tx descriptor queue push (rx has priority)
      if (tq_push) begin
        tq_kind[tq_wptr] <= rx_push ? rx_push_kind : TK_EVTIND;
        tq_f[tq_wptr]    <= rx_push ? {4'd0, rx_push_f} : inj_f;
        tq_d[tq_wptr]    <= rmem[raddr[7:2]];
        tq_wptr          <= tq_wptr + 2'd1;
      end
      if (rx_push && tq_full) irq_ovf <= 1'b1;   // response lost
      // ---------------- cpu fault injection (one pending)
      if (inj_load) begin
        if (inj_pend && !inj_push) irq_ovf <= 1'b1;   // previous one pending
        else begin
          inj_pend <= 1'b1;
          inj_f    <= cpu_wdata[20:0];
        end
      end else if (inj_push) begin
        inj_pend <= 1'b0;
      end
      if (tq_pop && tq_kind[tq_rptr] == TK_EVTIND) ack_wait <= 1'b1;
      // ---------------- queue count
      case ({tq_push, tq_pop})
        2'b10  : tq_cnt <= tq_cnt + 3'd1;
        2'b01  : tq_cnt <= tq_cnt - 3'd1;
        default: ;
      endcase
      // ---------------- IQ count
      iq_cnt <= iq_cnt - {5'd0, iq_pop} +
                ((msg_ok && rx_mt == MT_IQ) ? {2'b00, iq_put} : 6'd0);
    end
  end

  // ------------------------------------------------------------------
  // TX: frame serializer (DMAC/SMAC/ET/eCPRI header/payload/pad/FCS)
  // ------------------------------------------------------------------
  logic [7:0] tx_hdr_byte, tx_pay_byte;

  // a frame starts only after tx_en has been low for a cycle (frame delimiter)
  assign tq_pop = (tx_st == TX_IDLE) && !tx_en && (tq_cnt != 3'd0);

  always_comb begin
    case (tx_idx[4:0])
      5'd0   : tx_hdr_byte = cfg_dmac[47:40];
      5'd1   : tx_hdr_byte = cfg_dmac[39:32];
      5'd2   : tx_hdr_byte = cfg_dmac[31:24];
      5'd3   : tx_hdr_byte = cfg_dmac[23:16];
      5'd4   : tx_hdr_byte = cfg_dmac[15:8];
      5'd5   : tx_hdr_byte = cfg_dmac[7:0];
      5'd6   : tx_hdr_byte = cfg_smac[47:40];
      5'd7   : tx_hdr_byte = cfg_smac[39:32];
      5'd8   : tx_hdr_byte = cfg_smac[31:24];
      5'd9   : tx_hdr_byte = cfg_smac[23:16];
      5'd10  : tx_hdr_byte = cfg_smac[15:8];
      5'd11  : tx_hdr_byte = cfg_smac[7:0];
      5'd12  : tx_hdr_byte = ET_ECPRI[15:8];
      5'd13  : tx_hdr_byte = ET_ECPRI[7:0];
      5'd14  : tx_hdr_byte = ECPRI_REV;
      5'd15  : tx_hdr_byte = kind_mt(tx_kind);
      5'd16  : tx_hdr_byte = 8'h00;
      default: tx_hdr_byte = {2'b00, kind_len(tx_kind)};
    endcase
  end

  always_comb begin
    tx_pay_byte = 8'h00;                         // pad beyond payload
    case (tx_kind)
      TK_RDRESP:
        case (tx_idx)
          6'd3   : tx_pay_byte = {tx_f[5:0], 2'b00};
          6'd4   : tx_pay_byte = 8'h02;          // read response
          6'd5   : tx_pay_byte = tx_dat[31:24];
          6'd6   : tx_pay_byte = tx_dat[23:16];
          6'd7   : tx_pay_byte = tx_dat[15:8];
          6'd8   : tx_pay_byte = tx_dat[7:0];
          default: ;
        endcase
      TK_RSTRESP:
        case (tx_idx)
          6'd0   : tx_pay_byte = tx_f[15:8];
          6'd1   : tx_pay_byte = tx_f[7:0];
          6'd2   : tx_pay_byte = 8'h02;          // reset response
          default: ;
        endcase
      TK_EVTACK:
        case (tx_idx)
          6'd0   : tx_pay_byte = tx_f[15:8];
          6'd1   : tx_pay_byte = tx_f[16] ? 8'd4 : 8'd1;
          6'd2   : tx_pay_byte = tx_f[7:0];
          default: ;
        endcase
      default:                                   // TK_EVTIND
        case (tx_idx)
          6'd0   : tx_pay_byte = tx_f[7:0];
          6'd2   : tx_pay_byte = tx_sq;
          6'd3   : tx_pay_byte = 8'h01;          // one element
          6'd4, 6'd5 : tx_pay_byte = 8'hFF;      // element id: all
          6'd6   : tx_pay_byte = {3'b000, tx_f[20], tx_f[19:16]};
          6'd7   : tx_pay_byte = tx_f[15:8];
          default: ;
        endcase
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_st   <= TX_IDLE;
      tx_en   <= 1'b0;
      tx_d    <= 8'd0;
      tx_idx  <= 6'd0;
      tx_crc  <= 32'd0;
      tx_fcs  <= 32'd0;
      tx_kind <= TK_RDRESP;
      tx_f    <= 21'd0;
      tx_dat  <= 32'd0;
      tx_sq   <= 8'd0;
      tx_seq  <= 8'd0;
      ind_id  <= 8'd0;
      ind_seq <= 8'd0;
      tq_rptr <= 2'd0;
    end else begin
      case (tx_st)
        TX_IDLE: begin
          tx_en <= 1'b0;
          if (tq_pop) begin
            tx_kind <= tq_kind[tq_rptr];
            tx_f    <= tq_f[tq_rptr];
            tx_dat  <= tq_d[tq_rptr];
            tq_rptr <= tq_rptr + 2'd1;
            if (tq_kind[tq_rptr] == TK_EVTIND) begin
              tx_sq   <= tx_seq;
              tx_seq  <= tx_seq + 8'd1;
              ind_id  <= tq_f[tq_rptr][7:0];
              ind_seq <= tx_seq;
            end
            tx_d    <= cfg_dmac[47:40];
            tx_en   <= 1'b1;
            tx_crc  <= crc32_byte(32'hFFFF_FFFF, cfg_dmac[47:40]);
            tx_idx  <= 6'd1;
            tx_st   <= TX_HDR;
          end
        end
        TX_HDR: begin
          tx_d   <= tx_hdr_byte;
          tx_crc <= crc32_byte(tx_crc, tx_hdr_byte);
          tx_idx <= (tx_idx == 6'd17) ? 6'd0 : tx_idx + 6'd1;
          if (tx_idx == 6'd17) tx_st <= TX_PAY;
        end
        TX_PAY: begin                            // payload + pad, 42 bytes
          tx_d   <= tx_pay_byte;
          tx_crc <= crc32_byte(tx_crc, tx_pay_byte);
          tx_idx <= (tx_idx == 6'd41) ? 6'd0 : tx_idx + 6'd1;
          if (tx_idx == 6'd41) begin
            tx_fcs <= ~crc32_byte(tx_crc, tx_pay_byte);
            tx_st  <= TX_FCS;
          end
        end
        default: begin  // TX_FCS
          tx_d   <= tx_fcs[8*tx_idx[1:0] +: 8];
          tx_idx <= tx_idx + 6'd1;
          // last FCS byte is on the line next cycle; TX_IDLE drops tx_en
          if (tx_idx[1:0] == 2'd3) begin
            tx_idx <= 6'd0;
            tx_st  <= TX_IDLE;
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // cpu read mux
  // ------------------------------------------------------------------
  always_comb begin
    case (cpu_addr)
      4'd0   : cpu_rdata = cfg_dmac[31:0];
      4'd1   : cpu_rdata = {16'h0, cfg_dmac[47:32]};
      4'd2   : cpu_rdata = cfg_smac[31:0];
      4'd3   : cpu_rdata = {16'h0, cfg_smac[47:32]};
      4'd4   : cpu_rdata = iq_mem[iq_rptr];
      4'd5   : cpu_rdata = {rx_err_cnt, rx_ok_cnt, seq_gap_cnt, 2'b00, iq_cnt};
      4'd6   : cpu_rdata = {last_pc, last_seq};
      4'd7   : cpu_rdata = {8'h0, last_eseq, 5'h0, last_etype, last_event};
      4'd8   : cpu_rdata = {27'h0, irq_concat, irq_ovf, irq_malf,
                            irq_type, irq_fcs};
      4'd9   : cpu_rdata = {16'h0, reset_op};
      4'd10  : cpu_rdata = rx_smac[31:0];
      4'd11  : cpu_rdata = {16'h0, rx_smac[47:32]};
      4'd12  : cpu_rdata = {14'h0, ack_wait, inj_pend, tx_seq, 5'h0, tq_cnt};
      default: cpu_rdata = 32'h0;
    endcase
  end

endmodule
