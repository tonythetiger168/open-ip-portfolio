# SAS-4 initiator link layer: OOB bring-up, 128b/130b-style blocks (sync header + scrambled payload), block lock and loss of sync, SOF / header / payload / CRC-32 / EOF frames, and a built-in write / read-verify sequencer over a 16 x 32-bit register file

Protocol IP `SAS_4__Serial_Attached_SCSI_`, version 2.0. Apache-2.0.

## Overview

SAS-4 (Serial Attached SCSI, 24G) -- 128b/150b-style block-coded link layer initiator IP.  Distinct from SAS_top (NRZ + dword link): this core implements a 128b/150b-style block code and a self-synchronous scrambler. Implementation scope (simplified, NOT the full SPL specification):

- Block code: 2-bit sync header (2'b01 = data block, 2'b10 = control
block) + 128-bit payload block = 130 bits/block, MSB first, 1 bit/clk.
Sync header bits are never scrambled (64b/66b-style); payloads are.
- Scrambler: self-synchronous.  SAS-4 specifies x^58+x^39+1; simplified
here to x^16+x^5+1 (noted): obit = dbit ^ s[15] ^ s[4], s <<= obit.
The same LFSR stream runs continuously across all block payloads
(idle blocks included), so the line never carries plaintext.
- Frame format: SOF control block + header data block {type,dst,src,len}
(one 32-bit dword per field, value in low 8 bits) + payload data
block(s) (len <= 8 dwords, zero padded to 4-dword blocks) + CRC32 data
block (dword0 = CRC, poly 0x04C11DB7 reflected, init/xorout all-ones,
covering header + padded payload blocks) + EOF control block.
Idle control blocks are sent between frames.  A received frame takes
effect only once its EOF block arrives.  The transmitter only
sends len 0 / 1 frames; the receiver accepts len 0..8.
- OOB: SNW-style burst/idle handshake (106 clk burst, 318 clk idle,
>=64 clk run detect) -> PHY READY (link_up).  No burst answered in an
idle window repeats the previous burst.
- Block lock: 4 consecutive valid sync headers plus one legal control
code while hunting; an invalid header while hunting slips one bit.
- Loss of sync: 8 consecutive invalid sync headers (2'b00/2'b11) while
locked -> loss_sync: irq pulse, link_down and full re-OOB.
- Functional unit: 16x32 register file.  type 8'h01 = write (payload[0]),
8'h02 = read request (answered with a read response to the sender),
8'h83 = read response (payload[0] = reg value).  One read response
can wait for the transmitter; a newer request replaces it.  A built-in initiator
sequencer runs write + read-verify transactions with xorshift32 data
against a looped-back (reflecting) link partner. It takes only the
write of its own register and the read response from it; anything
else (a late frame of a timed-out transaction, another node's) is
ignored.
- irq: 1-clk pulse on CRC error, protocol violation, sequencer timeout,
read-verify mismatch or loss of sync.
NOTE: clk is used as the line bit clock (1 bit/clk).  rx_n is the
inverted companion of rx_p and is unused by this single-ended model.

tx_p / tx_n (serial out, 1 bit per PCLK), rx_p / rx_n (serial in; only rx_p is sampled) and link_up pass through unchanged. The initiator runs on its own after reset and verifies its own traffic against a reflecting link partner.
The scrambler is simplified to x^16 + x^5 + 1 (SAS-4 uses x^58 + x^39 + 1).

## Files

| File | Content |
|---|---|
| `rtl/SAS_4__Serial_Attached_SCSI__top.sv` | protocol core |
| `rtl/SAS_4__Serial_Attached_SCSI__apb.sv` | APB4 register wrapper (generated) |
| `tb/SAS_4__Serial_Attached_SCSI__tb.sv` | core testbench |
| `tb/SAS_4__Serial_Attached_SCSI__apb_tb.sv`, `tb/apb/SAS_4__Serial_Attached_SCSI__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SAS_4__Serial_Attached_SCSI__sva.sv`, `tb/cov/SAS_4__Serial_Attached_SCSI__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SAS_4__Serial_Attached_SCSI_.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.SAS_4__Serial_Attached_SCSI_ sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SAS_4__Serial_Attached_SCSI_ apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SAS_4__Serial_Attached_SCSI_          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SAS_4__Serial_Attached_SCSI__apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_p` | output | 1 | pin (pass-through) |
| `tx_n` | output | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `rx_n` | input | 1 | pin (pass-through) |
| `link_up` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SAS_4__Serial_Attached_SCSI__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `tx_n`, `rx_p`, `rx_n`, `link_up`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53340200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | Link state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5334 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 0 | `link_up` | OOB done and the link is up (cleared by a loss of sync, which restarts OOB) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | CRC error, protocol violation (control block out of place, missing EOF, length above 8, bad register address, unknown type), sequencer timeout, read-verify mismatch, or loss of sync |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SAS_4__Serial_Attached_SCSI__top.sv` | pass | 154/154 | 1618/1618 | 57/57 | 6/6 | 34/34 |
| wrapper `rtl/SAS_4__Serial_Attached_SCSI__apb.sv` | pass | 20/20 | 406/406 | n/a | 7/7 | 25/25 |
