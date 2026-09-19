// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CPRI v8.0 (eCPRI over CPR) -- CPRI master (REC) link-layer slice
//   - full 8b/10b encode/decode: all D0.0..D31.7 + K28.x, running disparity
//     (symbol = {a,b,c,d,e,i,f,g,h,j}, 'a' transmitted first, 1 symbol/clk)
//   - basic frame = 1 control word + 15 IQ words (16 bytes)
//   - hyperframe = 64 basic frames (simplified from 256 -- educational slice)
//   - sync FSM: master sends K28.5+0x50+0x50 at hyperframe start, peer RE
//     replies with K28.5; HUNT -> ALIGN (2 well-placed commas) -> SYNC,
//     rx phase locks onto the peer hyperframe
//   - control word slots: #0 sync (K28.5), #1 L1 inband (16-hyperframe slow
//     stream carrying rate / pointer-p / protocol-version negotiation),
//     #4 vendor byte
//   - IQ data: peer 16-bit I/Q interleaved byte stream packed into 32x32
//     buffer as {I[15:0],Q[15:0]} words, cpu port pop
//   - 8x8 rate config registers (cpu port)
//   - loss of sync: 4 consecutive hyperframes without peer K28.5 at the
//     expected position -> resync (HUNT) + irq
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module CPRI_v8_0__eCPRI_over_CPR__top #(
  parameter int DW = 32,             // cpu data width
  parameter int AW = 32              // kept for framework compatibility
)(
  input  logic        clk,
  input  logic        rst_n,
  // CPRI line, one 10-bit 8b/10b symbol per clock
  input  logic [9:0]  rx_sym,
  output logic [9:0]  tx_sym,
  // cpu port
  input  logic        cpu_we,
  input  logic        cpu_re,
  input  logic [3:0]  cpu_addr,
  input  logic [DW-1:0] cpu_wdata,
  output logic [DW-1:0] cpu_rdata,
  output logic        irq
);

  localparam logic [7:0] K28_5 = 8'hBC;   // comma / sync control word
  localparam logic [7:0] L1_SOM = 8'h5A;  // L1 inband slow-stream start mark

  typedef enum logic [1:0] {ST_HUNT, ST_ALIGN, ST_SYNC} state_t;
  state_t sync_st;

  // ------------------------------------------------------------------
  // disparity helpers: 6b block balanced when 3 ones, 4b when 2 ones
  // ------------------------------------------------------------------
  function automatic logic is_bal6(input logic [5:0] c);
    logic [2:0] n;
    begin
      n = {2'b00, c[0]} + {2'b00, c[1]} + {2'b00, c[2]}
        + {2'b00, c[3]} + {2'b00, c[4]} + {2'b00, c[5]};
      is_bal6 = (n == 3'd3);
    end
  endfunction

  function automatic logic is_bal4(input logic [3:0] c);
    logic [2:0] n;
    begin
      n = {2'b00, c[0]} + {2'b00, c[1]} + {2'b00, c[2]} + {2'b00, c[3]};
      is_bal4 = (n == 3'd2);
    end
  endfunction

  // ------------------------------------------------------------------
  // 8b/10b encoder. rd: 0 = RD-, 1 = RD+.
  // returns {new_rd, sym[9:0]} with sym[9:4]={a..i}, sym[3:0]={f,g,h,j}
  // ------------------------------------------------------------------
  function automatic logic [10:0] enc8b10b(input logic [7:0] d,
                                           input logic       k,
                                           input logic       rd);
    logic [5:0] c6;
    logic [3:0] c4;
    logic       rd1;
    begin
      if (k) begin
        c6 = rd ? 6'b110000 : 6'b001111;              // K28 (only K supported)
      end else begin
        case (d[4:0])                                  // 5b/6b, EDCBA
          5'd0 : c6 = rd ? 6'b011000 : 6'b100111;
          5'd1 : c6 = rd ? 6'b100010 : 6'b011101;
          5'd2 : c6 = rd ? 6'b010010 : 6'b101101;
          5'd3 : c6 = 6'b110001;
          5'd4 : c6 = rd ? 6'b001010 : 6'b110101;
          5'd5 : c6 = 6'b101001;
          5'd6 : c6 = 6'b011001;
          5'd7 : c6 = rd ? 6'b000111 : 6'b111000;
          5'd8 : c6 = rd ? 6'b000110 : 6'b111001;
          5'd9 : c6 = 6'b100101;
          5'd10: c6 = 6'b010101;
          5'd11: c6 = 6'b110100;
          5'd12: c6 = 6'b001101;
          5'd13: c6 = 6'b101100;
          5'd14: c6 = 6'b011100;
          5'd15: c6 = rd ? 6'b101000 : 6'b010111;
          5'd16: c6 = rd ? 6'b100100 : 6'b011011;
          5'd17: c6 = 6'b100011;
          5'd18: c6 = 6'b010011;
          5'd19: c6 = 6'b110010;
          5'd20: c6 = 6'b001011;
          5'd21: c6 = 6'b101010;
          5'd22: c6 = 6'b011010;
          5'd23: c6 = rd ? 6'b000101 : 6'b111010;
          5'd24: c6 = rd ? 6'b001100 : 6'b110011;
          5'd25: c6 = 6'b100110;
          5'd26: c6 = 6'b010110;
          5'd27: c6 = rd ? 6'b001001 : 6'b110110;
          5'd28: c6 = 6'b001110;
          5'd29: c6 = rd ? 6'b010001 : 6'b101110;
          5'd30: c6 = rd ? 6'b100001 : 6'b011110;
          default: c6 = rd ? 6'b010100 : 6'b101011;    // D31
        endcase
      end
      rd1 = rd ^ ~is_bal6(c6);
      if (k && (d[7:5] == 3'd7)) begin
        c4 = rd1 ? 4'b1000 : 4'b0111;                  // Kx.7 alternate
      end else begin
        case (d[7:5])                                  // 3b/4b, HGF
          3'd0 : c4 = rd1 ? 4'b0100 : 4'b1011;
          3'd1 : c4 = 4'b1001;
          3'd2 : c4 = 4'b0101;
          3'd3 : c4 = rd1 ? 4'b0011 : 4'b1100;
          3'd4 : c4 = rd1 ? 4'b0010 : 4'b1101;
          3'd5 : c4 = 4'b1010;
          3'd6 : c4 = 4'b0110;
          default: c4 = rd1 ? 4'b0001 : 4'b1110;       // Dx.7 primary
        endcase
      end
      enc8b10b = {rd1 ^ ~is_bal4(c4), c6, c4};
    end
  endfunction

  // ------------------------------------------------------------------
  // 8b/10b decoder. returns {valid, is_k, data[7:0]}.
  // (disparity of the received stream is not strictly enforced; invalid
  //  code groups are flagged as code violations)
  // ------------------------------------------------------------------
  function automatic logic [9:0] dec8b10b(input logic [9:0] s);
    logic [5:0] c6;
    logic [3:0] c4;
    logic       v6, v4, kk;
    logic [4:0] y;
    logic [2:0] x;
    begin
      c6 = s[9:4];
      c4 = s[3:0];
      v6 = 1'b1; kk = 1'b0; y = 5'd0;
      case (c6)
        6'b100111, 6'b011000: y = 5'd0;
        6'b011101, 6'b100010: y = 5'd1;
        6'b101101, 6'b010010: y = 5'd2;
        6'b110001:            y = 5'd3;
        6'b110101, 6'b001010: y = 5'd4;
        6'b101001:            y = 5'd5;
        6'b011001:            y = 5'd6;
        6'b111000, 6'b000111: y = 5'd7;
        6'b111001, 6'b000110: y = 5'd8;
        6'b100101:            y = 5'd9;
        6'b010101:            y = 5'd10;
        6'b110100:            y = 5'd11;
        6'b001101:            y = 5'd12;
        6'b101100:            y = 5'd13;
        6'b011100:            y = 5'd14;
        6'b010111, 6'b101000: y = 5'd15;
        6'b011011, 6'b100100: y = 5'd16;
        6'b100011:            y = 5'd17;
        6'b010011:            y = 5'd18;
        6'b110010:            y = 5'd19;
        6'b001011:            y = 5'd20;
        6'b101010:            y = 5'd21;
        6'b011010:            y = 5'd22;
        6'b111010, 6'b000101: y = 5'd23;
        6'b110011, 6'b001100: y = 5'd24;
        6'b100110:            y = 5'd25;
        6'b010110:            y = 5'd26;
        6'b110110, 6'b001001: y = 5'd27;
        6'b001110:            y = 5'd28;
        6'b001111, 6'b110000: begin y = 5'd28; kk = 1'b1; end
        6'b101110, 6'b010001: y = 5'd29;
        6'b011110, 6'b100001: y = 5'd30;
        6'b101011, 6'b010100: y = 5'd31;
        default:              v6 = 1'b0;
      endcase
      v4 = 1'b1; x = 3'd0;
      case (c4)
        4'b1011, 4'b0100:                 x = 3'd0;
        4'b1001:                          x = 3'd1;
        4'b0101:                          x = 3'd2;
        4'b1100, 4'b0011:                 x = 3'd3;
        4'b1101, 4'b0010:                 x = 3'd4;
        4'b1010:                          x = 3'd5;
        4'b0110:                          x = 3'd6;
        4'b1110, 4'b0001, 4'b0111, 4'b1000: x = 3'd7;
        default:                          v4 = 1'b0;
      endcase
      dec8b10b = {v6 & v4, kk, x, y};
    end
  endfunction

  // ------------------------------------------------------------------
  // registers
  // ------------------------------------------------------------------
  logic [7:0]  cfg [0:7];        // rate config: 0={ptr_p,rate},1=version,2=vendor
  // tx hyperframe counters (master is the timing source, free-running)
  logic [5:0]  tx_bf;
  logic [3:0]  tx_wpos;
  logic [3:0]  tx_hfi;
  logic        tx_rd;
  logic [7:0]  tx_byte, l1_tx_byte;
  logic        tx_is_k;
  // rx path
  logic        rx_v, rx_k;
  logic [7:0]  rx_d;
  logic [9:0]  rx_wcnt;          // position inside peer hyperframe (0..1023)
  logic [1:0]  align_cnt;
  logic [2:0]  miss_cnt;
  // L1 inband slow stream (16 hyperframes)
  logic [3:0]  l1_cnt;
  logic [7:0]  l1_b1, l1_b2;
  logic        l1_done;
  logic [3:0]  peer_ver, peer_rate;
  logic [7:0]  rx_vendor;
  // IQ capture buffer 32x32, {I[15:0],Q[15:0]} per word
  logic [31:0] iq_mem [0:31];
  logic [4:0]  iq_wptr, iq_rptr;
  logic [5:0]  iq_cnt;
  logic [1:0]  iq_bcnt;
  logic [23:0] iq_shift;
  logic [7:0]  ovf_cnt;
  // irq sticky bits
  logic        irq_los, irq_cv;

  logic        iq_pop, iq_pos;
  logic [3:0]  neg_ver, neg_rate;

  // ------------------------------------------------------------------
  // TX byte selection (control words + IQ placeholder pattern; the
  // downlink IQ source is application-specific in a real REC)
  // ------------------------------------------------------------------
  always_comb begin
    case (tx_hfi)
      4'd0   : l1_tx_byte = L1_SOM;
      4'd1   : l1_tx_byte = {4'h0, cfg[1][3:0]};             // protocol version
      4'd2   : l1_tx_byte = cfg[0];                          // {pointer p, rate}
      4'd15  : l1_tx_byte = cfg[0] ^ {4'h0, cfg[1][3:0]} ^ 8'hA5; // check byte
      default: l1_tx_byte = 8'h00;
    endcase
  end

  always_comb begin
    tx_is_k = 1'b0;
    tx_byte = 8'h00;
    if (tx_wpos == 4'd0) begin
      case (tx_bf)
        6'd0   : begin tx_is_k = 1'b1; tx_byte = K28_5; end  // sync control word
        6'd1   : tx_byte = l1_tx_byte;                       // L1 inband
        6'd4   : tx_byte = cfg[2];                           // vendor byte
        default: tx_byte = 8'h00;
      endcase
    end else if (tx_bf == 6'd0 && tx_wpos <= 4'd2) begin
      tx_byte = 8'h50;                                       // sync stuff bytes
    end else begin
      tx_byte = {tx_bf[3:0], tx_wpos};                       // IQ pattern
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_bf   <= 6'd0;
      tx_wpos <= 4'd0;
      tx_hfi  <= 4'd0;
      tx_rd   <= 1'b0;
      tx_sym  <= {6'b100111, 4'b1011};                       // D0.0 @ RD-
    end else begin
      {tx_rd, tx_sym} <= enc8b10b(tx_byte, tx_is_k, tx_rd);
      if (tx_wpos == 4'd15) begin
        tx_wpos <= 4'd0;
        if (tx_bf == 6'd63) begin
          tx_bf  <= 6'd0;
          tx_hfi <= tx_hfi + 4'd1;
        end else begin
          tx_bf <= tx_bf + 6'd1;
        end
      end else begin
        tx_wpos <= tx_wpos + 4'd1;
      end
    end
  end

  // ------------------------------------------------------------------
  // RX decode (combinational) + position helpers
  // ------------------------------------------------------------------
  assign {rx_v, rx_k, rx_d} = dec8b10b(rx_sym);
  // IQ positions: any word > 0, except the two sync stuff bytes of frame #0
  assign iq_pos = (rx_wcnt[3:0] != 4'd0) &&
                  !((rx_wcnt[9:4] == 6'd0) && (rx_wcnt[3:0] <= 4'd2));
  assign iq_pop = cpu_re && (cpu_addr == 4'd10) && (iq_cnt != 6'd0);

  assign neg_ver  = (cfg[1][3:0] < peer_ver)  ? cfg[1][3:0]  : peer_ver;
  assign neg_rate = (cfg[0][3:0] < peer_rate) ? cfg[0][3:0] : peer_rate;

  // ------------------------------------------------------------------
  // RX sequential: sync FSM + L1 inband + IQ packing + cpu/irq
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_st   <= ST_HUNT;
      rx_wcnt   <= 10'd0;
      align_cnt <= 2'd0;
      miss_cnt  <= 3'd0;
      l1_cnt    <= 4'd0;
      l1_b1     <= 8'd0;
      l1_b2     <= 8'd0;
      l1_done   <= 1'b0;
      peer_ver  <= 4'd0;
      peer_rate <= 4'd0;
      rx_vendor <= 8'd0;
      iq_wptr   <= 5'd0;
      iq_rptr   <= 5'd0;
      iq_cnt    <= 6'd0;
      iq_bcnt   <= 2'd0;
      iq_shift  <= 24'd0;
      ovf_cnt   <= 8'd0;
      irq_los   <= 1'b0;
      irq_cv    <= 1'b0;
      cfg[0]    <= 8'h2A;   // pointer p = 2, rate = 10
      cfg[1]    <= 8'h04;   // local protocol version 4
      cfg[2]    <= 8'hC9;   // vendor id
      cfg[3]    <= 8'd0;
      cfg[4]    <= 8'd0;
      cfg[5]    <= 8'd0;
      cfg[6]    <= 8'd0;
      cfg[7]    <= 8'd0;
    end else begin
      // cpu writes: config registers + irq clear
      if (cpu_we) begin
        if (cpu_addr < 4'd8)
          cfg[cpu_addr[2:0]] <= cpu_wdata[7:0];
        else if (cpu_addr == 4'd13) begin
          if (cpu_wdata[0]) irq_los <= 1'b0;
          if (cpu_wdata[1]) irq_cv  <= 1'b0;
        end
      end
      // code violation is sticky (set wins over simultaneous clear)
      if (!rx_v) irq_cv <= 1'b1;
      // IQ buffer pop/pointers
      if (iq_pop) iq_rptr <= iq_rptr + 5'd1;

      case (sync_st)
        // -------------------------------------------------- HUNT
        ST_HUNT: begin
          if (rx_v && rx_k && (rx_d == K28_5)) begin
            sync_st   <= ST_ALIGN;
            rx_wcnt   <= 10'd1;
            align_cnt <= 2'd0;
            miss_cnt  <= 3'd0;
          end
        end
        // -------------------------------------------------- ALIGN
        ST_ALIGN: begin
          if (rx_v && rx_k && (rx_d == K28_5)) begin
            if (rx_wcnt == 10'd0) begin
              // comma exactly one hyperframe after the previous one
              rx_wcnt <= 10'd1;
              if (align_cnt == 2'd1) begin
                sync_st   <= ST_SYNC;
                align_cnt <= 2'd0;
                iq_bcnt   <= 2'd0;
                l1_cnt    <= 4'd0;
              end else begin
                align_cnt <= align_cnt + 2'd1;
              end
            end else begin
              // stray comma: re-align phase to it
              rx_wcnt   <= 10'd1;
              align_cnt <= 2'd0;
            end
          end else if (rx_wcnt == 10'd0) begin
            // expected comma position passed without a comma
            sync_st   <= ST_HUNT;
            align_cnt <= 2'd0;
          end else begin
            rx_wcnt <= (rx_wcnt == 10'd1023) ? 10'd0 : rx_wcnt + 10'd1;
          end
        end
        // -------------------------------------------------- SYNC
        default: begin
          if (rx_wcnt == 10'd0) begin
            if (rx_v && rx_k && (rx_d == K28_5)) begin
              miss_cnt <= 3'd0;
            end else if (miss_cnt == 3'd3) begin
              // 4 consecutive hyperframes without peer K28.5: loss of sync
              sync_st  <= ST_HUNT;
              miss_cnt <= 3'd0;
              irq_los  <= 1'b1;
              iq_bcnt  <= 2'd0;
              l1_cnt   <= 4'd0;
              l1_done  <= 1'b0;
            end else begin
              miss_cnt <= miss_cnt + 3'd1;
            end
          end
          rx_wcnt <= (rx_wcnt == 10'd1023) ? 10'd0 : rx_wcnt + 10'd1;

          // L1 inband slow-stream byte (control word of basic frame #1)
          if ((rx_wcnt == 10'd16) && rx_v && !rx_k) begin
            if (rx_d == L1_SOM) begin
              l1_cnt <= 4'd1;
            end else if (l1_cnt != 4'd0) begin
              if (l1_cnt == 4'd1) l1_b1 <= rx_d;
              if (l1_cnt == 4'd2) l1_b2 <= rx_d;
              if (l1_cnt == 4'd15) begin
                l1_cnt <= 4'd0;
                if (rx_d == (l1_b1 ^ l1_b2 ^ 8'hA5)) begin
                  l1_done   <= 1'b1;
                  peer_ver  <= l1_b1[3:0];
                  peer_rate <= l1_b2[3:0];
                end
              end else begin
                l1_cnt <= l1_cnt + 4'd1;
              end
            end
          end
          // vendor byte (control word of basic frame #4)
          if ((rx_wcnt == 10'd64) && rx_v && !rx_k)
            rx_vendor <= rx_d;
          // IQ byte packing: 4 bytes -> {I[15:0],Q[15:0]}
          if (iq_pos && rx_v && !rx_k) begin
            case (iq_bcnt)
              2'd0   : iq_shift[23:16] <= rx_d;
              2'd1   : iq_shift[15:8]  <= rx_d;
              2'd2   : iq_shift[7:0]   <= rx_d;
              default: begin
                if ((iq_cnt < 6'd32) || iq_pop) begin
                  iq_mem[iq_wptr] <= {iq_shift, rx_d};
                  iq_wptr         <= iq_wptr + 5'd1;
                end else begin
                  ovf_cnt <= ovf_cnt + 8'd1;   // drop, no irq (status only)
                end
              end
            endcase
            iq_bcnt <= iq_bcnt + 2'd1;
          end
        end
      endcase

      // IQ count update (simultaneous push+pop keeps the count)
      case ({(sync_st == ST_SYNC) && iq_pos && rx_v && !rx_k &&
             (iq_bcnt == 2'd3) && ((iq_cnt < 6'd32) || iq_pop), iq_pop})
        2'b10  : iq_cnt <= iq_cnt + 6'd1;
        2'b01  : iq_cnt <= iq_cnt - 6'd1;
        default: iq_cnt <= iq_cnt;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // cpu read mux + irq
  // ------------------------------------------------------------------
  always_comb begin
    cpu_rdata = 32'h0;
    if (cpu_addr < 4'd8) begin
      cpu_rdata = {24'h0, cfg[cpu_addr[2:0]]};
    end else begin
      case (cpu_addr)
        4'd8   : cpu_rdata = {8'h0, ovf_cnt, peer_ver, iq_cnt, miss_cnt,
                              l1_done, sync_st};
        4'd9   : cpu_rdata = {24'h0, neg_rate, neg_ver};
        4'd10  : cpu_rdata = iq_mem[iq_rptr];
        4'd11  : cpu_rdata = {26'h0, iq_cnt};
        4'd12  : cpu_rdata = {24'h0, rx_vendor};
        4'd13  : cpu_rdata = {30'h0, irq_cv, irq_los};
        default: cpu_rdata = 32'h0;
      endcase
    end
  end

  assign irq = irq_los | irq_cv;

endmodule
