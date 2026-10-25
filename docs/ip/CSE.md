# Crypto & Security Engine: AES-128 (FIPS-197) ECB encrypt and decrypt, key written as four words, one round per clock

Protocol IP `CSE`, version 2.0. Apache-2.0.

## Overview

CSE -- Crypto & Security Engine: real AES-128 (FIPS-197) ECB core. * Full SubBytes/ShiftRows/MixColumns/AddRoundKey + on-the-fly key expansion; iterative datapath, 1 round/clk, 10 rounds * Parallel command port: 128-bit key written as 4x32 words (key_we/key_widx/key), start/din[127:0]/enc_dec -> busy/done/dout * Command queue depth 1: a new start or key write while busy is a protocol violation -> irq pulse (command ignored)


Wide values are little-endian across words: DIN0 and DOUT0 hold bits [31:0], DIN3 and DOUT3 bits [127:96]. The key is the other way round: KEY0 holds bits [127:96], as the core takes it.
The key words are write only (the core keeps no read path to them) and take whole words: a KEY write with PSTRB != 4'hF gets PSLVERR and is dropped.

## Files

| File | Content |
|---|---|
| `rtl/CSE_top.sv` | protocol core |
| `rtl/CSE_apb.sv` | APB4 register wrapper (generated) |
| `tb/CSE_tb.sv` | core testbench |
| `tb/CSE_apb_tb.sv`, `tb/apb/CSE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CSE_sva.sv`, `tb/cov/CSE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CSE.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CSE sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CSE apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CSE          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CSE_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `key_we` | input | 1 | write to a KEY word |
| `key_widx` | input | 2 | KEY word index |
| `key` | input | 32 | KEY write data |
| `start` | input | 1 | CMD |
| `enc_dec` | input | 1 | CTRL |
| `din` | input | 128 | DIN0[31:0], DIN1[31:0], DIN2[31:0], DIN3[31:0] |
| `busy` | output | 1 | STATUS |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `dout` | output | 128 | DOUT0[31:0], DOUT1[31:0], DOUT2[31:0], DOUT3[31:0] |
| `irq` | output | 1 | IRQ_STATUS.PROTOCOL |

## APB wrapper

`CSE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | KEY0 | WO (core) | 0x00000000 | key bits [127:96] (write only; reset 0); a write while busy is refused (PROTOCOL) |
| 0x018 | KEY1 | WO (core) | 0x00000000 | key bits [95:64] (write only; reset 0) |
| 0x01C | KEY2 | WO (core) | 0x00000000 | key bits [63:32] (write only; reset 0) |
| 0x020 | KEY3 | WO (core) | 0x00000000 | key bits [31:0] (write only; reset 0) |
| 0x024 | DIN0 | RW | 0x00000000 | Input block |
| 0x028 | DIN1 | RW | 0x00000000 | Input block |
| 0x02C | DIN2 | RW | 0x00000000 | Input block |
| 0x030 | DIN3 | RW | 0x00000000 | Input block |
| 0x034 | CTRL | RW | 0x00000001 | Operation |
| 0x038 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x03C | DOUT0 | RO | 0x00000000 | Result |
| 0x040 | DOUT1 | RO | 0x00000000 | Result |
| 0x044 | DOUT2 | RO | 0x00000000 | Result |
| 0x048 | DOUT3 | RO | 0x00000000 | Result |
| 0x04C | STATUS | RO | 0x00000000 | Engine state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4345 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| KEY0 | 31:0 | core register | written at core register 0 |
| KEY1 | 31:0 | core register | written at core register 1 |
| KEY2 | 31:0 | core register | written at core register 2 |
| KEY3 | 31:0 | core register | written at core register 3 |
| DIN0 | 31:0 | `din[31:0]` | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN1 | 31:0 | `din[63:32]` | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN2 | 31:0 | `din[95:64]` | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| DIN3 | 31:0 | `din[127:96]` | the 128-bit block taken by START (plaintext to encrypt, ciphertext to decrypt) |
| CTRL | 0 | `enc_dec` | 1: encrypt, 0: decrypt; taken by START |
| CMD | 0 | `start` | write 1: run one block with the current key, DIN and CTRL (21 clocks); refused while busy (PROTOCOL) |
| DOUT0 | 31:0 | `dout[31:0]` | the 128-bit result of the last operation, valid from DONE |
| DOUT1 | 31:0 | `dout[63:32]` | the 128-bit result of the last operation, valid from DONE |
| DOUT2 | 31:0 | `dout[95:64]` | the 128-bit result of the last operation, valid from DONE |
| DOUT3 | 31:0 | `dout[127:96]` | the 128-bit result of the last operation, valid from DONE |
| STATUS | 0 | `busy` | an operation is running (key expansion, then the rounds) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | an operation finished; DOUT holds the result |
| 1 | PROTOCOL | START or a KEY write while busy (refused) |

### Core register port

The KEY words reach the core's own register port. A write to one pulses `key_we` for one clock with `key_widx` (the core register) and `key` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CSE_top.sv` | pass | 182/182 | 1386/1386 | 8/8 | 5/5 | 8/8 |
| wrapper `rtl/CSE_apb.sv` | pass | 41/41 | 1274/1274 | n/a | 15/15 | 59/59 |
