// SPDX-License-Identifier: Apache-2.0
// eUSB2 repeater: a line-level model decodes eD+/eD- on its own (NRZI,
// sync hunt, bit unstuffing), collects each packet's bits and judges it at
// the EOP (control PID, length, CRC8), keeps a shadow register file and
// the squelch detector, and builds every read-response frame as a list of
// line states (sync, NRZI + stuffed bytes, EOP). It predicts dp/dm on every
// clock (retimed copy, squelch silence or response), squelch, irq and the
// register file.
`include "cov_macros.svh"
module eUSB2_sva (
  input logic       clk, rst_n, edp, edm, dp, dm, squelch, irq,
  input logic [7:0] regfile [0:7]
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic logic [7:0] crc8(input logic [7:0] c, input logic [7:0] d);
    for (int i = 7; i >= 0; i--) c = {c[6:0], 1'b0} ^ ((d[i] ^ c[7]) ? 8'h07 : 8'h00);
    return c;
  endfunction

  wire [1:0] ln = {edp, edm};
  localparam logic [1:0] SE0 = 2'b00, K = 2'b01, J = 2'b10, SE1 = 2'b11;

  logic [7:0] sh [0:7];
  logic [1:0] pl, dly;
  logic [7:0] cnt;
  logic       sq, m_irq;
  // receiver
  logic       run;
  int         zeros, ones, nb;
  logic [39:0] bits;
  // read responses
  logic       req, taken, tx;
  logic [2:0] raddr;
  logic [1:0] cel [0:63];
  int         ncell, ti;

  wire jk  = ln == J || ln == K;
  wire bv  = jk && (pl == J || pl == K);
  wire b   = ln == pl;
  wire [7:0] b0 = bits[7:0], b1 = bits[15:8], b2 = bits[23:16], b3 = bits[31:24];
  wire ctl = nb >= 8 && b0 == 8'hC3;
  wire wrp = !b1[7];
  wire full = wrp ? nb >= 32 : nb >= 24;
  wire lng  = wrp ? nb >= 40 : nb >= 32;
  wire crc_ok = wrp ? crc8(crc8(8'hFF, b1), b2) == b3 : crc8(8'hFF, b1) == b2;

  // coverage strobes
  logic vwr, vrd, vcrc, vtr, vlong, vpend, vstuff, vse1, vnon, vqrx, vtxstuff, vtxend, vshort;
  logic [7:0] wmask, rmask;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) sh[i] <= i == 0 ? 8'd8 : 8'd0;
      pl <= SE0; dly <= SE0; cnt <= 0; sq <= 0; m_irq <= 0;
      run <= 0; zeros <= 0; ones <= 0; nb <= 0; bits <= 0;
      req <= 0; taken <= 0; tx <= 0; raddr <= 0; ncell <= 0; ti <= 0;
      for (int i = 0; i < 64; i++) cel[i] <= J;
      {vwr, vrd, vcrc, vtr, vlong, vpend, vstuff, vse1, vnon, vqrx, vtxstuff, vtxend, vshort} <= '0;
      wmask <= 0; rmask <= 0;
    end else begin
      {vwr, vrd, vcrc, vtr, vlong, vpend, vstuff, vse1, vnon, vqrx, vtxstuff, vtxend, vshort} <= '0;
      dly <= ln; pl <= ln;

      // squelch
      if (ln == SE0) begin
        if (cnt != 8'hFF) cnt <= cnt + 1;
        if (cnt >= sh[0]) sq <= 1;
      end else begin
        cnt <= 0;
        if (ln == J) sq <= 0;
      end

      // receiver
      if (sq) begin
        run <= 0; zeros <= 0; vqrx <= bv;
      end else if (ln == SE1) begin
        m_irq <= 1; run <= 0; zeros <= 0; vse1 <= 1;
      end else if (ln == SE0) begin
        if (run) begin
          if (ctl) begin
            if (!full || lng) begin m_irq <= 1; vtr <= !full; vlong <= lng; end
            else if (!crc_ok) begin m_irq <= 1; vcrc <= 1; end
            else if (wrp) begin sh[b1[6:4]] <= b2; vwr <= 1; wmask[b1[6:4]] <= 1; end
            else begin req <= 1; raddr <= b1[6:4]; vrd <= 1; vpend <= tx; rmask[b1[6:4]] <= 1; end
          end else begin vnon <= nb >= 8; vshort <= nb < 8; end
        end
        run <= 0; zeros <= 0;
      end else if (bv) begin
        if (!run) begin
          if (!b) zeros <= zeros < 7 ? zeros + 1 : 7;
          else begin
            if (zeros == 7) begin run <= 1; ones <= 0; nb <= 0; bits <= 0; end
            zeros <= 0;
          end
        end else if (ones == 6) begin
          if (!b) ones <= 0;
          else begin m_irq <= 1; run <= 0; vstuff <= 1; end
        end else begin
          ones <= b ? ones + 1 : 0;
          if (nb < 40) begin bits[nb] <= b; nb <= nb + 1; end
        end
      end

      // read-response transmitter
      taken <= 0;
      if (taken) req <= 0;
      if (tx) begin
        ti <= ti + 1;
        if (ti == ncell - 1) tx <= 0;
      end else if (req && !taken) begin
        logic [1:0] lv;
        logic [7:0] by [0:3];
        int n, o;
        by[0] = 8'h3C; by[1] = {1'b1, raddr, 4'b0000}; by[2] = sh[raddr];
        by[3] = crc8(crc8(8'hFF, by[1]), by[2]);
        lv = J; n = 0;
        cel[n] <= lv; n++;
        for (int i = 0; i < 8; i++) begin if (i < 7) lv = ~lv; cel[n] <= lv; n++; end
        o = 0;
        for (int y = 0; y < 4; y++)
          for (int i = 0; i < 8; i++) begin
            if (!by[y][i]) begin lv = ~lv; o = 0; end else o++;
            cel[n] <= lv; n++;
            if (o == 6) begin lv = ~lv; o = 0; cel[n] <= lv; n++; vtxstuff <= 1; vtxend <= y == 3 && i == 7; end
          end
        cel[n] <= SE0; cel[n + 1] <= SE0;
        ncell <= n + 2; ti <= 0; tx <= 1; taken <= 1;
      end
    end
  end

  logic rf_ok;
  always_comb begin
    rf_ok = 1;
    for (int i = 0; i < 8; i++) if (regfile[i] != sh[i]) rf_ok = 0;
  end
  wire [1:0] exp_out = tx ? cel[ti] : sq ? SE0 : dly;

  `SVA_RST(a_reset_state, !rst_n, !squelch && !irq && {dp, dm} == 2'b00)
  `SVA_INV(a_outputs, {dp, dm} == exp_out)
  `SVA_INV(a_squelch, squelch == sq)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_register_file, rf_ok)
  `SVA_INV(a_response_never_se1, !tx || cel[ti] != SE1)

  covergroup cg_regs @(posedge clk);
    option.per_instance = 1;
    cp_w: coverpoint b1[6:4] iff (vwr_now) { bins a[] = {[0:7]}; }
    cp_r: coverpoint b1[6:4] iff (vrd_now) { bins a[] = {[0:7]}; }
    cp_wd: coverpoint dcls(b2) iff (vwr_now) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_wr: cross cp_w, cp_wd;
    cp_rd: coverpoint dcls(sh[b1[6:4]]) iff (vrd_now) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  function automatic int dcls(input logic [7:0] v);
    dcls = v == 0 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  // one-cycle-early versions of vwr / vrd so b1 still holds the address
  wire vwr_now = !sq && ln == SE0 && run && ctl && full && !lng && crc_ok && wrp;
  wire vrd_now = !sq && ln == SE0 && run && ctl && full && !lng && crc_ok && !wrp;
  cg_regs cg = new();

  `FC(register_write, vwr)
  `FC(register_read, vrd)
  `FC(crc_error, vcrc)
  `FC(truncated_control, vtr)
  `FC(over_long_control, vlong)
  `FC(read_queued_behind_response, vpend)
  `FC(bit_stuff_error, vstuff)
  `FC(se1_on_line, vse1)
  `FC(non_control_packet, vnon)
  `FC(runt_packet, vshort)
  `FC(squelch_ignores_traffic, vqrx)
  `FC(squelch_enter, !sq ##1 sq)
  `FC(squelch_exit, sq ##1 !sq)
  `FC(squelch_during_response, tx && sq)
  `FC(response_stuffed_bit, vtxstuff)
  `FC(response_stuff_before_eop, vtxend)
  `FC(rx_during_response, tx && run)
  `FC_RST(reset_during_response, rst_n && tx ##1 !rst_n)
endmodule

bind eUSB2_top eUSB2_sva u_sva (.*);
