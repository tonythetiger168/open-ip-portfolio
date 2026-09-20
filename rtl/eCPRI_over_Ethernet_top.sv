// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// eCPRI over Ethernet -- eCPRI message layer slice (node side)
//   - Ethernet frame parse/generate: DMAC + SMAC + Ethertype 0xAEFE +
//     payload + FCS (CRC-32/ISO-HDLC reflected, init/xorout 0xFFFFFFFF,
//     FCS sent LSB-byte first; rx residue check == 0xDEBB20E3).
//     Preamble/SFD/IFG are handled by the external MAC (byte stream i/f).
//   - eCPRI common header {rev[4],rsvd[3],c[1], msgtype[8], payload_size[16]}
//   - msgtype 0: IQ data -- pc_id[16] + seq_id[16] + IQ bytes (<=32B, must be
//     a multiple of 4) packed big-endian into a 32x32 IQ buffer (cpu pop);
//     seq_id gap tracking per link
//   - msgtype 4: generic memory transfer -- remote_addr[32] + rw[8]
//     (1=write + data[32], 0=read) against a 64x32 memory; read triggers a
//     response frame (rw=2) with the memory content
//   - msgtype 5: remote reset request -- reset_op[16] drives the reset_op
//     output + response frame echoing reset_op
//   - msgtype 6: event indication -- event_id[8] + ack_req[8]; ack_req!=0
//     triggers an event ACK frame; cpu fault-injection register emits an
//     event indication frame
//   - FCS-bad frames dropped + irq; unknown msgtype / malformed payload /
//     concatenated messages (c=1) dropped + irq
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module eCPRI_over_Ethernet_top #(
  parameter int DW = 32,             // cpu data width
  parameter int AW = 32              // kept for framework compatibility
)(
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
  input  logic [DW-1:0] cpu_wdata,
  output logic [DW-1:0] cpu_rdata,
  output logic        irq
);

  localparam logic [15:0] ET_ECPRI   = 16'hAEFE;
  localparam logic [7:0]  ECPRI_REV  = 8'h10;      // rev=1, c=0
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB20E3;
  localparam int          PAY_MAX    = 40;         // max supported payload

  // message types
  localparam logic [7:0] MT_IQ   = 8'd0;
  localparam logic [7:0] MT_MEM  = 8'd4;
  localparam logic [7:0] MT_RST  = 8'd5;
  localparam logic [7:0] MT_EVT  = 8'd6;

  // tx descriptor kinds
  localparam logic [1:0] TK_RDRESP = 2'd0;   // a=addr, b=data
  localparam logic [1:0] TK_RSTRESP = 2'd1;  // a={16'h0,reset_op}
  localparam logic [1:0] TK_EVTACK = 2'd2;   // a={24'h0,event_id}
  localparam logic [1:0] TK_EVTIND = 2'd3;   // a={24'h0,event_id}

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

  // ------------------------------------------------------------------
  // registers
  // ------------------------------------------------------------------
  logic [47:0] cfg_dmac, cfg_smac;
  // rx
  logic [7:0]  rx_pay [0:PAY_MAX-1];
  logic [7:0]  rx_cnt;              // byte index inside frame
  logic [15:0] rx_et;
  logic [7:0]  rx_hdr0, rx_mt;
  logic [15:0] rx_psize;
  logic [31:0] rx_crc;
  logic [47:0] rx_smac;
  logic        rx_drop_et;          // wrong ethertype: silent drop
  logic        rx_drop_c;           // concatenated message: drop + irq
  // message state
  logic [15:0] last_pc, last_seq;
  logic        seq_valid;
  logic [7:0]  seq_gap_cnt;
  logic [7:0]  last_event;
  logic [7:0]  rx_ok_cnt, rx_err_cnt;
  // IQ buffer 32x32
  logic [31:0] iq_mem [0:31];
  logic [4:0]  iq_wptr, iq_rptr;
  logic [5:0]  iq_cnt;
  // remote memory 64x32
  logic [31:0] rmem [0:63];
  // tx descriptor fifo (4 deep)
  logic [1:0]  tq_kind [0:3];
  logic [31:0] tq_a [0:3];
  logic [31:0] tq_b [0:3];
  logic [2:0]  tq_wptr, tq_rptr, tq_cnt;
  // tx serializer
  typedef enum logic [2:0] {TX_IDLE, TX_HDR, TX_PAY, TX_FCS} txst_t;
  txst_t       tx_st;
  logic [1:0]  tx_kind;
  logic [31:0] tx_a, tx_b;
  logic [4:0]  tx_idx;              // byte index within phase
  logic [4:0]  tx_plen;             // payload length
  logic [31:0] tx_crc, tx_fcs;
  logic [7:0]  tx_mt;
  // irq sticky bits
  logic        irq_fcs, irq_type, irq_malf, irq_ovf, irq_concat;

  logic        iq_pop;

  assign iq_pop = cpu_re && (cpu_addr == 4'd4) && (iq_cnt != 6'd0);
  assign irq = irq_fcs | irq_type | irq_malf | irq_ovf | irq_concat;

  // ------------------------------------------------------------------
  // RX: byte-stream field capture
  // ------------------------------------------------------------------
  logic        rx_dv_q;
  logic [7:0]  ridx;
  assign ridx = rx_dv_q ? rx_cnt : 8'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_dv_q  <= 1'b0;
      rx_cnt   <= 8'd0;
      rx_et    <= 16'd0;
      rx_hdr0  <= 8'd0;
      rx_mt    <= 8'd0;
      rx_psize <= 16'd0;
      rx_crc   <= 32'hFFFF_FFFF;
      rx_smac  <= 48'd0;
      rx_drop_et <= 1'b0;
      rx_drop_c  <= 1'b0;
    end else begin
      rx_dv_q <= rx_dv;
      if (rx_dv) begin
        rx_cnt <= (ridx == 8'hFF) ? 8'hFF : ridx + 8'd1;
        rx_crc <= (ridx == 8'd0) ? crc32_byte(32'hFFFF_FFFF, rx_d)
                                 : crc32_byte(rx_crc, rx_d);
        case (ridx)
          8'd0    : begin rx_drop_et <= 1'b0; rx_drop_c <= 1'b0; end
          8'd6    : rx_smac[47:40] <= rx_d;
          8'd7    : rx_smac[39:32] <= rx_d;
          8'd8    : rx_smac[31:24] <= rx_d;
          8'd9    : rx_smac[23:16] <= rx_d;
          8'd10   : rx_smac[15:8]  <= rx_d;
          8'd11   : rx_smac[7:0]   <= rx_d;
          8'd12   : rx_et[15:8]    <= rx_d;
          8'd13   : begin
                      rx_et[7:0] <= rx_d;
                      if ({rx_et[15:8], rx_d} != ET_ECPRI)
                        rx_drop_et <= 1'b1;          // not eCPRI: silent drop
                    end
          8'd14   : begin
                      rx_hdr0 <= rx_d;
                      if (rx_d[0]) rx_drop_c <= 1'b1; // concatenation unsupported
                    end
          8'd15   : rx_mt            <= rx_d;
          8'd16   : rx_psize[15:8]   <= rx_d;
          8'd17   : rx_psize[7:0]    <= rx_d;
          default : begin
                      if ((ridx - 8'd18) < 8'd40)
                        rx_pay[ridx - 8'd18] <= rx_d;
                    end
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // RX: end-of-frame checks + message dispatch
  // ------------------------------------------------------------------
  logic        rx_fend;
  logic        len_ok, fcs_ok, frame_ok, psize_malf;
  logic [3:0]  iq_nw;
  logic [5:0]  iq_avail;

  assign rx_fend  = rx_dv_q && !rx_dv;
  assign len_ok   = ({9'd0, rx_cnt} == (17'd22 + {1'b0, rx_psize})) &&
                    (rx_psize <= 16'd40);
  assign fcs_ok   = (rx_crc == CRC_RESIDUE);
  assign frame_ok = rx_fend && !rx_drop_et && !rx_drop_c && len_ok && fcs_ok;
  // payload-size sanity per message type
  assign psize_malf = (rx_mt == MT_IQ)  ? ((rx_psize < 16'd4) || (rx_psize[1:0] != 2'b00) ||
                                           (rx_psize > 16'd36)) :
                      (rx_mt == MT_MEM) ? !((rx_psize == 16'd5) || (rx_psize == 16'd9)) :
                      (rx_mt == MT_RST) ? (rx_psize < 16'd2) :
                      (rx_mt == MT_EVT) ? (rx_psize < 16'd2) : 1'b0;
  assign iq_nw    = {2'b00, rx_psize[5:2]} - 4'd1;   // (psize-4)/4, psize%4==0
  assign iq_avail = 6'd32 - iq_cnt + {5'd0, iq_pop};

  // tx descriptor queue push request from rx dispatch
  logic        rx_push;
  logic [1:0]  rx_push_kind;
  logic [31:0] rx_push_a, rx_push_b;
  logic [31:0] raddr;
  assign raddr = {rx_pay[0], rx_pay[1], rx_pay[2], rx_pay[3]};

  always_comb begin
    rx_push      = 1'b0;
    rx_push_kind = TK_RDRESP;
    rx_push_a    = 32'd0;
    rx_push_b    = 32'd0;
    if (frame_ok && !psize_malf) begin
      case (rx_mt)
        MT_MEM: if (rx_psize == 16'd5 && rx_pay[4] == 8'h00) begin
                  rx_push      = 1'b1;
                  rx_push_kind = TK_RDRESP;
                  rx_push_a    = raddr;
                  rx_push_b    = rmem[raddr[7:2]];
                end
        MT_RST: begin
                  rx_push      = 1'b1;
                  rx_push_kind = TK_RSTRESP;
                  rx_push_a    = {16'h0, rx_pay[0], rx_pay[1]};
                end
        MT_EVT: if (rx_pay[1] != 8'h00) begin
                  rx_push      = 1'b1;
                  rx_push_kind = TK_EVTACK;
                  rx_push_a    = {24'h0, rx_pay[0]};
                end
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // RX dispatch + message state + memories (sequential)
  // ------------------------------------------------------------------
  logic        cpu_push;
  logic        tq_pop;
  logic        iq_push;
  assign iq_push = frame_ok && !psize_malf && (rx_mt == MT_IQ);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_dmac    <= 48'hAABB_CCDD_EEFF;
      cfg_smac    <= 48'h1122_3344_5566;
      last_pc     <= 16'd0;
      last_seq    <= 16'd0;
      seq_valid   <= 1'b0;
      seq_gap_cnt <= 8'd0;
      last_event  <= 8'd0;
      rx_ok_cnt   <= 8'd0;
      rx_err_cnt  <= 8'd0;
      reset_op    <= 16'd0;
      iq_wptr     <= 5'd0;
      iq_rptr     <= 5'd0;
      iq_cnt      <= 6'd0;
      tq_wptr     <= 3'd0;
      tq_rptr     <= 3'd0;
      tq_cnt      <= 3'd0;
      irq_fcs     <= 1'b0;
      irq_type    <= 1'b0;
      irq_malf    <= 1'b0;
      irq_ovf     <= 1'b0;
      irq_concat  <= 1'b0;
      for (int i = 0; i < 64; i++) rmem[i] <= 32'd0;
    end else begin
      // ---------------- cpu writes
      cpu_push = 1'b0;
      if (cpu_we) begin
        case (cpu_addr)
          4'd0   : cfg_dmac[31:0]  <= cpu_wdata;
          4'd1   : cfg_dmac[47:32] <= cpu_wdata[15:0];
          4'd2   : cfg_smac[31:0]  <= cpu_wdata;
          4'd3   : cfg_smac[47:32] <= cpu_wdata[15:0];
          4'd7   : cpu_push = 1'b1;              // fault event injection
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
      if (rx_fend) begin
        if (rx_drop_c) begin
          irq_concat <= 1'b1;
          rx_err_cnt <= rx_err_cnt + 8'd1;
        end else if (!rx_drop_et) begin
          if (!fcs_ok) begin
            irq_fcs    <= 1'b1;
            rx_err_cnt <= rx_err_cnt + 8'd1;
          end else if (!len_ok) begin
            irq_malf   <= 1'b1;
            rx_err_cnt <= rx_err_cnt + 8'd1;
          end else if (psize_malf) begin
            irq_malf   <= 1'b1;
            rx_err_cnt <= rx_err_cnt + 8'd1;
          end else begin
            case (rx_mt)
              // ---------------- msgtype 0: IQ data
              MT_IQ: begin
                for (int w = 0; w < 8; w++) begin
                  if ((w[3:0] < iq_nw) && ({2'b00, w} < iq_avail)) begin
                    iq_mem[iq_wptr + w[4:0]] <= {rx_pay[4+4*w], rx_pay[5+4*w],
                                                 rx_pay[6+4*w], rx_pay[7+4*w]};
                  end
                end
                if ({2'b00, iq_nw} > iq_avail) irq_ovf <= 1'b1;
                iq_wptr <= iq_wptr +
                           (({2'b00, iq_nw} > iq_avail) ? iq_avail[4:0]
                                                          : {1'b0, iq_nw});
                // seq_id tracking
                if (seq_valid && ({rx_pay[0], rx_pay[1]} == last_pc) &&
                    ({rx_pay[2], rx_pay[3]} != (last_seq + 16'd1)))
                  seq_gap_cnt <= seq_gap_cnt + 8'd1;
                last_pc   <= {rx_pay[0], rx_pay[1]};
                last_seq  <= {rx_pay[2], rx_pay[3]};
                seq_valid <= 1'b1;
                rx_ok_cnt <= rx_ok_cnt + 8'd1;
              end
              // ---------------- msgtype 4: memory transfer
              MT_MEM: begin
                if (rx_psize == 16'd9 && rx_pay[4] == 8'h01) begin
                  rmem[raddr[7:2]] <= {rx_pay[5], rx_pay[6], rx_pay[7], rx_pay[8]};
                  rx_ok_cnt <= rx_ok_cnt + 8'd1;
                end else if (rx_psize == 16'd5 && rx_pay[4] == 8'h00) begin
                  rx_ok_cnt <= rx_ok_cnt + 8'd1;
                end else begin
                  irq_malf   <= 1'b1;
                  rx_err_cnt <= rx_err_cnt + 8'd1;
                end
              end
              // ---------------- msgtype 5: remote reset
              MT_RST: begin
                reset_op  <= {rx_pay[0], rx_pay[1]};
                rx_ok_cnt <= rx_ok_cnt + 8'd1;
              end
              // ---------------- msgtype 6: event indication
              MT_EVT: begin
                last_event <= rx_pay[0];
                rx_ok_cnt  <= rx_ok_cnt + 8'd1;
              end
              // ---------------- unknown message type
              default: begin
                irq_type   <= 1'b1;
                rx_err_cnt <= rx_err_cnt + 8'd1;
              end
            endcase
          end
        end
      end
      // ---------------- tx descriptor queue push (rx has priority)
      if ((rx_push || cpu_push) && !(tq_cnt == 3'd4 && !tq_pop)) begin
        if (rx_push) begin
          tq_kind[tq_wptr[1:0]] <= rx_push_kind;
          tq_a[tq_wptr[1:0]]    <= rx_push_a;
          tq_b[tq_wptr[1:0]]    <= rx_push_b;
        end else begin
          tq_kind[tq_wptr[1:0]] <= TK_EVTIND;
          tq_a[tq_wptr[1:0]]    <= {24'h0, cpu_wdata[7:0]};
          tq_b[tq_wptr[1:0]]    <= 32'd0;
        end
        tq_wptr <= tq_wptr + 3'd1;
      end else if (cpu_push) begin
        irq_ovf <= 1'b1;                       // injection dropped, queue full
      end
      // ---------------- queue count
      case ({((rx_push || cpu_push) && !(tq_cnt == 3'd4 && !tq_pop)), tq_pop})
        2'b10  : tq_cnt <= tq_cnt + 3'd1;
        2'b01  : tq_cnt <= tq_cnt - 3'd1;
        default: tq_cnt <= tq_cnt;
      endcase
      // ---------------- IQ count (push_eff = min(iq_nw, iq_avail))
      if (iq_push) begin
        iq_cnt <= iq_cnt - {5'd0, iq_pop} +
                  (({2'b00, iq_nw} > iq_avail) ? iq_avail
                                               : {2'b00, iq_nw});
      end else if (iq_pop) begin
        iq_cnt <= iq_cnt - 6'd1;
      end
    end
  end

  // ------------------------------------------------------------------
  // TX: frame serializer (DMAC/SMAC/ET/eCPRI header/payload/FCS)
  // ------------------------------------------------------------------
  logic [7:0] tx_hdr_byte, tx_pay_byte;

  assign tq_pop = (tx_st == TX_IDLE) && (tq_cnt != 3'd0);

  always_comb begin
    case (tx_idx)
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
      5'd15  : tx_hdr_byte = tx_mt;
      5'd16  : tx_hdr_byte = 8'h00;
      default: tx_hdr_byte = {3'b000, tx_plen};
    endcase
  end

  always_comb begin
    tx_pay_byte = 8'h00;
    case (tx_kind)
      TK_RDRESP: begin
        case (tx_idx)
          5'd0   : tx_pay_byte = tx_a[31:24];
          5'd1   : tx_pay_byte = tx_a[23:16];
          5'd2   : tx_pay_byte = tx_a[15:8];
          5'd3   : tx_pay_byte = tx_a[7:0];
          5'd4   : tx_pay_byte = 8'h02;               // read response
          5'd5   : tx_pay_byte = tx_b[31:24];
          5'd6   : tx_pay_byte = tx_b[23:16];
          5'd7   : tx_pay_byte = tx_b[15:8];
          default: tx_pay_byte = tx_b[7:0];
        endcase
      end
      TK_RSTRESP: tx_pay_byte = (tx_idx == 5'd0) ? tx_a[15:8] : tx_a[7:0];
      default   : tx_pay_byte = (tx_idx == 5'd0) ? tx_a[7:0] : 8'h01;
      // TK_EVTACK: {event_id, ack=1} / TK_EVTIND: {event_id, ack_req=1}
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_st   <= TX_IDLE;
      tx_en   <= 1'b0;
      tx_d    <= 8'd0;
      tx_idx  <= 5'd0;
      tx_crc  <= 32'd0;
      tx_fcs  <= 32'd0;
      tx_kind <= TK_RDRESP;
      tx_a    <= 32'd0;
      tx_b    <= 32'd0;
      tx_mt   <= 8'd0;
      tx_plen <= 5'd0;
      tq_rptr <= 3'd0;
    end else begin
      case (tx_st)
        TX_IDLE: begin
          tx_en <= 1'b0;
          if (tq_cnt != 3'd0) begin
            tx_kind <= tq_kind[tq_rptr[1:0]];
            tx_a    <= tq_a[tq_rptr[1:0]];
            tx_b    <= tq_b[tq_rptr[1:0]];
            tq_rptr <= tq_rptr + 3'd1;
            case (tq_kind[tq_rptr[1:0]])
              TK_RDRESP: begin tx_mt <= MT_MEM; tx_plen <= 5'd9; end
              TK_RSTRESP: begin tx_mt <= MT_RST; tx_plen <= 5'd2; end
              default   : begin tx_mt <= MT_EVT; tx_plen <= 5'd2; end
            endcase
            tx_d    <= cfg_dmac[47:40];
            tx_en   <= 1'b1;
            tx_crc  <= crc32_byte(32'hFFFF_FFFF, cfg_dmac[47:40]);
            tx_idx  <= 5'd1;
            tx_st   <= TX_HDR;
          end
        end
        TX_HDR: begin
          tx_d   <= tx_hdr_byte;
          tx_crc <= crc32_byte(tx_crc, tx_hdr_byte);
          if (tx_idx == 5'd17) begin
            tx_idx <= 5'd0;
            tx_st  <= TX_PAY;
          end else begin
            tx_idx <= tx_idx + 5'd1;
          end
        end
        TX_PAY: begin
          tx_d   <= tx_pay_byte;
          tx_crc <= crc32_byte(tx_crc, tx_pay_byte);
          if (tx_idx == (tx_plen - 5'd1)) begin
            tx_fcs <= ~crc32_byte(tx_crc, tx_pay_byte);
            tx_idx <= 5'd0;
            tx_st  <= TX_FCS;
          end else begin
            tx_idx <= tx_idx + 5'd1;
          end
        end
        default: begin  // TX_FCS
          case (tx_idx)
            5'd0   : tx_d <= tx_fcs[7:0];
            5'd1   : tx_d <= tx_fcs[15:8];
            5'd2   : tx_d <= tx_fcs[23:16];
            default: tx_d <= tx_fcs[31:24];
          endcase
          if (tx_idx == 5'd3) begin
            // last FCS byte is on the line next cycle; TX_IDLE drops tx_en
            tx_idx <= 5'd0;
            tx_st  <= TX_IDLE;
          end else begin
            tx_idx <= tx_idx + 5'd1;
          end
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // cpu read mux
  // ------------------------------------------------------------------
  always_comb begin
    cpu_rdata = 32'h0;
    case (cpu_addr)
      4'd0   : cpu_rdata = cfg_dmac[31:0];
      4'd1   : cpu_rdata = {16'h0, cfg_dmac[47:32]};
      4'd2   : cpu_rdata = cfg_smac[31:0];
      4'd3   : cpu_rdata = {16'h0, cfg_smac[47:32]};
      4'd4   : cpu_rdata = iq_mem[iq_rptr];
      4'd5   : cpu_rdata = {rx_err_cnt, rx_ok_cnt, seq_gap_cnt, 2'b00, iq_cnt};
      4'd6   : cpu_rdata = {last_pc, last_seq};
      4'd7   : cpu_rdata = {24'h0, last_event};
      4'd8   : cpu_rdata = {27'h0, irq_concat, irq_ovf, irq_malf,
                            irq_type, irq_fcs};
      4'd9   : cpu_rdata = {16'h0, reset_op};
      4'd10  : cpu_rdata = rx_smac[31:0];
      default: cpu_rdata = 32'h0;
    endcase
  end

endmodule
