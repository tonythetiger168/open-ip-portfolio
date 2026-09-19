// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking loopback testbench for SAS_4__Serial_Attached_SCSI__top.
//  (a) reset state, (b) OOB handshake -> PHY READY, (c) >=4 write/read
//      loopback transactions checked both at the DUT regfile and on the wire
//      (independent 128b/150b block decoder + x^16+x^5+1 descrambler in the
//      TB verifies scrambled line data is NOT plaintext and decodes frames),
//  (d) CRC error injection (1 payload line-bit flip) -> drop + irq + no
//      register pollution + stale-read mismatch + link keeps running,
//  (e) 8 consecutive bad sync headers -> loss-of-sync + irq + re-OOB +
//      transaction recovery.
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module SAS_4__Serial_Attached_SCSI__tb;

  // mirror of DUT constants
  localparam logic [1:0]  SH_DATA   = 2'b01;
  localparam logic [1:0]  SH_CTRL   = 2'b10;
  localparam logic [31:0] CODE_IDLE = 32'hA5C3_0000;
  localparam logic [31:0] CODE_SOF  = 32'hA5C3_0001;
  localparam logic [31:0] CODE_EOF  = 32'hA5C3_0002;
  localparam logic [15:0] SCR_SEED  = 16'hACE1;
  localparam logic [7:0]  T_WRITE   = 8'h01;
  localparam logic [7:0]  T_RDREQ   = 8'h02;
  localparam logic [7:0]  T_RDRSP   = 8'h83;
  localparam logic [2:0]  TX_PAY0_CODE = 3'd3; // mirrors RTL tx_t enum
  localparam logic        RX_HUNT_CODE = 1'b0; // mirrors RTL rxl_t enum

  logic clk = 0, rst_n = 0;
  logic tx_p, tx_n, rx_p, rx_n, link_up, irq;
  logic corrupt = 1'b0;          // 1-clk loopback bit flip (error injection)
  int   errors = 0;
  int   irq_cnt = 0;

  SAS_4__Serial_Attached_SCSI__top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_p(tx_p), .tx_n(tx_n),
    .rx_p(rx_p), .rx_n(rx_n),
    .link_up(link_up), .irq(irq)
  );

  always #5 clk = ~clk;

  // direct loopback with injectable corruption on rx_p
  assign rx_p = tx_p ^ corrupt;
  assign rx_n = tx_n;

  always @(posedge clk) if (rst_n && irq) irq_cnt++;

  // -------- scoreboard model of the DUT initiator sequencer -----------------
  // txn n writes reg[n % 16] with 32'h5A5A_0000 + n*32'h0001_0101
  function automatic logic [31:0] exp_data(input int n);
    return 32'h5A5A_0000 + n * 32'h0001_0101;
  endfunction

  // CRC32 reference model (same construction as DUT)
  function automatic logic [31:0] crc32_dw(input logic [31:0] crc,
                                           input logic [31:0] dw);
    logic [31:0] c;
    begin
      c = crc;
      for (int b = 3; b >= 0; b--) begin
        for (int i = 0; i < 8; i++) begin
          if (c[0] ^ dw[b*8+i]) c = (c >> 1) ^ 32'hEDB88320;
          else                  c = (c >> 1);
        end
      end
      crc32_dw = c;
    end
  endfunction

  function automatic logic [31:0] crc4(input logic [31:0] crc,
                                       input logic [31:0] d0,
                                       input logic [31:0] d1,
                                       input logic [31:0] d2,
                                       input logic [31:0] d3);
    crc4 = crc32_dw(crc32_dw(crc32_dw(crc32_dw(crc, d0), d1), d2), d3);
  endfunction

  // ---------------- independent wire monitor --------------------------------
  // Taps the CLEAN tx line, re-implements the 128b/150b block code and the
  // x^16+x^5+1 self-synchronous descrambler, verifies every frame CRC on the
  // wire and checks frame contents against the sequencer model.  Also counts
  // scrambled-vs-plaintext bit differences (line must not carry plaintext).
  logic [15:0]  m_dscr = SCR_SEED;
  logic [1:0]   m_sync;
  logic [127:0] m_pld, m_raw;
  int           nonplain_bits  = 0;
  int           frames_checked = 0;
  int           crc_checked    = 0;
  logic         inj_started = 1'b0;  // stop content compare after injection
  logic         mon_gate    = 1'b0;  // suppress wire checks during re-OOB

  int           m_state = 0;         // 0 idle, 1 wait hdr, 4 wait pay,
                                     // 2 wait crc, 3 wait eof
  logic [7:0]   m_type, m_dst, m_src, m_len;
  logic [31:0]  m_crc;
  logic [31:0]  m_pay [0:7];
  int           m_payblk;
  logic [31:0]  shadow [0:15];       // shadow register file from wire writes
  logic         sh_valid [0:15];
  logic [7:0]   last_rd;
  int           writes_seen = 0;

  task automatic mon_bit(output logic b);
    @(negedge clk); b = tx_p;
  endtask

  // receive one 130-bit block at the current assumed boundary
  task automatic mon_block;
    logic b;
    begin
      mon_bit(m_sync[1]);
      mon_bit(m_sync[0]);
      for (int i = 127; i >= 0; i--) begin
        mon_bit(b);
        m_raw[i] = b;
        m_pld[i] = b ^ m_dscr[15] ^ m_dscr[4];
        m_dscr   = {m_dscr[14:0], b};
        if (m_pld[i] !== b) nonplain_bits++;
      end
    end
  endtask

  // hunt: bit-slip until 4 consecutive valid syncs AND a legal control code.
  // On exit the monitor is exactly block-aligned (no prefetched bit is lost).
  task automatic mon_hunt;
    logic [1:0] s;
    logic [127:0] p;
    logic b;
    int  good;
    logic code_found;
    logic have_pend;
    logic pend;
    begin
      m_dscr     = SCR_SEED;
      m_state    = 0;
      good       = 0;
      code_found = 0;
      have_pend  = 0;
      pend       = 0;
      while (good < 4 || !code_found) begin
        if (have_pend) begin s[1] = pend; have_pend = 0; end
        else mon_bit(s[1]);
        mon_bit(s[0]);
        if (s == SH_DATA || s == SH_CTRL) begin
          for (int i = 127; i >= 0; i--) begin
            mon_bit(b);
            p[i]   = b ^ m_dscr[15] ^ m_dscr[4];
            m_dscr = {m_dscr[14:0], b};
          end
          if (s == SH_CTRL &&
              (p[127:96] == CODE_IDLE || p[127:96] == CODE_SOF ||
               p[127:96] == CODE_EOF))
            code_found = 1;
          good++;
        end else begin
          pend       = s[0];             // slip by one bit: retry at +1 offset
          have_pend  = 1;
          good       = 0;
          code_found = 0;
        end
      end
    end
  endtask

  // frame content check against the sequencer model (self-synchronizing:
  // write data pattern embeds the target address; read responses are checked
  // against the shadow register file built from observed writes)
  task automatic mon_content;
    begin
      case (m_type)
        T_WRITE: begin
          if (m_len < 8'd1 || m_dst >= 8'd16) begin
            errors++;
            $display("ERROR: wire WRITE malformed len=%0d dst=%0d", m_len, m_dst);
          end else begin
            if (!(m_pay[0][31:24] == 8'h5A &&
                  m_pay[0][7:0]   == m_pay[0][15:8] &&
                  m_pay[0][23:16] == (8'h5A + m_pay[0][7:0]) &&
                  m_pay[0][3:0]   == m_dst[3:0])) begin
              errors++;
              $display("ERROR: wire WRITE data %h not sequencer pattern (addr %0d)",
                       m_pay[0], m_dst);
            end
            shadow[m_dst[3:0]]   = m_pay[0];
            sh_valid[m_dst[3:0]] = 1'b1;
            writes_seen++;
          end
        end
        T_RDREQ: begin
          if (m_dst >= 8'd16 || m_len != 8'd0) begin
            errors++;
            $display("ERROR: wire RDREQ malformed len=%0d dst=%0d", m_len, m_dst);
          end
          last_rd = m_dst;
        end
        T_RDRSP: begin
          if (m_len < 8'd1) begin
            errors++;
            $display("ERROR: wire RDRSP malformed len=%0d", m_len);
          end else if (sh_valid[last_rd[3:0]] &&
                       m_pay[0] !== shadow[last_rd[3:0]]) begin
            errors++;
            $display("ERROR: wire RDRSP data %h != shadow %h (addr %0d)",
                     m_pay[0], shadow[last_rd[3:0]], last_rd);
          end
        end
        default: begin
          errors++;
          $display("ERROR: wire frame unknown type %h", m_type);
        end
      endcase
      frames_checked++;
    end
  endtask

  initial begin : WIRE_MON
    int bad;
    for (int a = 0; a < 16; a++) begin
      sh_valid[a] = 1'b0;
      shadow[a]   = 32'd0;
    end
    @(posedge rst_n);
    bad = 0;
    mon_hunt;
    forever begin
      mon_block;
      if (m_sync != SH_DATA && m_sync != SH_CTRL) begin
        bad++;
        if (bad >= 8) begin bad = 0; mon_hunt; end
      end else begin
        bad = 0;
        case (m_state)
          0: if (m_sync == SH_CTRL && m_pld[127:96] == CODE_SOF) m_state = 1;
          1: begin                                   // header block
               if (m_sync != SH_DATA) begin
                 if (!mon_gate) begin
                   errors++; $display("ERROR: wire HDR block not data");
                 end
                 m_state = 0;
               end else begin
                 m_type = m_pld[103:96];
                 m_dst  = m_pld[71:64];
                 m_src  = m_pld[39:32];
                 m_len  = m_pld[7:0];
                 m_crc  = crc4(32'hFFFF_FFFF, m_pld[127:96], m_pld[95:64],
                               m_pld[63:32], m_pld[31:0]);
                 if (m_len == 8'd0) m_state = 2;
                 else if (m_len <= 8'd8) begin m_payblk = 0; m_state = 4; end
                 else begin
                   if (!mon_gate) begin
                     errors++; $display("ERROR: wire HDR len %0d > 8", m_len);
                   end
                   m_state = 0;
                 end
               end
             end
          4: begin                                   // payload block
               if (m_sync != SH_DATA) begin
                 if (!mon_gate) begin
                   errors++; $display("ERROR: wire PAY block not data");
                 end
                 m_state = 0;
               end else begin
                 m_pay[m_payblk*4+0] = m_pld[127:96];
                 m_pay[m_payblk*4+1] = m_pld[95:64];
                 m_pay[m_payblk*4+2] = m_pld[63:32];
                 m_pay[m_payblk*4+3] = m_pld[31:0];
                 m_crc = crc4(m_crc, m_pld[127:96], m_pld[95:64],
                              m_pld[63:32], m_pld[31:0]);
                 if (m_len <= 8'd4 || m_payblk == 1) m_state = 2;
                 else m_payblk = 1;
               end
             end
          2: begin                                   // CRC block
               if (m_sync != SH_DATA) begin
                 if (!mon_gate) begin
                   errors++; $display("ERROR: wire CRC block not data");
                 end
               end else if (m_pld[127:96] !== (m_crc ^ 32'hFFFF_FFFF)) begin
                 if (!mon_gate) begin
                   errors++;
                   $display("ERROR: wire CRC mismatch got=%h exp=%h",
                            m_pld[127:96], m_crc ^ 32'hFFFF_FFFF);
                 end
               end else begin
                 crc_checked++;
                 if (!inj_started && !mon_gate) mon_content;
               end
               m_state = 3;
             end
          3: begin                                   // EOF block
               if (!(m_sync == SH_CTRL && m_pld[127:96] == CODE_EOF)) begin
                 if (!mon_gate) begin
                   errors++; $display("ERROR: wire EOF block bad");
                 end
               end
               m_state = 0;
             end
          default: m_state = 0;
        endcase
      end
    end
  end

  // ---------------- error injection drivers ---------------------------------
  logic       arm_crc = 1'b0, crc_inj_fired = 1'b0;
  logic [3:0] crc_inj_addr = 4'd0;
  logic [31:0] crc_inj_old = 32'd0;
  logic       arm_sync = 1'b0;
  int         sync_inj_cnt = 0;

  always @(negedge clk) begin
    corrupt <= 1'b0;
    // (d) flip one payload line bit of a write frame's PAY0 block
    if (arm_crc && dut.phy_ready && dut.tx_state == TX_PAY0_CODE &&
        dut.f_type == T_WRITE && dut.tx_cnt == 8'd65) begin
      corrupt       <= 1'b1;
      arm_crc       <= 1'b0;
      crc_inj_fired <= 1'b1;
      crc_inj_addr  <= dut.f_dst[3:0];
      crc_inj_old   <= dut.regs[dut.f_dst[3:0]];
    end
    // (e) flip the sync header MSB of 8 consecutive blocks
    if (arm_sync && dut.phy_ready && dut.rx_cnt == 8'd0 && sync_inj_cnt < 8) begin
      corrupt      <= 1'b1;
      sync_inj_cnt <= sync_inj_cnt + 1;
    end
  end

  // ---------------- main stimulus --------------------------------------------
  int t;
  int ok_before, irq_before, crc_wire_before;

  initial begin
    // (a) reset / initial state
    rst_n = 0;
    repeat (10) @(posedge clk);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq high during reset");
    end
    if (tx_p !== 1'b0) begin
      errors++; $display("ERROR: tx_p not idle during reset");
    end
    if (dut.phy_ready !== 1'b0) begin
      errors++; $display("ERROR: phy_ready high right after reset");
    end
    rst_n = 1;

    // (b) OOB handshake must complete -> PHY READY
    t = 0;
    while (!dut.phy_ready && t < 20000) begin @(posedge clk); t++; end
    if (!dut.phy_ready) begin
      errors++; $display("ERROR: OOB sequence did not reach PHY READY");
    end else begin
      $display("INFO: OOB complete, PHY READY after %0d clks", t);
    end
    if (irq_cnt != 0) begin
      errors++; $display("ERROR: irq during OOB/link bring-up");
    end

    // (c) >=4 successful write + read-verify loopback transactions, checked
    // at the regfile AND by the independent wire monitor
    t = 0;
    while (dut.ok_cnt < 6 && t < 80000) begin @(posedge clk); t++; end
    if (dut.ok_cnt < 6) begin
      errors++; $display("ERROR: fewer than 6 verified write/read transactions (%0d)",
                         dut.ok_cnt);
    end
    repeat (300) @(posedge clk);
    for (int a = 0; a < 4; a++) begin
      if (dut.regs[a] !== exp_data(a)) begin
        errors++;
        $display("ERROR: regfile[%0d] got=%h exp=%h", a, dut.regs[a], exp_data(a));
      end
    end
    if (frames_checked < 12) begin
      errors++;
      $display("ERROR: wire monitor checked fewer than 12 frames (%0d)", frames_checked);
    end
    if (crc_checked < 12) begin
      errors++;
      $display("ERROR: wire monitor verified fewer than 12 frame CRCs (%0d)", crc_checked);
    end
    if (nonplain_bits < 2000) begin
      errors++;
      $display("ERROR: line appears unscrambled (nonplain_bits=%0d)", nonplain_bits);
    end
    if (irq_cnt != 0) begin
      errors++; $display("ERROR: irq during clean traffic phase");
    end
    $display("INFO: %0d loopback transactions, %0d wire frames, nonplain_bits=%0d",
             dut.ok_cnt, frames_checked, nonplain_bits);

    // (d) CRC error injection on the next write frame payload
    inj_started = 1'b1;
    irq_before  = irq_cnt;
    ok_before   = dut.ok_cnt;
    arm_crc     = 1'b1;
    t = 0;
    while (!crc_inj_fired && t < 30000) begin @(posedge clk); t++; end
    if (!crc_inj_fired) begin
      errors++; $display("ERROR: CRC injection window never occurred");
    end
    t = 0;
    while (irq_cnt == irq_before && t < 8000) begin @(posedge clk); t++; end
    if (irq_cnt == irq_before) begin
      errors++; $display("ERROR: no irq after CRC error injection");
    end
    if (dut.crc_err_cnt < 1) begin
      errors++; $display("ERROR: crc_err_cnt did not increment");
    end
    repeat (2000) @(posedge clk);
    if (dut.regs[crc_inj_addr] !== crc_inj_old) begin
      errors++;
      $display("ERROR: regfile[%0d] polluted by bad-CRC frame: got=%h exp=%h",
               crc_inj_addr, dut.regs[crc_inj_addr], crc_inj_old);
    end
    // the stale read-back of the dropped write must be caught by the verifier
    t = 0;
    while (dut.mm_cnt < 1 && t < 40000) begin @(posedge clk); t++; end
    if (dut.mm_cnt < 1) begin
      errors++; $display("ERROR: read-verify mismatch of dropped write not caught");
    end
    // link must keep working after the error (back-to-back transactions)
    t = 0;
    while (dut.ok_cnt < ok_before + 2 && t < 80000) begin @(posedge clk); t++; end
    if (dut.ok_cnt < ok_before + 2) begin
      errors++; $display("ERROR: link did not continue after CRC error");
    end

    // (e) sync header violation injection: 8 bad syncs -> loss-of-sync
    mon_gate        = 1'b1;    // wire monitor pauses checks during re-OOB
    irq_before      = irq_cnt;
    ok_before       = dut.ok_cnt;
    crc_wire_before = crc_checked;
    arm_sync        = 1'b1;
    t = 0;
    while (dut.phy_ready && t < 30000) begin @(posedge clk); t++; end
    if (dut.phy_ready) begin
      errors++; $display("ERROR: no loss-of-sync after 8 bad sync headers");
    end
    arm_sync = 1'b0;
    if (sync_inj_cnt < 8) begin
      errors++; $display("ERROR: fewer than 8 sync violations injected (%0d)",
                         sync_inj_cnt);
    end
    if (irq_cnt == irq_before) begin
      errors++; $display("ERROR: no irq on loss-of-sync");
    end
    if (dut.rx_lock !== RX_HUNT_CODE) begin
      errors++; $display("ERROR: rx not back in hunt after loss-of-sync");
    end
    // link must retrain: re-OOB -> PHY READY -> transactions resume
    t = 0;
    while (!dut.phy_ready && t < 40000) begin @(posedge clk); t++; end
    if (!dut.phy_ready) begin
      errors++; $display("ERROR: re-OOB did not complete after loss-of-sync");
    end
    t = 0;
    while (dut.ok_cnt < ok_before + 2 && t < 100000) begin @(posedge clk); t++; end
    if (dut.ok_cnt < ok_before + 2) begin
      errors++; $display("ERROR: no transactions after resync");
    end
    t = 0;
    while (crc_checked <= crc_wire_before && t < 60000) begin @(posedge clk); t++; end
    if (crc_checked <= crc_wire_before) begin
      errors++; $display("ERROR: wire monitor did not re-lock after resync");
    end
    repeat (4000) @(posedge clk);
    mon_gate = 1'b0;
    $display("INFO: resync complete, ok_cnt=%0d crc_err=%0d irq_cnt=%0d",
             dut.ok_cnt, dut.crc_err_cnt, irq_cnt);

    // (f) summary
    if (errors == 0) $display("TEST PASSED: SAS_4__Serial_Attached_SCSI_");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #4000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
