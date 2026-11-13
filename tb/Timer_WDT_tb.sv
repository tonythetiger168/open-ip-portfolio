// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Timer_WDT_top (system timer, watchdog,
// AXI4 timestamp records). A cycle-level reference model of the prescaler,
// COUNT, the timer and the watchdog is compared with the core on every
// clock (COUNT, WDT_COUNT, TIMER, BARK, wdt_reset) under random PRESCALE,
// PERIOD, WDT_LOAD, kicks and enable changes. Timestamp records: each timer
// event that finds the writer idle is written as COUNT at the next ring
// slot, TS_WP / TS_MISSED count them, records wrap at TS_WORDS and match the
// model's values; an AXI write error sets TS_ERR; reset mid-run.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Timer_WDT_tb;
  `include "soc_ss_tb_common.svh"
  logic [15:0] prescale = 0, ts_words = 0;
  logic        tmr_en = 0, ts_en = 0, wdt_en = 0, kick = 0;
  logic [31:0] period = 0, ts_base = 32'hFFFF_F000, wdt_load = 0;
  wire  [31:0] count, wdt_count;
  wire  [15:0] ts_wp, ts_missed;
  wire         wdt_reset, tmr_irq, bark, ts_err;
  Timer_WDT_top dut (.*);

  // ---------------- reference model ----------------
  logic [15:0] m_pre;
  logic [31:0] m_count, m_tcnt, m_wdt;
  logic        m_barked, m_bite;
  int          n_tmr = 0, n_bark = 0, n_err = 0, n_rec = 0, n_missed = 0;
  logic [31:0] recs [$];
  bit          check_on = 1;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_pre <= 0; m_count <= 0; m_tcnt <= 0; m_wdt <= 0; m_barked <= 0; m_bite <= 0;
    end else begin
      bit tick, t_ev, b_ev;
      tick = m_pre >= prescale;
      t_ev = tmr_en && tick && m_tcnt >= period;
      b_ev = wdt_en && tick && m_wdt == 0 && !m_barked && !kick;
      if (check_on) begin
        if (count !== m_count) fail($sformatf("COUNT %0d, expected %0d", count, m_count));
        if (wdt_count !== m_wdt) fail($sformatf("WDT_COUNT %0d, expected %0d", wdt_count, m_wdt));
        if (tmr_irq !== t_ev) fail("TIMER event");
        if (bark !== b_ev) fail("BARK event");
        if (wdt_reset !== m_bite) fail("wdt_reset");
      end
      n_tmr += t_ev; n_bark += b_ev; n_err += ts_err;
      if (t_ev && ts_en && ts_words != 0) begin
        if (dut.e_busy || dut.e_done) n_missed++;
        else recs.push_back(m_count);
      end
      m_pre <= tick ? 0 : m_pre + 1;
      if (tick) m_count <= m_count + 1;
      if (!tmr_en) m_tcnt <= 0;
      else if (tick) m_tcnt <= (m_tcnt >= period) ? 0 : m_tcnt + 1;
      if (!wdt_en || kick) begin
        m_wdt <= wdt_load; m_barked <= 0; m_bite <= 0;
      end else if (tick) begin
        if (m_wdt == 0) begin
          m_wdt <= wdt_load;
          if (m_barked) m_bite <= 1;
          m_barked <= 1;
        end else m_wdt <= m_wdt - 1;
      end
    end
  end

  task automatic check_records;
    clks(20);
    while (dut.e_busy) @(negedge clk);
    clks(2);
    if (ts_wp !== 16'(recs.size())) fail($sformatf("TS_WP %0d, expected %0d", ts_wp, recs.size()));
    if (ts_missed !== 16'(n_missed > 65535 ? 65535 : n_missed)) fail($sformatf("TS_MISSED %0d, expected %0d", ts_missed, n_missed));
    // the last min(TS_WORDS, n) records are in the ring
    for (int r = (recs.size() > ts_words ? recs.size() - ts_words : 0); r < recs.size(); r++)
      if (mem.peek(ts_base + 32'(4 * (r % ts_words))) !== recs[r]) begin
        fail($sformatf("record %0d: %h, expected %h", r, mem.peek(ts_base + 32'(4 * (r % ts_words))), recs[r]));
        break;
      end
  endtask

  initial begin
    int b0;
    clks(3);
    rst_n = 1;
    clks(5);
    // free-running count with prescalers
    for (int k = 0; k < 6; k++) begin @(negedge clk); prescale = 16'($urandom % 5); clks(50); end
    // timer with records into a ring of 7 words
    @(negedge clk);
    prescale = 1; period = 9; ts_words = 7; ts_en = 1; tmr_en = 1;
    clks(800);
    check_records();
    // period shorter than a record write: some events are missed
    @(negedge clk); prescale = 0; period = 1;
    clks(300);
    @(negedge clk); tmr_en = 0;
    check_records();
    if (n_missed == 0) fail($sformatf("no missed records with a 2-clock period (%0d events, %0d records)", n_tmr, recs.size()));
    // random timer settings
    for (int k = 0; k < 10; k++) begin
      @(negedge clk);
      prescale = 16'($urandom % 4); period = 32'($urandom % 30); tmr_en = 1; ts_en = $urandom % 4 != 0;
      mem.stall = $urandom % 2;
      clks(200 + $urandom % 200);
    end
    @(negedge clk); tmr_en = 0;
    check_records();
    if (n_tmr < 50) fail("too few timer events");
    // AXI error on a record write
    mem.err_lo = ts_base; mem.err_hi = ts_base + 32'(4 * ts_words);
    @(negedge clk); prescale = 0; period = 20; tmr_en = 1;
    clks(30);
    @(negedge clk); tmr_en = 0;
    clks(20);
    if (n_err == 0) fail("no TS_ERR on a write error");
    mem.err_lo = '1; mem.err_hi = '1;
    // watchdog: kicked in time, then bark, then bite
    @(negedge clk); prescale = 2; wdt_load = 15;    // load first, then enable (two register writes)
    @(negedge clk); wdt_en = 1;
    for (int k = 0; k < 10; k++) begin clks(30); @(negedge clk); kick = 1; @(negedge clk); kick = 0; end
    if (n_bark != 0) fail($sformatf("bark although kicked in time (%0d)", n_bark));
    clks(60);
    if (n_bark != 1) fail($sformatf("%0d barks, expected 1", n_bark));
    clks(60);
    if (!wdt_reset) fail("no bite after a second timeout");
    @(negedge clk); kick = 1; @(negedge clk); kick = 0;
    clks(2);
    if (wdt_reset) fail("bite not cleared by a kick");
    b0 = n_bark;
    clks(150);
    @(negedge clk); wdt_en = 0;
    clks(2);
    if (wdt_reset) fail("bite not cleared by WDT_EN = 0");
    if (n_bark == b0) fail("no bark after the kick");
    // random watchdog settings and kicks
    for (int k = 0; k < 300; k++) begin
      @(negedge clk);
      if (k % 50 == 0) begin wdt_load = 32'($urandom % 20); prescale = 16'($urandom % 3); wdt_en = $urandom % 4 != 0; end
      kick = ($urandom % 40 == 0);
    end
    kick = 0; wdt_en = 0;
    // reset while a record write is in flight
    @(negedge clk); ts_en = 1; tmr_en = 1; period = 0; prescale = 0;
    clks(3);
    check_on = 0;
    rst_n = 0; clks(2);
    if (m_awvalid || m_wvalid || count !== 0 || ts_wp !== 0) fail("not idle in reset");
    recs.delete(); n_missed = 0;
    tmr_en = 0; ts_en = 0;
    rst_n = 1; check_on = 1;
    clks(5);
    @(negedge clk); period = 4; ts_en = 1; tmr_en = 1;
    clks(100);
    @(negedge clk); tmr_en = 0;
    check_records();
    // TS_WORDS lowered below the next slot: the record goes to slot 0
    check_on = 0;
    rst_n = 0; clks(2); rst_n = 1; clks(2);
    ts_base = 32'h0000_9000; ts_words = 8; period = 3; prescale = 0;
    for (int i = 0; i < 8; i++) mem.poke(ts_base + 32'(4 * i), 32'hDEAD_0000 | 32'(i));
    @(negedge clk); ts_en = 1; tmr_en = 1;
    while (ts_wp < 5) @(negedge clk);
    tmr_en = 0; clks(10);
    if (ts_wp !== 5) fail("TS_WP before lowering TS_WORDS");
    mem.poke(ts_base, 32'hDEAD_0000);
    ts_words = 3;
    @(negedge clk); tmr_en = 1;
    while (ts_wp < 7) @(negedge clk);
    tmr_en = 0; clks(10);
    if (mem.peek(ts_base) === 32'hDEAD_0000 || mem.peek(ts_base + 4) === 32'hDEAD_0001) fail("record not at slots 0, 1 after lowering TS_WORDS");
    for (int i = 5; i < 8; i++) if (mem.peek(ts_base + 32'(4 * i)) !== (32'hDEAD_0000 | 32'(i))) fail($sformatf("record at slot %0d, outside the shrunk ring", i));
    // other AXI error codes, random BID
    mem.rand_id = 1;
    for (int k = 0; k < 2; k++) begin
      mem.err_resp = k ? 2'b11 : 2'b01;
      mem.err_lo = ts_base; mem.err_hi = ts_base + 32'(4 * ts_words);
      @(negedge clk); period = 20; tmr_en = 1;
      clks(30);
      @(negedge clk); tmr_en = 0; clks(20);
    end
    mem.err_resp = 2'b10; mem.err_lo = '1; mem.err_hi = '1;
    // TS_WORDS 0: events but no records
    @(negedge clk); ts_words = 0; tmr_en = 1; period = 2; clks(20); tmr_en = 0;
    // every bit of the configuration pins and of the watchdog count
    @(negedge clk); wdt_en = 0; wdt_load = 32'hFFFF_FFFF; ts_base = 32'hFFFF_FFFF;
    clks(3);
    @(negedge clk); wdt_load = 32'h0; clks(3);
    // a kick right at expiry, a kick after the bite, the watchdog off while biting
    @(negedge clk); prescale = 0; wdt_load = 3; wdt_en = 1;
    clks(3); @(negedge clk); kick = 1; @(negedge clk); kick = 0;
    clks(15); @(negedge clk); kick = 1; @(negedge clk); kick = 0;
    clks(15); @(negedge clk); wdt_en = 0; clks(2);
    @(negedge clk); wdt_load = 0; wdt_en = 1; clks(1); @(negedge clk); kick = 1; @(negedge clk); kick = 0;
    wdt_en = 0;
    // the prescaler at its maximum: PRE climbs to 16'hFFFF
    @(negedge clk); prescale = 16'hFFFF; clks(140000);
    // a long ring at one event per clock: TS_WP wraps, TS_MISSED saturates
    @(negedge clk); prescale = 0; period = 0; ts_base = 32'h0000_0000; ts_words = 16'hFFFF;
    mem.stall = 0; ts_en = 1; tmr_en = 1;
    while (ts_wp != 16'h0010 || dut.ts_missed != 16'hFFFF) @(negedge clk);
    @(negedge clk); tmr_en = 0;
    clks(20);   // (TS_WP and TS_MISSED are checked every clock by the coverage checker)
    // a long period: the timer count's upper bits, and the timer with the
    // watchdog together
    @(negedge clk); period = 32'hFFFF_FFFF; ts_en = 0; tmr_en = 1; wdt_load = 5; wdt_en = 1;
    clks(1100000);
    @(negedge clk); period = 40; clks(200); tmr_en = 0; wdt_en = 0;
    // a timer event and a bark on the same tick
    @(negedge clk); period = 0; wdt_load = 0; tmr_en = 1; wdt_en = 1; clks(10);
    @(negedge clk); tmr_en = 0; wdt_en = 0;
    ts_words = 3; wdt_load = 0;
    // a final reset clears the counters
    check_on = 0;
    @(negedge clk); rst_n = 0; clks(2); rst_n = 1; clks(3);
    finish("Timer_WDT");
  end
endmodule
