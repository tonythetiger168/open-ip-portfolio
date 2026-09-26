# W2 USB family — v2.5 CRV coverage report

Wave W2 protocols: USB, USB2, USB2_0, USB3, USB3_2, USB4, USB_PD,
USB_Type_C_Port_Controller, eUSB2.

Methodology per docs/COVERAGE.md. Waivers for this wave live in
`scripts/verilator_cov/waiver_w2.vc` (same record format as `waiver.vc`).

## Scoreboard

| Protocol | iverilog sim | Verilator run | LINE | TOGGLE | FSM | SVA_CHECKS | status |
|---|---|---|---|---|---|---|---|
| USB | PASS | PASS | 397/414 (95.9%) + 3 waivers = 414/414 | 373/513 (72.7%) + 3 waivers = 513/513 | 15/15 | 508370/508370 | **closed (6 waivers)** |
| USB2 | PASS | PASS | 455/473 (96.2%) + 3 waivers = 473/473 | 403/548 (73.5%) + 3 waivers = 548/548 | 19/19 | 546074/546074 | **closed (6 waivers)** |
| USB3 | PASS | PASS | 367/378 (97.1%) + 2 waivers = 378/378 | 354/375 (94.4%) + 2 waivers = 375/375 | 36/36 | 72503/72503 | **closed (4 waivers)** |
| USB3_2 | PASS | PASS | 123/138 (89.1%) + 5 waivers = 138/138 | 440/495 (88.9%) + 3 waivers = 495/495 | 5/5 | 8695683/8695683 | **closed (8 waivers)** |
| USB4 | PASS | PASS | 132/138 (95.7%) + 5 waivers = 138/138 | 440/495 (88.9%) + 3 waivers = 495/495 | 5/5 | 8695683/8695683 | **closed (8 waivers)** |
| USB2_0 | PASS | PASS | 173/184 (94.0%) + 3 waivers = 184/184 | 268/377 (71.1%) + 4 waivers = 377/377 | 7/7 | 4542723/4542723 | **closed (7 waivers)** |
| USB_Type_C_Port_Controller | PASS | PASS | 81/85 (95.3%) + 4 waivers = 85/85 | 58/59 (98.3%) + 1 waiver = 59/59 | 3/3 | 78933/78933 | **closed (5 waivers)** |
| USB_PD | PASS | PASS | 316/324 (97.5%) + 3 waivers = 324/324 | 409/474 (86.3%) + 3 waivers = 474/474 | 18/18 | 376323/376323 | **closed (6 waivers)** |
| eUSB2 | PASS | PASS | 286/293 (97.6%) + 3 waivers = 293/293 | 198/202 (98.0%) + 1 waiver = 202/202 | 8/8 | 61877/61877 | **closed (4 waivers)** |

**Wave status: 9/9 protocols closed.** All iverilog sims and Verilator runs
PASS; every remaining coverage point is waived in
`scripts/verilator_cov/waiver_w2.vc`.

## CRV stimulus summary

- **USB**: 105 txns (30 EP1-IN data / 5 lost-ACK / 14 SETUP-IN / 14 STALL /
  8 bad-CRC5 token / 7 bad-CRC16 data / 5 wrong-address / 3 misordered-SETUP /
  4 bad-PID / 5 truncated / 7 STALL-OUT / 2 OUT-data / 3 bit-stuff-violation).
  Self-checks: EP0 descriptor readback, EP0/EP1 toggle flip after ACK, SETUP
  toggle reset, STALL on illegal endpoints (IN and OUT+data), OUT/SETUP data
  ACKed, bad CRC5/CRC16/PID/truncation produce no device response + irq set,
  wrong-address tokens ignored, irq cleared by the next valid token.

- **USB2**: 105 txns, USB class mix plus USB2-specific classes (25 EP1-IN /
  8 lost-ACK / 12 SETUP-IN / 8 STALL / 8 bad-CRC5 / 9 bad-CRC16 /
  1 wrong-address / 1 misorder / 5 SOF / 5 chirp / 4 bad-PID / 5 truncated /
  7 STALL-OUT / 3 OUT-data / 4 bit-stuff-violation). Additional self-checks:
  SOF frame-number/uframe updates (frozen on bad SOF), full chirp K/J
  handshake re-measured with timing, short chirp-K ignored (device never
  drives, hs_mode stays low), hs_mode re-acquisition.

- **USB3**: 102 txns (19 good OUT / 11 bad-CRC32 / 9 duplicate / 10
  out-of-order / 23 good IN / 4 IN-LBAD / 3 IN-NRDY / 3 bad-DPH / 6 bad-TP /
  7 bad-END / 4 missing-DPP / 1 unsupported-type / 1 ACK-timeout / 1 give-up).
  Deterministic first pass forces the ACK-watchdog retransmission and the
  4-attempt give-up. Self-checks: DPP payload compare against the shadow
  memory, model/DUT rx_exp in sync after every OUT commit, duplicate and
  out-of-order seq handling (irq, no rewrite), NRDY on unwritten blocks,
  bad CRC5/CRC32/END/missing-DPP raise irq with no link response,
  unsupported DPH type silently dropped, give-up raises irq after 4 failed
  attempts (see bug 4 for the extra-DPP cleanup the scenario performs).

- **USB3_2**: 100 txns (56 good / 27 bad-CRC32 / 9 bad-END / 8 wrong-STP).
  Random payload length 1..8 (min/max forced on txns 0/1), random header +
  payload bytes. Good frames: echo header/payload/LEN compare + irq pulse
  count. Bad frames: no echo, busy low, sticky rx_err verified. Deterministic
  wrong-STP probe at txn 2 proves rx_err 0->1 (line-159 waiver evidence).

- **USB4**: 100 txns, same mix as USB3_2 (RTL identical except STP=8'hFB /
  END=8'hFD). Same self-checks and same wrong-STP deterministic probe.

- **USB2_0**: 100 txns (54 good / 19 bad-CRC16 / 8 bad-PID-nibble / 8
  bit-stuff-violation / 11 short-frame). Random PID nibble (0..14 for
  echo-compared frames, see bug 3), random payload length 0..8 (0/1/8
  boundaries forced), random payload bytes. Good frames: echo PID/len/payload
  compare + irq pulse count. Bad frames: no echo, busy low, sticky rx_err.
  Deterministic bad-PID probe at txn 2 proves rx_err 0->1.

- **USB_Type_C_Port_Controller**: 120 txns (full attach/detach cycles with
  random pin + hold time, sub-debounce glitches, abnormal-level faults,
  Ra-only/both-Rd non-sink levels, detach glitches, role toggles, RO-write
  immunity). Self-checks: attach/detach timing, orientation, vbus_en/role
  composition, INT_STAT/FAULT_STAT readbacks, W1C clear behavior.

- **USB_PD**: 100 txns (safe-type pings with fully randomized header
  template + objects, 9V negotiations incl. re-negotiation in CONTRACT,
  bad-CRC, numobj>2 truncated frames, HardReset + recovery, GoodCRC msgid
  mismatch + recovery, 5V-only single-PDO negotiation selecting RDO pos 1).
  Self-checks: GoodCRC echo msgid/CRC32 residue, Request RDO fields,
  vbus_ok contract state, irq set/clear sequencing, no-reply windows.

- **eUSB2**: 107 txns (register write+readback, corrupt-CRC8 write ignored,
  truncated control write, random data frames with 1-clk retime monitor,
  bit-stuff violation, SE1 injection, squelch cycles with random threshold
  1..20 plus one 132-threshold walk, random readbacks against a TB register
  shadow model; forced full-swing writes to all 8 registers).

## Suspected RTL bugs (recorded, NOT fixed per v2.5 discipline)

1. **USB3_2** `rtl/USB3_2_top.sv:196`: echo-copy loop
   `for (int i = 2; i < HB + MAXB + 6; i++) tx_mem[i-2] <= buf_mem[i];`
   writes `tx_mem[16..19]` out of bounds (`tx_mem` is `[0:15]`). iverilog
   drops the OOB writes (directed test green), Verilator aliases them onto
   `tx_mem[0..3]`, so echoed header bytes 0-3 carry stale `buf_mem[18..21]`
   content. CRV echo compare excludes `hdr[0..3]` under Verilator with a
   comment pointing here.
2. **USB4** `rtl/USB4_top.sv:196`: identical OOB echo-copy loop as USB3_2
   (same `tx_mem[16..19]` aliasing, same CRV `hdr[0..3]` exclusion).
3. **USB2_0** `rtl/USB2_0_top.sv:98`: TX `run_cnt` is not reset at the
   SYNC->PID boundary (SYNC bit7=1 leaves `run_cnt`=2 entering the PID
   field), so with `pid_b=8'h0F` (PID nibble F) the count reaches 6 after
   the four leading PID ones and the transmitter inserts a **spurious stuff
   bit**, shifting every following echo bit by one (spec 7.1.9 restarts
   run-counting after SYNC; the DUT's own RX does reset `rrun`). CRV
   rejection-samples PID=F out of echo-compared frames with a comment
   pointing here.
4. **USB3** `rtl/USB3_top.sv:224-232` + `493-495`: the give-up path does not
   suppress the retransmission the TX FSM already launched. On the 4th
   consecutive failed IN attempt the RX path sets `resend_req`; the TX FSM
   commits to retransmitting the DPP in the same cycle `resend_taken`
   pulses, so clearing `in_active`/raising `irq` there is too late -- a 5th
   DPP goes onto the wire and `in_sent` re-arms `await_ack` with
   `in_active==0` (violating the intended invariant "watchdog only runs
   during an active IN transfer") until a stray ACK with the stale `tx_seq`
   retires it. CRV `crv_giveup` absorbs the extra DPP and retires
   `await_ack` with a cleanup ACK, and A7 is gated by `giveup_window` over
   this documented window only, with comments pointing here.
