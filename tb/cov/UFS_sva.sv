// SPDX-License-Identifier: Apache-2.0
// UFS host (simplified UniPro frame link + UPIU): a pin-level model runs
// its own power-on / training / retrain sequence from rx_p, decodes every
// received frame (SOF hunt, header, payload, CRC-32, EOF), executes the
// COMMAND UPIUs against a shadow LUN0 medium, builds the RESPONSE / DATA
// UPIU frames itself and predicts tx_p bit by bit, irq cycle by cycle, and
// the medium contents.
`include "cov_macros.svh"
module UFS_sva #(parameter int BIT_CLKS = 1) (
  input logic        clk, rst_n, tx_p, tx_n, rx_p, irq,
  input logic [31:0] storage [0:255]
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [31:0] SOF = 32'h5546_5301, EOFW = 32'h5546_5302, TRN = 32'hBC3C_5A5A;
  localparam int TMO = 4095 * BIT_CLKS;

  function automatic logic [31:0] crc(input logic [31:0] c, input logic [31:0] w);
    for (int i = 31; i >= 0; i--) c = (c >> 1) ^ ((c[0] ^ w[i]) ? 32'hEDB88320 : 32'h0);
    return c;
  endfunction

  // ---------------- bit clock ----------------
  int bd;
  wire tick = BIT_CLKS <= 1 || bd == BIT_CLKS - 1;

  // ---------------- link ----------------
  localparam int L_PWR = 0, L_TRN = 1, L_WAIT = 2, L_UP = 3;
  int          lp, lt, lb, lw, lg;
  logic        larm;
  logic [31:0] lsh;
  wire  [31:0] lnx = {lsh[30:0], rx_p};

  // ---------------- receiver ----------------
  localparam int R_HUNT = 0, R_WORD = 1;
  int          rp, rb, rwi, rlen;
  logic [31:0] rsh, rcrc, rw [0:10];          // hdr, payload, crc, eof
  wire  [31:0] rnx = {rsh[30:0], rx_p};

  // ---------------- transmitter ----------------
  logic [31:0] q [0:16];
  int          qn, qb;
  logic        treq, trun, m_tx, m_irq;
  logic [31:0] m_st [0:255];
  logic        vld [0:255];                  // written since time 0
  // the medium is not reset, so neither is its model
  initial for (int i = 0; i < 256; i++) begin m_st[i] = '0; vld[i] = 0; end

  // coverage strobes
  logic f_tur, f_w4, f_r8, f_crc, f_eof, f_big, f_short, f_lun, f_xfer, f_woor, f_r0, f_rbig;
  logic f_unk, f_other, f_busy, f_retrain, f_second_bad, f_link;

  task automatic frame(inout logic [31:0] b [0:16], inout int n, input logic [31:0] h,
                       input int len, input logic [31:0] p [0:7]);
    logic [31:0] c;
    c = crc(32'hFFFFFFFF, h);
    b[n] = SOF; b[n + 1] = h; n += 2;
    for (int i = 0; i < 8; i++) if (i < len) begin b[n] = p[i]; c = crc(c, p[i]); n++; end
    b[n] = ~c; b[n + 1] = EOFW; n += 2;
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bd <= 0; lp <= L_PWR; lt <= 0; lb <= 0; lw <= 0; lg <= 0; larm <= 0; lsh <= '0;
      rp <= R_HUNT; rb <= 0; rwi <= 0; rlen <= 0; rsh <= '0; rcrc <= '0;
      qn <= 0; qb <= 0; treq <= 0; trun <= 0; m_tx <= 1; m_irq <= 0;
      {f_tur, f_w4, f_r8, f_crc, f_eof, f_big, f_short, f_lun, f_xfer, f_woor, f_r0, f_rbig} <= '0;
      {f_unk, f_other, f_busy, f_retrain, f_second_bad, f_link} <= '0;
    end else begin
      {f_tur, f_w4, f_r8, f_crc, f_eof, f_big, f_short, f_lun, f_xfer, f_woor, f_r0, f_rbig} <= '0;
      {f_unk, f_other, f_busy, f_retrain, f_second_bad, f_link} <= '0;
      m_irq <= 0;
      bd <= tick ? 0 : bd + 1;

      // ---------------- link sequence ----------------
      case (lp)
        L_PWR: if (lt == 15) begin lp <= L_TRN; lt <= 0; lb <= 0; lw <= 0; end else lt <= lt + 1;
        L_TRN: if (tick) begin
          if (lb == 31) begin
            lb <= 0;
            if (lw == 7) begin lp <= L_WAIT; lt <= 0; larm <= 0; end else lw <= lw + 1;
          end else lb <= lb + 1;
        end
        L_WAIT: begin
          if (tick) begin
            lsh <= lnx;
            if (!larm) begin if (lnx == TRN) begin larm <= 1; lg <= 0; end end
            else if (lg == 31) begin
              larm <= 0;
              if (lnx == TRN) begin lp <= L_UP; f_link <= 1; end else f_second_bad <= 1;
            end else lg <= lg + 1;
          end
          if (lt == TMO) begin lp <= L_TRN; lb <= 0; lw <= 0; lt <= 0; larm <= 0; f_retrain <= 1; end
          else lt <= lt + 1;
        end
        default: ;
      endcase

      // ---------------- receiver + command execution ----------------
      if (lp == L_UP && tick) begin
        rsh <= rnx;
        if (rp == R_HUNT) begin
          if (rnx == SOF) begin rp <= R_WORD; rb <= 0; rwi <= 0; rcrc <= 32'hFFFFFFFF; end
        end else if (rb != 31) rb <= rb + 1;
        else begin
          rb <= 0;
          rw[rwi] <= rnx;
          rwi <= rwi + 1;
          if (rwi == 0) begin
            rcrc <= crc(32'hFFFFFFFF, rnx);
            rlen <= int'(rnx[7:0]);
            if (rnx[7:0] > 8) begin rp <= R_HUNT; m_irq <= 1; f_big <= 1; end
          end else if (rwi <= rlen) rcrc <= crc(rcrc, rnx);
          else if (rwi == rlen + 1) begin
            if (rnx != ~rcrc) begin rp <= R_HUNT; m_irq <= 1; f_crc <= 1; end
          end else begin
            logic [31:0] h, p [0:7], b [0:16], st, lba;
            logic [7:0] op, tt;
            int n, nx, nb;
            bit ok, resp, rd;
            rp <= R_HUNT;
            h = rw[0]; tt = h[23:16];
            for (int i = 0; i < 8; i++) p[i] = rw[1 + i];
            op = p[0][31:24]; lba = {8'h0, p[0][23:0]};
            b = q; nb = 0;
            if (rnx != EOFW) begin m_irq <= 1; f_eof <= 1; end
            else if (h[31:24] != 8'h01) f_other <= 1;
            else if (treq || trun) begin m_irq <= 1; f_busy <= 1; end
            else if (rlen < 4) begin m_irq <= 1; f_short <= 1; end
            else begin
              ok = 1; rd = 0;
              if (h[15:8] != 0) begin ok = 0; f_lun <= 1; end
              else if (op == 8'h00) f_tur <= 1;
              else if (op == 8'h2A) begin
                n = rlen - 4;
                if (n < 1 || lba + 32'(n) > 256) begin ok = 0; f_woor <= 1; end
                else if (int'(p[1][31:24]) != n) begin ok = 0; f_xfer <= 1; end
                else begin
                  for (int i = 0; i < 4; i++) if (i < n) begin m_st[lba[7:0] + 8'(i)] <= p[4 + i]; vld[lba[7:0] + 8'(i)] <= 1; end
                  f_w4 <= n == 4;
                end
              end else if (op == 8'h28) begin
                nx = int'(p[1][31:24]);
                if (nx < 1 || nx > 8 || lba + 32'(nx) > 256) begin
                  ok = 0; f_r0 <= nx == 0; f_rbig <= nx > 8; f_woor <= nx >= 1 && nx <= 8;
                end else begin rd = 1; f_r8 <= nx == 8; end
              end else begin ok = 0; f_unk <= 1; end
              if (!ok) m_irq <= 1;
              st = ok ? 32'h0 : 32'h0005_0001;
              p[0] = st;
              frame(b, nb, {8'h81, tt, h[15:8], 8'd1}, 1, p);
              if (rd) begin
                // the medium is read when the DATA UPIU starts; no write can
                // land in between, so reading the shadow now is equivalent
                for (int i = 0; i < 8; i++) p[i] = m_st[lba[7:0] + 8'(i)];
                frame(b, nb, {8'h02, tt, 8'h00, 8'(nx)}, nx, p);
              end
              q <= b; qn <= nb * 32; qb <= 0; treq <= 1;
            end
          end
        end
      end

      // ---------------- transmitter ----------------
      if (tick) begin
        if (!trun) begin
          m_tx <= 1;
          if (treq) begin trun <= 1; treq <= 0; end
        end else begin
          m_tx <= q[qb / 32][31 - qb % 32];
          qb <= qb + 1;
          if (qb == qn - 1) trun <= 0;
        end
      end
    end
  end

  wire exp_tx = lp == L_TRN ? TRN[31 - lb] : lp == L_UP ? m_tx : 1'b1;
  logic st_ok;
  always_comb begin
    st_ok = 1;
    for (int i = 0; i < 256; i++) if (vld[i] && storage[i] != m_st[i]) st_ok = 0;
  end

  `SVA_RST(a_reset_idle, !rst_n, tx_p && !tx_n && !irq)
  `SVA_INV(a_tx_line, tx_p == exp_tx)
  `SVA_INV(a_differential, tx_n == !tx_p)
  `SVA_INV(a_irq, irq == m_irq)
  `SVA_INV(a_medium, st_ok)

  `FC(link_trained, f_link)
  `FC(retrain_timeout, f_retrain)
  `FC(train_second_dword_bad, f_second_bad)
  `FC(test_unit_ready, f_tur)
  `FC(write10_4_dwords, f_w4)
  `FC(read10_8_dwords, f_r8)
  `FC(crc_error, f_crc)
  `FC(bad_eof, f_eof)
  `FC(oversize_len, f_big)
  `FC(malformed_cdb, f_short)
  `FC(bad_lun, f_lun)
  `FC(write_xfer_mismatch, f_xfer)
  `FC(out_of_range_lba, f_woor)
  `FC(read_len_zero, f_r0)
  `FC(read_len_over_8, f_rbig)
  `FC(unknown_opcode, f_unk)
  `FC(non_command_upiu_ignored, f_other)
  `FC(command_while_busy, f_busy)
  `FC(data_upiu_chained, trun && tick && qb == 160)
  `FC_RST(reset_while_transmitting, rst_n && trun ##1 !rst_n)
endmodule

bind UFS_top UFS_sva #(.BIT_CLKS(BIT_CLKS)) u_sva (.*);
