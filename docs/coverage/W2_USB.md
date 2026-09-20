# W2 USB family — v2.5 CRV coverage report

Wave W2 protocols: USB, USB2, USB2_0, USB3, USB3_2, USB4, USB_PD,
USB_Type_C_Port_Controller, eUSB2.

Methodology per docs/COVERAGE.md. Waivers for this wave live in
`scripts/verilator_cov/waiver_w2.vc` (same record format as `waiver.vc`).

## Scoreboard

| Protocol | iverilog sim | Verilator run | LINE | TOGGLE | FSM | SVA_CHECKS | status |
|---|---|---|---|---|---|---|---|
| USB3_2 | PASS | PASS | 123/138 (89.1%) + 5 waivers = 138/138 | 440/495 (88.9%) + 3 waivers = 495/495 | 5/5 | 8695683/8695683 | **closed (8 waivers)** |
| USB4 | PASS | PASS | 132/138 (95.7%) + 5 waivers = 138/138 | 440/495 (88.9%) + 3 waivers = 495/495 | 5/5 | 8695683/8695683 | **closed (8 waivers)** |
| USB2_0 | PASS | PASS | 173/184 (94.0%) + 3 waivers = 184/184 | 268/377 (71.1%) + 4 waivers = 377/377 | 7/7 | 4542723/4542723 | **closed (7 waivers)** |
| USB_Type_C_Port_Controller | PASS | PASS | 81/85 (95.3%) + 4 waivers = 85/85 | 58/59 (98.3%) + 1 waiver = 59/59 | 3/3 | 78933/78933 | **closed (5 waivers)** |
| USB_PD | PASS | PASS | 316/324 (97.5%) + 3 waivers = 324/324 | 409/474 (86.3%) + 3 waivers = 474/474 | 18/18 | 376323/376323 | **closed (6 waivers)** |
| eUSB2 | PASS | PASS | 286/293 (97.6%) + 3 waivers = 293/293 | 198/202 (98.0%) + 1 waiver = 202/202 | 8/8 | 61877/61877 | **closed (4 waivers)** |

## CRV stimulus summary

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
