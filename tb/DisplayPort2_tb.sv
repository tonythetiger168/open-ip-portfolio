// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for DisplayPort2_top -- DisplayPort source
//  TB plays the sink: Manchester-II AUX responder (DPCD window + EDID ROM),
//  8b/10b main-link decoder with running-disparity tracking, link-training
//  status model (CR_DONE / EQ_DONE derived from the actual lane content).
// Checks:
//  1. reset state (lane idle, no aux, no irq)
//  2. AUX read/write DPCD compare (write values, ACK replies, final DPCD)
//  3. link-training sequence code-by-code (D10.2 CR burst, K28.5+D10.2 TPS1,
//     every symbol a valid 8b/10b code with correct running disparity)
//  4. EDID read-back via I2C-over-AUX (first 8 bytes)
//  5. video frame decode: BS/pixels/BE/SS/MSA(4 dwords)/SE/fill, 2+ frames
//  6. training-failure injection: sink never replies -> retries + irq
//  7. Manchester violation injection on AUX reply -> retry & recover
// ============================================================================
`timescale 1ns/1ps
module DisplayPort2_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic lane_p, lane_valid, link_trained, train_fail;
  logic aux_tx_p, aux_tx_en;
  logic sink_present;
  logic [63:0] edid;
  logic edid_valid;
  logic irq;

  int errors = 0;

  // ------------------------- sink AUX line model -------------------------
  logic sink_drv = 0;
  logic sink_val = 1;
  wire  aux_line = aux_tx_en ? aux_tx_p : (sink_drv ? sink_val : 1'b1);

  DisplayPort2_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .lane_p(lane_p), .lane_valid(lane_valid),
    .link_trained(link_trained), .train_fail(train_fail),
    .aux_tx_p(aux_tx_p), .aux_tx_en(aux_tx_en), .aux_rx_p(aux_line),
    .sink_present(sink_present),
    .edid(edid), .edid_valid(edid_valid),
    .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // =====================================================================
  // FSM probe: lt_state(14) + pat(4) + aux_state(14) = 32
  localparam int DP2_FSM_TOTAL = 32;
  logic [31:0] fsm_seen = '0;
  always @(posedge clk) begin
    if (dut.lt_state  < 14) fsm_seen[dut.lt_state]        <= 1'b1;
    if (dut.pat       < 4)  fsm_seen[14 + dut.pat]        <= 1'b1;
    if (dut.aux_state < 14) fsm_seen[18 + dut.aux_state]  <= 1'b1;
  end

  int sva_total = 0, sva_fail = 0;
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

  task automatic cchk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (t=%0t)", msg, $time);
    end
  endtask

  // output-invariant assertion suite (sampled at posedge, pre-NBA coherent)
  int  rst_cyc = 0;
  logic fail_q = 1'b0, trained_q = 1'b0, edidv_q = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: idle in reset
      if (rst_cyc > 0)
        sva_check((lane_valid === 1'b0) && (link_trained === 1'b0) &&
                  (aux_tx_en === 1'b0) && (irq === 1'b0), "A1 reset: idle");
      rst_cyc++;
    end else begin
      // A2: irq is exactly train_fail
      sva_check(irq === train_fail, "A2 irq == train_fail");
      // A3: failure and training success are mutually exclusive
      sva_check(!(train_fail && link_trained), "A3 fail/trained exclusive");
      // A4: train_fail is sticky until reset
      if (fail_q) sva_check(train_fail === 1'b1, "A4 train_fail sticky");
      // A5: link_trained is sticky until reset
      if (trained_q) sva_check(link_trained === 1'b1, "A5 link_trained sticky");
      // A6: edid_valid sticky + result is the EDID header constant
      if (edidv_q) begin
        sva_check(edid_valid === 1'b1, "A6 edid_valid sticky");
        sva_check(edid === 64'h00FF_FFFF_FFFF_FF00, "A6b edid constant");
      end
      // A7: FSM encodings in range
      sva_check((dut.lt_state < 14) && (dut.aux_state < 14) && (dut.pat < 4),
                "A7 FSM encodings valid");
    end
    fail_q    <= train_fail;
    trained_q <= link_trained;
    edidv_q   <= edid_valid;
  end
`endif

  // ------------------------- 8b/10b reference (copy of DUT) -------------------------
  function automatic logic [10:0] enc_8b10b(input logic [7:0] d,
                                            input logic       k,
                                            input logic       rd);
    logic [4:0] d5;
    logic [2:0] d3;
    logic [5:0] s6;
    logic [3:0] s4;
    logic       rd1, rd2;
    logic [2:0] ones6;
    logic [1:0] ones4;
    logic       use_a7;
    begin
      d5 = d[4:0];
      d3 = d[7:5];
      if (k && d5 == 5'd28) begin
        s6 = 6'b001111;
        if (rd) s6 = ~s6;
      end else begin
        case (d5)
          5'd0 : s6 = 6'b100111;  5'd1 : s6 = 6'b011101;
          5'd2 : s6 = 6'b101101;  5'd3 : s6 = 6'b110001;
          5'd4 : s6 = 6'b110101;  5'd5 : s6 = 6'b101001;
          5'd6 : s6 = 6'b011001;  5'd7 : s6 = 6'b111000;
          5'd8 : s6 = 6'b111001;  5'd9 : s6 = 6'b100101;
          5'd10: s6 = 6'b010101;  5'd11: s6 = 6'b110100;
          5'd12: s6 = 6'b001101;  5'd13: s6 = 6'b101100;
          5'd14: s6 = 6'b011100;  5'd15: s6 = 6'b010111;
          5'd16: s6 = 6'b011011;  5'd17: s6 = 6'b100011;
          5'd18: s6 = 6'b010011;  5'd19: s6 = 6'b110010;
          5'd20: s6 = 6'b001011;  5'd21: s6 = 6'b101010;
          5'd22: s6 = 6'b011010;  5'd23: s6 = 6'b111010;
          5'd24: s6 = 6'b110011;  5'd25: s6 = 6'b100110;
          5'd26: s6 = 6'b010110;  5'd27: s6 = 6'b110110;
          5'd28: s6 = 6'b001110;  5'd29: s6 = 6'b101110;
          5'd30: s6 = 6'b011110;  default: s6 = 6'b101011;
        endcase
        if (rd && (d5 == 5'd0  || d5 == 5'd1  || d5 == 5'd2  || d5 == 5'd4  ||
                   d5 == 5'd7  || d5 == 5'd8  || d5 == 5'd15 || d5 == 5'd16 ||
                   d5 == 5'd23 || d5 == 5'd24 || d5 == 5'd27 || d5 == 5'd29 ||
                   d5 == 5'd30 || d5 == 5'd31))
          s6 = ~s6;
      end
      ones6 = s6[0] + s6[1] + s6[2] + s6[3] + s6[4] + s6[5];
      if (ones6 == 3) rd1 = rd;
      else            rd1 = (ones6 > 3);
      use_a7 = (d3 == 3'd7) &&
               (k || (!rd1 && s6[0] && s6[1]) || (rd1 && !s6[0] && !s6[1]));
      if (use_a7) begin
        s4 = rd1 ? 4'b1000 : 4'b0111;
      end else begin
        case (d3)
          3'd0: s4 = 4'b1011;  3'd1: s4 = 4'b1001;
          3'd2: s4 = 4'b0101;  3'd3: s4 = 4'b1100;
          3'd4: s4 = 4'b1101;  3'd5: s4 = 4'b1010;
          3'd6: s4 = 4'b0110;  default: s4 = 4'b1110;
        endcase
        if (rd1 && (d3 == 3'd0 || d3 == 3'd3 || d3 == 3'd4 || d3 == 3'd7))
          s4 = ~s4;
      end
      ones4 = s4[0] + s4[1] + s4[2] + s4[3];
      if (ones4 == 2) rd2 = rd1;
      else            rd2 = (ones4 > 2);
      enc_8b10b = {rd2, s6, s4};
    end
  endfunction

  // decode table: index {rd_in, code[9:0]}
  logic [7:0] dec_data [0:2047];
  logic       dec_k    [0:2047];
  logic       dec_rd   [0:2047];
  logic       dec_ok   [0:2047];

  initial begin : build_tables
    logic [10:0] e;
    int idx;
    logic [7:0] kc;
    for (int i = 0; i < 2048; i++) dec_ok[i] = 1'b0;
    for (int rd = 0; rd < 2; rd++) begin
      for (int d = 0; d < 256; d++) begin
        e = enc_8b10b(d[7:0], 1'b0, rd[0]);
        idx = {rd[0], e[9:0]};
        dec_ok[idx] = 1'b1; dec_data[idx] = d[7:0];
        dec_k[idx] = 1'b0;    dec_rd[idx] = e[10];
      end
      for (int j = 0; j < 5; j++) begin
        case (j)
          0: kc = 8'hBC;  1: kc = 8'hF7;  2: kc = 8'hFB;
          3: kc = 8'hFD;  default: kc = 8'hFE;
        endcase
        e = enc_8b10b(kc, 1'b1, rd[0]);
        idx = {rd[0], e[9:0]};
        dec_ok[idx] = 1'b1; dec_data[idx] = kc;
        dec_k[idx] = 1'b1;  dec_rd[idx] = e[10];
      end
    end
    // anchor vectors (guard against common-mode table bugs)
    if (enc_8b10b(8'h4A, 1'b0, 1'b0) !== 11'b0_0101010101) begin
      errors++; $display("ERROR: anchor D10.2 encode mismatch");
    end
    if (enc_8b10b(8'hBC, 1'b1, 1'b0) !== 11'b1_0011111010) begin
      errors++; $display("ERROR: anchor K28.5 encode mismatch");
    end
  end

  // ------------------------- sink model state -------------------------
  logic [7:0]   dpcd [0:15];
  logic [7:0]   edid_offset;
  logic         sink_enable = 0;
  logic         corrupt_armed = 0;
  logic         corrupt_happened = 0;
  int           aux_req_count = 0;
  int           aux_nack_count = 0;
  logic         saw_tp_cr  = 0;
  logic         saw_tp_tps = 0;
`ifdef VERILATOR
  // v2.5 CRV knobs: while nack_storm is set every sink reply is a NACK
  // (reply 4'h1, no data); nack_fired counts delivered injected NACKs.
  logic         nack_storm = 0;
  int           nack_fired = 0;
`endif

  // byte i at [8*i +: 8]; first 8 bytes = real EDID header
  localparam logic [127:0] EDID_ROM = {64'h1234_5678_9ABC_DEF0,
                                       64'h00FF_FFFF_FFFF_FF00};

  // ------------------------- main-link monitor -------------------------
  logic        cr_done = 0, tps_done = 0;
  int          cr_run = 0, cr_run_max = 0;
  int          tps_seq = 0;
  int          tps_pos = 0;
  // video checker
  logic        video_check_en = 0;
  logic        vinframe = 0, vlearned = 0, learn_frame = 0;
  int          vpos = 0;
  logic [7:0]  fc_exp = 0;
  int          frames_ok = 0;
  int          viol_count = 0;

  task automatic mon_symbol(input logic [7:0] d, input logic k);
    logic [7:0] exp_msa;
    begin
      // --- training pattern tracking (feeds sink lane-status model) ---
      if (!k && d == 8'h4A) begin
        cr_run++;
        if (cr_run > cr_run_max) cr_run_max = cr_run;
      end else begin
        cr_run = 0;
      end
      if (cr_run >= 16) cr_done = 1;
      case (tps_pos)
        0: tps_pos = (k && d == 8'hBC) ? 1 : 0;
        1: tps_pos = (!k && d == 8'h4A) ? 2 : ((k && d == 8'hBC) ? 1 : 0);
        2: tps_pos = (!k && d == 8'h4A) ? 3 : ((k && d == 8'hBC) ? 1 : 0);
        default: begin
          if (!k && d == 8'h4A) begin
            tps_seq++;
            tps_pos = 0;
          end else begin
            tps_pos = (k && d == 8'hBC) ? 1 : 0;
          end
        end
      endcase
      if (tps_seq >= 4) tps_done = 1;
      // --- video frame checker (40-symbol lines) ---
      if (video_check_en) begin
        if (!vinframe) begin
          if (k && d == 8'hFB) begin
            vinframe = 1;
            vpos = 1;
            if (!vlearned) learn_frame = 1;
          end
        end else begin
          if (vpos >= 1 && vpos <= 16) begin          // pixels
            if (!learn_frame &&
                (k || d !== (fc_exp + vpos[7:0] - 8'd1))) begin
              errors++;
              $display("ERROR: video pixel %0d got k=%b d=%02h exp=%02h",
                       vpos-1, k, d, fc_exp + vpos[7:0] - 8'd1);
            end
          end else if (vpos == 17) begin              // BE
            if (!(k && d == 8'hBC)) begin
              errors++; $display("ERROR: BE expected, got k=%b d=%02h", k, d);
            end
          end else if (vpos == 18) begin              // SS
            if (!(k && d == 8'hFD)) begin
              errors++; $display("ERROR: SS expected, got k=%b d=%02h", k, d);
            end
          end else if (vpos >= 19 && vpos <= 34) begin // MSA 4 dwords
            case (vpos - 19)
              0:  exp_msa = 8'h01;
              1:  exp_msa = fc_exp;
              2:  exp_msa = 8'h00;
              3:  exp_msa = 8'h00;
              4:  exp_msa = 8'h56;
              5:  exp_msa = 8'h34;
              6:  exp_msa = 8'h12;
              7:  exp_msa = 8'h00;
              8:  exp_msa = 8'h40;
              9:  exp_msa = 8'h01;
              10: exp_msa = 8'h00;
              11: exp_msa = 8'h00;
              12: exp_msa = 8'hF0;
              13: exp_msa = 8'h00;
              14: exp_msa = 8'h00;
              default: exp_msa = 8'h00;
            endcase
            if (vpos == 20 && learn_frame) begin
              fc_exp = d + 8'd1;         // learn frame count
            end else if (!learn_frame && (k || d !== exp_msa)) begin
              errors++;
              $display("ERROR: MSA byte %0d got k=%b d=%02h exp=%02h",
                       vpos-19, k, d, exp_msa);
            end
          end else if (vpos == 35) begin              // SE
            if (!(k && d == 8'hFE)) begin
              errors++; $display("ERROR: SE expected, got k=%b d=%02h", k, d);
            end
          end else if (vpos == 36) begin              // FS
            if (!(k && d == 8'hF7)) begin
              errors++; $display("ERROR: FS expected, got k=%b d=%02h", k, d);
            end
          end else begin                              // 3 x D00.0 fill
            if (k || d !== 8'h00) begin
              errors++; $display("ERROR: fill D00.0 expected, got k=%b d=%02h", k, d);
            end
          end
          vpos++;
          if (vpos == 40) begin
            vpos = 0;
            vinframe = 0;
            if (learn_frame) begin
              learn_frame = 0;
              vlearned = 1;
            end else begin
              frames_ok++;
              fc_exp++;
            end
          end
        end
      end
    end
  endtask

  // lane decoder: sync on lane_valid, decode every 10-bit symbol.
  // If lane_valid/rst_n drops mid-symbol the bit phase is lost: stop
  // decoding and re-sync on the next fresh rise of lane_valid.
  initial begin : lane_mon
    logic [9:0] code;
    logic       rd;
    logic       mon_ok;
    int         idx;
    forever begin
      @(posedge lane_valid);
      rd = 1'b0;
      mon_ok = 1'b1;
      while (lane_valid && mon_ok) begin
        for (int i = 9; i >= 0; i--) begin
          @(negedge clk);
          if (!lane_valid || !rst_n) mon_ok = 1'b0;
          code[i] = lane_p;
        end
        if (mon_ok) begin
          idx = {rd, code};
          if (!dec_ok[idx]) begin
            errors++;
            viol_count++;
            $display("ERROR: 8b/10b violation code=%b rd=%0d @%0t", code, rd, $time);
          end else begin
            mon_symbol(dec_data[idx], dec_k[idx]);
            rd = dec_rd[idx];
          end
        end
      end
      if (!mon_ok && lane_valid) @(negedge lane_valid);
    end
  end

  // ------------------------- AUX sink responder -------------------------
  task automatic rx_pair(output logic bit_val, output logic ok);
    logic c0, c1;
    begin
      @(negedge clk); c0 = aux_line;
      @(negedge clk); c1 = aux_line;
      ok = (c0 !== c1);
      bit_val = c0;
    end
  endtask

  task automatic rx_byte(output logic [7:0] b, output logic ok);
    logic bv, pok;
    begin
      b = 8'h00;
      ok = 1'b1;
      for (int i = 7; i >= 0; i--) begin
        rx_pair(bv, pok);
        if (!pok) ok = 1'b0;
        b[i] = bv;
      end
    end
  endtask

  task automatic send_bit(input logic b);
    begin
      @(negedge clk); sink_val = b;
      @(negedge clk); sink_val = ~b;
    end
  endtask

  task automatic send_byte(input logic [7:0] b, input logic corrupt);
    begin
      for (int i = 7; i >= 0; i--) begin
        if (corrupt && i == 3) begin
          // Manchester violation: chips (0,0), then abandon the reply
          @(negedge clk); sink_val = 1'b0;
          @(negedge clk); sink_val = 1'b0;
          sink_drv = 1'b0;
          sink_val = 1'b1;
          corrupt_happened = 1'b1;
          i = -9;                            // terminate the loop
        end else begin
          send_bit(b[i]);
        end
      end
    end
  endtask

  // reply: SYNC + start + {reply,4'h0} + data bytes + STOP
  task automatic aux_send(input logic [3:0] reply, input logic [3:0] len,
                          input logic [63:0] rdata, input logic corrupt);
    begin
      repeat (6) @(negedge clk);
      sink_drv = 1'b1;
      sink_val = 1'b1;                       // idle until first sync chip
      for (int i = 0; i < 16; i++) send_bit(1'b0);
      send_bit(1'b1);                        // start bit
      send_byte({reply, 4'h0}, corrupt);
      if (!(corrupt && corrupt_happened)) begin
        for (int i = 0; i < len; i++) send_byte(rdata[8*i +: 8], 1'b0);
        @(negedge clk); sink_val = 1'b1;     // STOP chips (1,1)
        @(negedge clk); sink_val = 1'b1;
        @(negedge clk);
        sink_drv = 1'b0;
        sink_val = 1'b1;
      end
    end
  endtask

  task automatic aux_recv(output logic [3:0] cmd, output logic [19:0] addr,
                          output logic [3:0] len, output logic [63:0] wdata,
                          output logic ok);
    logic bv, pok;
    logic [7:0] b0, b1, b2, b3, bd;
    logic s0, s1;
    begin
      ok = 1'b1;
      wdata = 64'h0;
      for (int i = 0; i < 16; i++) begin
        rx_pair(bv, pok);
        if (!pok || bv) ok = 1'b0;
      end
      rx_pair(bv, pok);
      if (!pok || !bv) ok = 1'b0;            // start bit
      rx_byte(b0, pok); if (!pok) ok = 1'b0;
      rx_byte(b1, pok); if (!pok) ok = 1'b0;
      rx_byte(b2, pok); if (!pok) ok = 1'b0;
      rx_byte(b3, pok); if (!pok) ok = 1'b0;
      cmd  = b0[7:4];
      addr = {b0[3:0], b1, b2};
      len  = b3[3:0];
      if (cmd == 4'h8 || cmd == 4'h0) begin
        for (int i = 0; i < len; i++) begin
          rx_byte(bd, pok);
          if (!pok) ok = 1'b0;
          wdata[8*i +: 8] = bd;
        end
      end
      @(negedge clk); s0 = aux_line;
      @(negedge clk); s1 = aux_line;
      if (!(s0 === 1'b1 && s1 === 1'b1)) ok = 1'b0;   // STOP chips
    end
  endtask

  // sink server: receive requests, answer according to DPCD/EDID model
  initial begin : sink_server
    logic [3:0]  cmd;
    logic [19:0] addr;
    logic [3:0]  len;
    logic [63:0] wdata;
    logic        ok;
    logic        do_corrupt;
    logic [63:0] rd_data;
    logic [7:0]  status;
    for (int i = 0; i < 16; i++) dpcd[i] = 8'h00;
    edid_offset = 8'h00;
    forever begin
      @(posedge aux_tx_en);
      aux_recv(cmd, addr, len, wdata, ok);
      aux_req_count++;
      if (!ok) begin
        errors++;
        $display("ERROR: AUX request framing violation @%0t", $time);
      end else begin
        do_corrupt = corrupt_armed;
        if (corrupt_armed) corrupt_armed = 1'b0;
`ifdef VERILATOR
        if (sink_enable && nack_storm) begin
          // CRV NACK storm: every reply NACKed until the storm is lifted
          nack_fired++;
          aux_send(4'h1, 4'd0, 64'h0, 1'b0);
        end else
`endif
        if (sink_enable) begin
          case (cmd)
            4'h8: begin                       // native AUX write
              dpcd[addr[3:0]] = wdata[7:0];
              if (addr == 20'h2 && wdata[7:0] == 8'h21) saw_tp_cr  = 1'b1;
              if (addr == 20'h2 && wdata[7:0] == 8'h22) saw_tp_tps = 1'b1;
              aux_send(4'h0, 4'd0, 64'h0, do_corrupt);
            end
            4'h9: begin                       // native AUX read
              status = (addr == 20'h3) ? {6'b000000, tps_done, cr_done}
                                       : dpcd[addr[3:0]];
              aux_send(4'h0, 4'd1, {56'h0, status}, do_corrupt);
            end
            4'h0: begin                       // I2C-over-AUX write
              if (addr[15:8] == 8'h50) begin
                edid_offset = addr[7:0];
                aux_send(4'h0, 4'd0, 64'h0, do_corrupt);
              end else begin
                aux_nack_count++;
                aux_send(4'h1, 4'd0, 64'h0, 1'b0);
              end
            end
            4'h1: begin                       // I2C-over-AUX read
              if (addr[15:8] == 8'h50) begin
                rd_data = 64'h0;
                for (int i = 0; i < 8; i++)
                  rd_data[8*i +: 8] = EDID_ROM[8*(edid_offset + i[3:0]) +: 8];
                aux_send(4'h0, len, rd_data, do_corrupt);
              end else begin
                aux_nack_count++;
                aux_send(4'h1, 4'd0, 64'h0, 1'b0);
              end
            end
            default: begin
              aux_nack_count++;
              aux_send(4'h1, 4'd0, 64'h0, 1'b0);
            end
          endcase
        end
      end
    end
  end

  // ------------------------- helpers -------------------------
  task automatic tb_reset;
    begin
      cr_done = 1'b0; tps_done = 1'b0;
      cr_run = 0; cr_run_max = 0;
      tps_seq = 0; tps_pos = 0;
      video_check_en = 1'b0;
      vinframe = 1'b0; vlearned = 1'b0; learn_frame = 1'b0;
      vpos = 0; fc_exp = 8'h00;
      frames_ok = 0;
      for (int i = 0; i < 16; i++) dpcd[i] = 8'h00;
      edid_offset = 8'h00;
      saw_tp_cr = 1'b0; saw_tp_tps = 1'b0;
    end
  endtask

  // ------------------------- main test sequence -------------------------
  int t;
  int base_req;
  initial begin : main
    sink_present = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;

    // CHECK 1: reset / idle state
    repeat (3) @(negedge clk);
    if (lane_valid !== 1'b0 || link_trained !== 1'b0 || irq !== 1'b0 ||
        aux_tx_en !== 1'b0 || edid_valid !== 1'b0) begin
      errors++;
      $display("ERROR: reset state lane_valid=%b trained=%b irq=%b aux_en=%b edid_v=%b",
               lane_valid, link_trained, irq, aux_tx_en, edid_valid);
    end

    // ---------------- Phase 1: full training + EDID + video ----------------
    sink_enable  = 1'b1;
    sink_present = 1'b1;
    for (t = 0; t < 60000 && link_trained !== 1'b1; t++) @(negedge clk);
    if (link_trained !== 1'b1) begin
      errors++; $display("ERROR: link training did not complete");
    end
    // CHECK 2: DPCD writes compared (link rate / lane count / patterns)
    if (dpcd[0] !== 8'h14) begin
      errors++; $display("ERROR: DPCD LINK_RATE=%02h exp 14", dpcd[0]);
    end
    if (dpcd[1] !== 8'h01) begin
      errors++; $display("ERROR: DPCD LANE_COUNT=%02h exp 01", dpcd[1]);
    end
    if (!saw_tp_cr || !saw_tp_tps) begin
      errors++; $display("ERROR: TRAINING_PATTERN_SET writes missing cr=%b tps=%b",
                         saw_tp_cr, saw_tp_tps);
    end
    if (dpcd[2] !== 8'h00) begin
      errors++; $display("ERROR: DPCD TRAINING_PATTERN not cleared: %02h", dpcd[2]);
    end
    // CHECK 3: training sequence on the lane
    if (cr_run_max < 32) begin
      errors++; $display("ERROR: CR burst too short: %0d D10.2", cr_run_max);
    end
    if (tps_seq < 4) begin
      errors++; $display("ERROR: TPS1 sequences seen: %0d (<4)", tps_seq);
    end
    // CHECK 4: EDID read-back
    if (edid_valid !== 1'b1 || edid !== 64'h00FF_FFFF_FFFF_FF00) begin
      errors++; $display("ERROR: EDID valid=%b data=%016h", edid_valid, edid);
    end
    if (aux_nack_count != 0) begin
      errors++; $display("ERROR: unexpected AUX NACKs: %0d", aux_nack_count);
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq asserted during successful training");
    end
    // CHECK 5: video frames (2+ consecutive frames code-by-code)
    repeat (20) @(negedge clk);
    video_check_en = 1'b1;
    for (t = 0; t < 60000 && frames_ok < 2; t++) @(negedge clk);
    video_check_en = 1'b0;
    if (frames_ok < 2) begin
      errors++; $display("ERROR: video frames checked: %0d (<2)", frames_ok);
    end
    if (viol_count != 0) begin
      errors++; $display("ERROR: %0d 8b/10b violations on main link", viol_count);
    end

    // ---------------- Phase 2: training-failure injection ----------------
    tb_reset();
    sink_present = 1'b0;
    rst_n = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    sink_enable = 1'b0;           // sink never replies
    sink_present = 1'b1;
    base_req = aux_req_count;
    for (t = 0; t < 60000 && irq !== 1'b1; t++) @(negedge clk);
    if (irq !== 1'b1 || train_fail !== 1'b1) begin
      errors++; $display("ERROR: training failure did not raise irq/fail");
    end
    if (link_trained !== 1'b0) begin
      errors++; $display("ERROR: link_trained high after failed training");
    end
    if (aux_req_count - base_req < 3) begin
      errors++;
      $display("ERROR: AUX retries not observed (attempts=%0d)",
               aux_req_count - base_req);
    end

    // ---------------- Phase 3: Manchester violation injection ----------------
    tb_reset();
    sink_present = 1'b0;
    rst_n = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    sink_enable  = 1'b1;
    corrupt_armed = 1'b1;         // first AUX reply is corrupted
    sink_present = 1'b1;
    for (t = 0; t < 60000 && link_trained !== 1'b1; t++) @(negedge clk);
    if (!corrupt_happened) begin
      errors++; $display("ERROR: corruption injection never happened");
    end
    if (link_trained !== 1'b1) begin
      errors++;
      $display("ERROR: DUT did not recover after corrupted AUX reply");
    end
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq stuck after recovery");
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized training sessions (full reset per session), sink
    // behaviour randomized per session:
    //   ~50% benign: clean training -> link_trained + EDID, no irq;
    //   ~20% Manchester violation on the first AUX reply -> DUT retries
    //        the op and still trains, no irq;
    //   ~10% NACK storm lifted after 1..2 injected NACKs -> recovery;
    //   ~10% persistent NACK storm -> retries exhausted, train_fail + irq;
    //   ~10% sink absent (no replies) -> AUX timeouts, train_fail + irq
    //        with >= 3 observed retry attempts.
    begin : crv_phase
      int n_ben = 0, n_viol = 0, n_nack = 0, n_fail = 0, n_absent = 0;
      int sel, nn, t2, base;
      for (int i = 0; i < 120; i++) begin
        tb_reset();
        sink_present = 1'b0;
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        corrupt_happened = 1'b0;
        sink_enable = 1'b1;
        sel = $urandom_range(0, 9);
        if (sel <= 4) begin
          sink_present = 1'b1;
          for (t2 = 0; t2 < 80000 && link_trained !== 1'b1; t2++) @(negedge clk);
          cchk(link_trained === 1'b1, "CRV benign: not trained");
          cchk(edid_valid === 1'b1 && edid === 64'h00FF_FFFF_FFFF_FF00,
               "CRV benign: EDID wrong");
          cchk(irq === 1'b0, "CRV benign: irq asserted");
          n_ben++;
        end else if (sel <= 6) begin
          corrupt_armed = 1'b1;
          sink_present  = 1'b1;
          for (t2 = 0; t2 < 80000 && link_trained !== 1'b1; t2++) @(negedge clk);
          cchk(corrupt_happened, "CRV viol: injection never fired");
          cchk(link_trained === 1'b1, "CRV viol: no recovery");
          cchk(irq === 1'b0, "CRV viol: irq asserted");
          n_viol++;
        end else if (sel == 7) begin
          nn   = $urandom_range(1, 2);
          base = nack_fired;
          nack_storm   = 1'b1;
          sink_present = 1'b1;
          for (t2 = 0; t2 < 80000 && (nack_fired - base) < nn; t2++)
            @(negedge clk);
          nack_storm = 1'b0;
          cchk((nack_fired - base) == nn, "CRV nack: injection never fired");
          for (t2 = 0; t2 < 80000 && link_trained !== 1'b1; t2++) @(negedge clk);
          cchk(link_trained === 1'b1, "CRV nack: no recovery");
          cchk(irq === 1'b0, "CRV nack: irq asserted");
          n_nack++;
        end else if (sel == 8) begin
          nack_storm   = 1'b1;
          sink_present = 1'b1;
          for (t2 = 0; t2 < 120000 && irq !== 1'b1; t2++) @(negedge clk);
          nack_storm = 1'b0;
          cchk(irq === 1'b1 && train_fail === 1'b1, "CRV storm: no fail/irq");
          cchk(link_trained !== 1'b1, "CRV storm: trained anyway");
          n_fail++;
        end else begin
          sink_enable  = 1'b0;
          sink_present = 1'b1;
          base = aux_req_count;
          for (t2 = 0; t2 < 120000 && irq !== 1'b1; t2++) @(negedge clk);
          cchk(irq === 1'b1 && train_fail === 1'b1, "CRV absent: no fail/irq");
          cchk(link_trained !== 1'b1, "CRV absent: trained anyway");
          cchk(aux_req_count - base >= 3, "CRV absent: retries missing");
          n_absent++;
        end
      end
      $display("CRV: 120 training sessions: benign=%0d viol=%0d nack=%0d storm-fail=%0d absent-fail=%0d",
               n_ben, n_viol, n_nack, n_fail, n_absent);
    end
`endif

    if (errors == 0) $display("TEST PASSED: DisplayPort2");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < DP2_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, DP2_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // TIMEOUT guard
`ifdef VERILATOR
  // Chunked timeout: Verilator 5.006 corrupts the --timing delay heap on a
  // single long-pending #delay once many short-delay resumptions interleave.
  initial begin
    repeat (30000) #1000;   // 30 ms in 1-us chunks
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #5000000;
    $display("ERROR: TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
