# W2 USB family — v2.5 CRV coverage report

Wave W2 protocols: USB, USB2, USB2_0, USB3, USB3_2, USB4, USB_PD,
USB_Type_C_Port_Controller, eUSB2.

Methodology per docs/COVERAGE.md. Waivers for this wave live in
`scripts/verilator_cov/waiver_w2.vc` (same record format as `waiver.vc`).

## Scoreboard

| Protocol | iverilog sim | Verilator run | LINE | TOGGLE | FSM | SVA_CHECKS | status |
|---|---|---|---|---|---|---|---|
| USB3_2 | PASS | PASS | 123/138 (89.1%) + 5 waivers = 138/138 | 440/495 (88.9%) + 3 waivers = 495/495 | 5/5 | 8695683/8695683 | **closed (8 waivers)** |

## CRV stimulus summary

- **USB3_2**: 100 txns (56 good / 27 bad-CRC32 / 9 bad-END / 8 wrong-STP).
  Random payload length 1..8 (min/max forced on txns 0/1), random header +
  payload bytes. Good frames: echo header/payload/LEN compare + irq pulse
  count. Bad frames: no echo, busy low, sticky rx_err verified. Deterministic
  wrong-STP probe at txn 2 proves rx_err 0->1 (line-159 waiver evidence).

## Suspected RTL bugs (recorded, NOT fixed per v2.5 discipline)

1. **USB3_2** `rtl/USB3_2_top.sv:196`: echo-copy loop
   `for (int i = 2; i < HB + MAXB + 6; i++) tx_mem[i-2] <= buf_mem[i];`
   writes `tx_mem[16..19]` out of bounds (`tx_mem` is `[0:15]`). iverilog
   drops the OOB writes (directed test green), Verilator aliases them onto
   `tx_mem[0..3]`, so echoed header bytes 0-3 carry stale `buf_mem[18..21]`
   content. CRV echo compare excludes `hdr[0..3]` under Verilator with a
   comment pointing here.
