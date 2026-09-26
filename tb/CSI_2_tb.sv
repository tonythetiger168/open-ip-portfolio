// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for CSI_2_top (MIPI CSI-2 RX, packet layer)
// TB plays the camera/CSI-2 transmitter: serial SoT + packets (1 bit/clk),
// with ECC + CRC-16 computed here the same way the spec defines them.
// Checks: reset state / FS-FE short packets / RAW8 long packet line-buffer
// readback / ECC single-bit correction (data + ECC byte) / ECC double-bit
// drop + irq / CRC-16 corruption drop + irq / mid-packet abort / back-to-back
// frames.
// ============================================================================
`timescale 1ns/1ps
module CSI_2_tb;

  logic        clk = 0, rst_n = 0;
  logic        rx_bit = 0, rx_valid = 0;
  logic        irq, frame_active;
  logic [15:0] frame_cnt, line_cnt, last_wc, lb_len;
  logic [7:0]  last_dt;
  logic [3:0]  err_flags;
  logic [8:0]  lb_addr = 0;
  logic [7:0]  lb_rdata;

  int errors = 0;

  CSI_2_top dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .rx_valid(rx_valid),
    .irq(irq), .frame_active(frame_active),
    .frame_cnt(frame_cnt), .line_cnt(line_cnt),
    .last_dt(last_dt), .last_wc(last_wc),
    .err_flags(err_flags), .lb_len(lb_len),
    .lb_addr(lb_addr), .lb_rdata(lb_rdata)
  );

  always #5 clk = ~clk;

  // payload staging memory (camera image line)
  logic [7:0] payload_mem [0:1023];

  // ------------------------------------------------------------------
  // reference models (same math as DUT, written independently)
  // ------------------------------------------------------------------
  function automatic logic [5:0] ecc24(input logic [23:0] d);
    begin
      ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
      ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
      ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
      ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
      ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
      ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    end
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c,
                                             input logic [7:0]  d);
    logic [15:0] v;
    begin
      v = c ^ {8'h00, d};
      for (int k = 0; k < 8; k++)
        v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      crc16_byte = v;
    end
  endfunction

  // ------------------------------------------------------------------
  // lane driving tasks (camera side)
  // ------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] d);
    begin
      for (int i = 0; i < 8; i++) begin
        @(negedge clk);
        rx_valid <= 1'b1;
        rx_bit   <= d[i];
      end
    end
  endtask

  task automatic send_idle(input int n);
    begin
      @(negedge clk);
      rx_valid <= 1'b0;
      rx_bit   <= 1'b0;
      repeat (n) @(negedge clk);
    end
  endtask

  // short packet: DI={VC,DT}, 16-bit data field, ECC
  task automatic send_short(input logic [5:0] dt, input logic [1:0] vc,
                            input logic [15:0] data);
    logic [7:0] b0;
    begin
      b0 = {vc, dt};
      send_byte(8'hB8);
      send_byte(b0);
      send_byte(data[7:0]);
      send_byte(data[15:8]);
      send_byte({2'b00, ecc24({data, b0})});
      send_idle(6);
    end
  endtask

  // long packet from payload_mem[0..wc-1]; hdr_xor/ecc_xor corrupt the
  // header/ECC bytes on the wire; bad_crc flips the footer CRC
  task automatic send_long(input logic [5:0] dt, input logic [1:0] vc,
                           input logic [15:0] wc,
                           input logic [23:0] hdr_xor,
                           input logic [7:0]  ecc_xor,
                           input bit          bad_crc);
    logic [7:0]  b0;
    logic [15:0] c;
    begin
      b0 = {vc, dt};
      c  = 16'hFFFF;
      send_byte(8'hB8);
      send_byte(b0        ^ hdr_xor[7:0]);
      send_byte(wc[7:0]   ^ hdr_xor[15:8]);
      send_byte(wc[15:8]  ^ hdr_xor[23:16]);
      send_byte({2'b00, ecc24({wc, b0})} ^ ecc_xor);
      for (int i = 0; i < wc; i++) begin
        send_byte(payload_mem[i]);
        c = crc16_byte(c, payload_mem[i]);
      end
      if (bad_crc) c = c ^ 16'hA5A5;
      send_byte(c[7:0]);
      send_byte(c[15:8]);
      send_idle(6);
    end
  endtask

  // compare DUT line buffer against payload_mem[0..len-1]
  task automatic check_line(input int len, input string tag);
    begin
      if (lb_len !== 16'(len)) begin
        errors++;
        $display("ERROR: %s lb_len=%0d exp=%0d", tag, lb_len, len);
      end
      for (int i = 0; i < len; i++) begin
        lb_addr = 9'(i);
        #1;
        if (lb_rdata !== payload_mem[i]) begin
          errors++;
          $display("ERROR: %s lb[%0d] got=%02h exp=%02h",
                   tag, i, lb_rdata, payload_mem[i]);
        end
      end
    end
  endtask

  task automatic check(input bit cond, input string tag);
    begin
      if (!cond) begin
        errors++;
        $display("ERROR: %s", tag);
      end
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int CSI_FSM_TOTAL = 8;   // S_SYNC..S_CRC1 (rtl enum)
  logic [7:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.state;  // hierarchical FSM probe

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: sample DUT state register every clock
  always @(posedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit        first_cycle = 1;  // skip the very first posedge (DUT reset
                               // values land in that NBA region)
  logic [15:0] fc_q = 0;
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(irq === 1'b0 && frame_active === 1'b0 && frame_cnt === 16'h0 &&
                line_cnt === 16'h0 && lb_len === 16'h0 && err_flags === 4'h0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: payload counter never exceeds the programmed word count
      sva_check(dut.pay_cnt <= dut.wc, "A2 pay_cnt within wc");
      // A3: committed line length bounded by the line buffer depth
      sva_check(lb_len <= 16'd512, "A3 lb_len bounded");
      // A4: frame counter never decreases
      sva_check(frame_cnt >= fc_q, "A4 frame_cnt monotone");
      // A5: an active frame implies at least one frame was started
      sva_check(!frame_active || (frame_cnt >= 16'd1), "A5 active implies FS");
      // A6: line buffer read port tracks the array combinationally
      sva_check(lb_rdata === dut.line_buf[lb_addr], "A6 lb read port");
      // A7: payload phase only exists for non-zero word counts
      sva_check((dut_state != 3'd5) || (dut.wc != 16'h0), "A7 S_PAY has wc");
    end
    fc_q <= frame_cnt;
  end
`endif

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    // ---- reset ----
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // (1) reset state
    check(frame_cnt == 0 && line_cnt == 0 && irq == 1'b0 &&
          frame_active == 1'b0 && lb_len == 0, "reset state");

    // ---- frame 0: FS + 2 RAW8 lines + FE ----
    for (int i = 0; i < 16; i++) payload_mem[i] = 8'h10 + i[7:0];
    send_short(6'h00, 2'd0, 16'd0);                 // FS
    check(frame_cnt == 1 && frame_active == 1'b1 && line_cnt == 0,
          "FS: frame_cnt=1 active");
    send_long(6'h2B, 2'd0, 16'd16, 24'h0, 8'h0, 0); // RAW8 line 0
    check(line_cnt == 1 && irq == 1'b0, "line0 committed");
    check(last_dt == 8'h2B && last_wc == 16'd16, "line0 DT/WC status");
    check_line(16, "line0");

    for (int i = 0; i < 32; i++) payload_mem[i] = 8'hA0 + i[7:0];
    send_long(6'h2B, 2'd0, 16'd32, 24'h0, 8'h0, 0); // RAW8 line 1
    check(line_cnt == 2, "line1 committed");
    check_line(32, "line1");

    send_short(6'h01, 2'd0, 16'd0);                 // FE
    check(frame_active == 1'b0 && frame_cnt == 1, "FE: frame end");

    // ---- frame 1: ECC single-bit correction ----
    for (int i = 0; i < 8; i++) payload_mem[i] = 8'h40 + i[7:0];
    send_short(6'h00, 2'd0, 16'd1);                 // FS frame 1
    check(frame_cnt == 2 && line_cnt == 0, "FS frame1");
    // flip header bit 15 (WC[7]) on the wire: must be corrected
    send_long(6'h2B, 2'd0, 16'd8, 24'h008000, 8'h00, 0);
    check(line_cnt == 1 && irq == 1'b0 && err_flags[3] == 1'b1,
          "ECC single-bit (WC) corrected");
    check(last_wc == 16'd8, "corrected WC=8");
    check_line(8, "ecc-corr line");
    // flip one ECC-byte bit on the wire: data untouched, counted corrected
    send_long(6'h2B, 2'd0, 16'd8, 24'h000000, 8'h10, 0);
    check(line_cnt == 2 && irq == 1'b0, "ECC single-bit (ECC byte) accepted");
    check_line(8, "ecc-byte line");

    // ---- ECC double-bit error: uncorrectable, drop + irq ----
    send_long(6'h2B, 2'd0, 16'd8, 24'h000003, 8'h00, 0);
    check(irq == 1'b1 && err_flags[1] == 1'b1 && line_cnt == 2,
          "ECC double-bit dropped + irq");

    // ---- CRC-16 corruption: drop + irq, then recovery ----
    for (int i = 0; i < 8; i++) payload_mem[i] = 8'h70 + i[7:0];
    send_long(6'h2B, 2'd0, 16'd8, 24'h0, 8'h0, 1);  // bad CRC
    check(irq == 1'b1 && err_flags[0] == 1'b1 && line_cnt == 2,
          "CRC bad dropped + irq");
    check(lb_len == 16'd8, "bad CRC line not committed (lb_len kept)");
    send_long(6'h2B, 2'd0, 16'd8, 24'h0, 8'h0, 0);  // good again
    check(irq == 1'b0 && line_cnt == 3, "good packet clears irq");
    check_line(8, "recovery line");

    // ---- mid-packet abort (link idle before packet end) ----
    send_byte(8'hB8);
    send_byte(8'h2B);
    send_idle(6);                                   // abort in header
    check(err_flags[2] == 1'b1, "mid-packet abort flagged");
    check(line_cnt == 3, "abort does not commit");

    // ---- back-to-back traffic: 3 lines, no gap issues ----
    for (int i = 0; i < 12; i++) payload_mem[i] = 8'hC0 + i[7:0];
    send_long(6'h2B, 2'd0, 16'd12, 24'h0, 8'h0, 0);
    send_long(6'h2B, 2'd0, 16'd12, 24'h0, 8'h0, 0);
    send_long(6'h2B, 2'd0, 16'd12, 24'h0, 8'h0, 0);
    check(line_cnt == 6 && irq == 1'b0, "back-to-back lines");
    check_line(12, "b2b line");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized transactions. Classes: random frames (FS + 1-3 RAW
    // long packets with random VC/DT/WC/payload incl. boundary WC=0/512/
    // 520 + FE) with frame/line-count and line-buffer self-checks; short
    // packet mixes (FS/LE/generic/FE); error injection (round-robin):
    // ECC single-bit in header / in ECC byte (corrected), ECC double-bit
    // (drop + irq), CRC-16 corruption (drop + irq), mid-packet abort at
    // a random position. A software scoreboard tracks the expected
    // frame_cnt / line_cnt across the whole phase.
    begin : crv_phase
      int n_frm = 0, n_shrt = 0, n_e1h = 0, n_e1e = 0, n_e2 = 0, n_ecrc = 0;
      int n_abt = 0;
      int roll, eroll = 0, nl, wc_c, pos;
      int m_fc, m_lc;                       // scoreboard counts
      logic [5:0] dt_c;
      logic [1:0] vc_c;
      logic [23:0] hx;
      logic [7:0]  ex;
      m_fc = frame_cnt;
      m_lc = line_cnt;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 29);
        if (roll < 11) begin
          // ---- random frame: FS + 1-3 long packets + FE ----
          n_frm++;
          vc_c = 2'($urandom_range(0, 3));
          send_short(6'h00, vc_c, 16'($urandom_range(0, 65535)));   // FS
          m_fc++;
          m_lc = 0;
          if (frame_cnt !== 16'(m_fc) || frame_active !== 1'b1 ||
              line_cnt !== 16'd0) begin
            errors++; $display("ERROR: CRV FS counts got fc=%0d lc=%0d exp fc=%0d",
                               frame_cnt, line_cnt, m_fc);
          end
          nl = 1 + $urandom_range(0, 2);
          for (int l = 0; l < nl; l++) begin
            roll = $urandom_range(0, 9);
            if (roll == 0)      wc_c = 0;               // boundary: empty
            else if (roll == 1) wc_c = 512;             // boundary: full LB
            else if (roll == 2) wc_c = 520;             // boundary: > LB
            else if (roll == 3) wc_c = 200;             // boundary: mid
            else if (roll == 4) wc_c = 300;             // boundary: mid
            else                wc_c = 1 + $urandom_range(0, 63);
            dt_c = 6'h10 + 6'($urandom_range(0, 47));   // long-packet DT
            for (int i = 0; i < wc_c && i < 1024; i++)
              payload_mem[i] = 8'($urandom_range(0, 255));
            send_long(dt_c, vc_c, 16'(wc_c), 24'h0, 8'h0, 0);
            m_lc++;
            if (line_cnt !== 16'(m_lc) || irq !== 1'b0) begin
              errors++; $display("ERROR: CRV line commit lc=%0d exp=%0d irq=%b",
                                 line_cnt, m_lc, irq);
            end
            if (last_wc !== 16'(wc_c)) begin
              errors++; $display("ERROR: CRV last_wc got=%0d exp=%0d",
                                 last_wc, wc_c);
            end
            check_line(wc_c > 512 ? 512 : wc_c, "CRV line");
          end
          send_short(6'h01, vc_c, 16'h0);                          // FE
          if (frame_active !== 1'b0 || frame_cnt !== 16'(m_fc)) begin
            errors++; $display("ERROR: CRV FE state");
          end
        end else if (roll < 15) begin
          // ---- short-packet mix: FS + LE/generic shorts + FE ----
          n_shrt++;
          vc_c = 2'($urandom_range(0, 3));
          send_short(6'h00, vc_c, 16'h0);
          m_fc++;
          m_lc = 0;
          nl = 1 + $urandom_range(0, 5);
          for (int l = 0; l < nl; l++) begin
            dt_c = 6'($urandom_range(0, 15));           // short-packet DT
            send_short(dt_c, vc_c, 16'($urandom_range(0, 65535)));
            if (dt_c == 6'h03) m_lc++;                  // DT_LE
            if (dt_c == 6'h00) begin m_fc++; m_lc = 0; end  // nested FS
            if (dt_c == 6'h01) ;                        // FE: active clears
          end
          send_short(6'h01, vc_c, 16'h0);
          if (frame_cnt !== 16'(m_fc) || line_cnt !== 16'(m_lc)) begin
            errors++; $display("ERROR: CRV short counts fc=%0d/%0d lc=%0d/%0d",
                               frame_cnt, m_fc, line_cnt, m_lc);
          end
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV irq set during short packets");
          end
        end else begin
          // ---- error-injection classes (round-robin) ----
          vc_c = 2'd0;
          for (int i = 0; i < 16; i++)
            payload_mem[i] = 8'($urandom_range(0, 255));
          case (eroll)
            0: begin
              // ECC single-bit in the 24-bit header: corrected + commit
              n_e1h++;
              hx = 24'h1 << $urandom_range(0, 23);
              send_long(6'h2B, vc_c, 16'd16, hx, 8'h0, 0);
              m_lc++;
              if (line_cnt !== 16'(m_lc) || irq !== 1'b0 ||
                  err_flags[3] !== 1'b1) begin
                errors++; $display("ERROR: CRV ECC-1bit hdr not corrected");
              end
              check_line(16, "CRV ecc1h");
            end
            1: begin
              // ECC single-bit in the ECC byte: accepted + commit
              n_e1e++;
              ex = 8'h1 << $urandom_range(0, 5);
              send_long(6'h2B, vc_c, 16'd16, 24'h0, ex, 0);
              m_lc++;
              if (line_cnt !== 16'(m_lc) || irq !== 1'b0) begin
                errors++; $display("ERROR: CRV ECC-1bit ecc not accepted");
              end
              check_line(16, "CRV ecc1e");
            end
            2: begin
              // ECC double-bit: uncorrectable -> drop + irq, line kept
              n_e2++;
              hx = (24'h1 << $urandom_range(0, 11)) |
                   (24'h1 << $urandom_range(12, 23));
              send_long(6'h2B, vc_c, 16'd16, hx, 8'h0, 0);
              if (irq !== 1'b1 || err_flags[1] !== 1'b1 ||
                  line_cnt !== 16'(m_lc)) begin
                errors++; $display("ERROR: CRV ECC-2bit not dropped");
              end
              send_long(6'h2B, vc_c, 16'd16, 24'h0, 8'h0, 0);  // recovery
              m_lc++;
              if (irq !== 1'b0 || line_cnt !== 16'(m_lc)) begin
                errors++; $display("ERROR: CRV ECC-2bit recovery failed");
              end
              check_line(16, "CRV ecc2-rec");
            end
            3: begin
              // CRC-16 corruption: drop + irq, lb_len kept
              n_ecrc++;
              send_long(6'h2B, vc_c, 16'd16, 24'h0, 8'h0, 1);
              if (irq !== 1'b1 || err_flags[0] !== 1'b1 ||
                  line_cnt !== 16'(m_lc)) begin
                errors++; $display("ERROR: CRV bad CRC not dropped");
              end
              send_long(6'h2B, vc_c, 16'd16, 24'h0, 8'h0, 0);  // recovery
              m_lc++;
              if (irq !== 1'b0 || line_cnt !== 16'(m_lc)) begin
                errors++; $display("ERROR: CRV CRC recovery failed");
              end
              check_line(16, "CRV crc-rec");
            end
            default: begin
              // mid-packet abort at a random position (header/payload)
              n_abt++;
              pos = $urandom_range(0, 5);
              send_byte(8'hB8);
              send_byte(8'h2B);
              if (pos > 0) send_byte(8'd16);
              if (pos > 1) send_byte(8'h00);
              if (pos > 2) send_byte({2'b00, ecc24({16'd16, 8'h2B})});
              if (pos > 3) send_byte(payload_mem[0]);
              if (pos > 4) send_byte(payload_mem[1]);
              send_idle(6);                                // abort
              if (err_flags[2] !== 1'b1 || line_cnt !== 16'(m_lc)) begin
                errors++; $display("ERROR: CRV abort not flagged");
              end
              send_long(6'h2B, vc_c, 16'd16, 24'h0, 8'h0, 0);  // recovery
              m_lc++;
              if (line_cnt !== 16'(m_lc)) begin
                errors++; $display("ERROR: CRV abort recovery failed");
              end
              check_line(16, "CRV abt-rec");
            end
          endcase
          eroll = (eroll + 1) % 5;
        end
      end
      $display("CRV: 120 txns (frames=%0d shorts=%0d | ecc1h=%0d ecc1e=%0d ecc2=%0d crc=%0d abort=%0d)",
               n_frm, n_shrt, n_e1h, n_e1e, n_e2, n_ecrc, n_abt);

      // ---- coverage-closure sweep --------------------------------------
      // (a) exhaustive ECC syndrome decode: single-bit error at every one
      //     of the 24 header positions and all 6 ECC-byte bits -> every
      //     entry of the ecc_bit decode table; all packets must correct
      //     and commit (scoreboard updated).
      // (b) ECC-corrected SHORT packets (FS/LE/generic/FE) -> corrected-
      //     path short-packet case arms.
      // (c) 2100 line-end shorts in one frame -> line_cnt[11:0] toggle.
      // (d) 600 FS/FE pairs -> frame_cnt[9:0] toggle.
      send_short(6'h00, 2'd0, 16'h0);                      // FS
      m_fc++;
      m_lc = 0;
      for (int eb = 0; eb < 24; eb++) begin
        for (int i = 0; i < 8; i++)
          payload_mem[i] = 8'($urandom_range(0, 255));
        send_long(6'h2B, 2'd0, 16'd8, 24'h1 << eb, 8'h0, 0);
        m_lc++;
        if (line_cnt !== 16'(m_lc) || irq !== 1'b0) begin
          errors++; $display("ERROR: sweep ECC hdr bit %0d not corrected", eb);
        end
        check_line(8, "sweep ecc-hdr");
      end
      for (int eb = 0; eb < 6; eb++) begin
        for (int i = 0; i < 8; i++)
          payload_mem[i] = 8'($urandom_range(0, 255));
        send_long(6'h2B, 2'd0, 16'd8, 24'h0, 8'h1 << eb, 0);
        m_lc++;
        if (line_cnt !== 16'(m_lc) || irq !== 1'b0) begin
          errors++; $display("ERROR: sweep ECC byte bit %0d not accepted", eb);
        end
        check_line(8, "sweep ecc-byte");
      end
      send_short(6'h01, 2'd0, 16'h0);                      // FE
      // corrected short packets: FS, LE, generic (dt 0x08), FE
      send_short(6'h00, 2'd0, 16'h0);
      m_fc++;
      m_lc = 0;
      // single-bit header error on an FS short packet (data field = 0)
      begin
        logic [7:0] b0;
        logic [15:0] dd;
        b0 = {2'd0, 6'h00};
        dd = 16'h0;
        send_byte(8'hB8);
        send_byte(b0 ^ 8'h01);                              // flip bit 0
        send_byte(dd[7:0]);
        send_byte(dd[15:8]);
        send_byte({2'b00, ecc24({dd, b0})});
        send_idle(6);
      end
      m_fc++;                                               // corrected FS
      m_lc = 0;
      if (frame_cnt !== 16'(m_fc) || frame_active !== 1'b1) begin
        errors++; $display("ERROR: sweep corrected FS failed");
      end
      // corrected LE short (flip WC-data bit 8)
      begin
        logic [7:0] b0;
        logic [15:0] dd;
        b0 = {2'd0, 6'h03};
        dd = 16'h0;
        send_byte(8'hB8);
        send_byte(b0);
        send_byte(dd[7:0]);
        send_byte(dd[15:8] ^ 8'h01);                        // flip bit 8
        send_byte({2'b00, ecc24({dd, b0})});
        send_idle(6);
      end
      m_lc++;                                               // corrected LE
      if (line_cnt !== 16'(m_lc)) begin
        errors++; $display("ERROR: sweep corrected LE failed");
      end
      // corrected generic short (dt 0x08: default arm, no side effect)
      begin
        logic [7:0] b0;
        logic [15:0] dd;
        b0 = {2'd0, 6'h08};
        dd = 16'h0;
        send_byte(8'hB8);
        send_byte(b0 ^ 8'h20);                              // flip bit 5
        send_byte(dd[7:0]);
        send_byte(dd[15:8]);
        send_byte({2'b00, ecc24({dd, b0})});
        send_idle(6);
      end
      if (line_cnt !== 16'(m_lc) || frame_cnt !== 16'(m_fc)) begin
        errors++; $display("ERROR: sweep corrected generic changed counts");
      end
      // corrected FE short (flip bit 1): frame must close
      begin
        logic [7:0] b0;
        logic [15:0] dd;
        b0 = {2'd0, 6'h01};
        dd = 16'h0;
        send_byte(8'hB8);
        send_byte(b0 ^ 8'h02);                              // flip bit 1
        send_byte(dd[7:0]);
        send_byte(dd[15:8]);
        send_byte({2'b00, ecc24({dd, b0})});
        send_idle(6);
      end
      if (frame_active !== 1'b0) begin
        errors++; $display("ERROR: sweep corrected FE failed");
      end
      // corrected long packets with wide headers: toggle hc[17:0] both
      // directions (dt/vc/wc combinations chosen for bit coverage)
      for (int i = 0; i < 8; i++)
        payload_mem[i] = 8'($urandom_range(0, 255));
      send_long(6'h3F, 2'd3, 16'd300, 24'h000008, 8'h0, 0); // flip bit 3
      m_lc++;
      send_long(6'h2B, 2'd0, 16'd203, 24'h010000, 8'h0, 0); // flip bit 16
      m_lc++;
      send_long(6'h2B, 2'd0, 16'd520, 24'h080000, 8'h0, 0); // flip bit 23
      m_lc++;
      if (line_cnt !== 16'(m_lc) || irq !== 1'b0) begin
        errors++; $display("ERROR: sweep wide-header corrected longs failed");
      end
      send_short(6'h01, 2'd0, 16'h0);                      // FE
      // (c) line_cnt walk: 4200 line-end shorts in one frame
      send_short(6'h00, 2'd0, 16'h0);
      m_fc++;
      m_lc = 0;
      for (int l = 0; l < 4200; l++) send_short(6'h03, 2'd0, 16'(l));
      m_lc = 4200;
      if (line_cnt !== 16'(m_lc)) begin
        errors++; $display("ERROR: sweep line_cnt got=%0d exp=%0d",
                           line_cnt, m_lc);
      end
      send_short(6'h01, 2'd0, 16'h0);
      // (d) frame_cnt walk: 1100 FS/FE pairs
      for (int f = 0; f < 1100; f++) begin
        send_short(6'h00, 2'd0, 16'(f));
        send_short(6'h01, 2'd0, 16'h0);
      end
      m_fc += 1100;
      if (frame_cnt !== 16'(m_fc)) begin
        errors++; $display("ERROR: sweep frame_cnt got=%0d exp=%0d",
                           frame_cnt, m_fc);
      end
      $display("COV_CLOSURE: ECC syndrome sweep + corrected shorts + line/frame walks done");
    end
`endif

    // ---- report ----
    if (errors == 0) $display("TEST PASSED: CSI_2");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CSI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CSI_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (8000) #1000;    // 8 ms in 1-us chunks
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #500000;
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
