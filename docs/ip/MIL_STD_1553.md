# MIL-STD-1553B bus controller / remote terminal for dual-redundant buses, with mode codes, RT-RT transfers, broadcast and a 2048-word message buffer

Protocol IP `MIL_STD_1553`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIL_STD_1553_top` (`rtl/MIL_STD_1553_top.sv`) |
| Register interface | APB4 slave `MIL_STD_1553_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x15530100 (code 0x1553, version 1.0) |
| Registers | 18 words, 0x000 to 0x044 |
| Interrupts | 7 sources into one level-high `irq` |
| Data streams | RT_MSG (from the core) |
| Protocol pins | 8 pass-through |

## Overview

MIL_STD_1553_top v1.0: MIL-STD-1553B terminal: bus controller (BC) or remote terminal (RT), dual-redundant buses A / B

- Line coding (both directions): 1 Mbit/s Manchester II, 20-bit-time
words: a 3-bit-time sync (command / status: + then -, data: - then +,
1.5 bit times each), 16 data bits MSB first ('1' = + then -), odd
parity. The transceiver interface is a {p, n} pair per bus and
direction: p = 1 the line is positive, n = 1 negative, both 0 idle.
cfg_half = PCLK cycles per 0.5 us (at least 4).
- Decoder (one per bus): a level that held for 2.5..3.5 half bits and
flips to the opposite level is a sync; the 34 half bits after it are
sampled in their middles. A Manchester error (equal halves, idle or
both levels), a broken sync or even parity makes a word error. Words
the terminal itself is sending are not decoded.
- RT (cfg_bc = 0): answers commands to cfg_rt_addr, and broadcasts (RT
31) when cfg_bcast_en. Receive commands take 1..32 data words
(contiguous) into mem {0, SA, word}; transmit commands send the status
word and the data words from mem {1, SA, word}. RT-to-RT transfers as
the receiver (its receive command followed by the transmit command of
another RT, whose status and data it checks) or as the transmitter.
The status word goes out 2.5 us after the last word (a 4.5 us response
time); a contiguous extra word cancels it. Mode codes (SA 0 or 31):
1 synchronize, 2 transmit status word, 3 initiate self test,
4 / 5 transmitter shutdown / override (of the other bus), 6 / 7 inhibit
/ override the terminal flag, 8 reset RT, 16 transmit vector word,
17 synchronize with data word, 18 transmit last command, 19 transmit
BIT word; every other code is illegal (message error, status only).
Status word: address, message error, service request, broadcast
command received, busy, subsystem flag, terminal flag. With
cfg_busy the RT stores no data and sends no data words. Errors (word,
word count, illegal, RT-RT timeout / address) set the message error
bit and suppress the status word of that message, except illegal
commands, which are answered. A valid command to the RT on either bus
supersedes the message in progress. rt_msg reports every message.
- BC (cfg_bc = 1): one message per bc_start, of type bc_type: 0 BC-RT
(data from mem {1, 0, word}), 1 RT-BC (data into mem {0, 0, word}),
2 RT-RT (bc_cmd1 the receive, bc_cmd2 the transmit command), 3 mode
code without data, 4 mode code with data from the RT, 5 mode code with
a data word from mem {1, 0, 0}. The response must start (its sync
middle) within cfg_resp_timeout half bits after the last word; the
status word's address is checked, a status with the message error or
busy bit carries no data. bc_done reports the status words, the data
word count and the errors: no response, address, word error, word
count. Broadcast commands expect no status.
- Message buffer: 2048 x 16 words inside, address {T/R, SA, word}. The
host reads and writes it through host_*; a host write to the word the
terminal writes on the same clock is dropped (the terminal's wins).

Features:

- Bus controller: BC-RT, RT-BC, RT-RT and mode code messages (with or without a data word), broadcast, response timeout, status address, word and word count checks
- Remote terminal: address 0..30 with broadcast, 1..32 data words, RT-RT as receiver and transmitter, superseding commands on either bus
- Mode codes 1-8, 16-19 (synchronize, transmit status, self test, transmitter shutdown / override, terminal flag inhibit / override, reset, vector, synchronize with data, last command, BIT word); illegal commands answered with the message error bit
- Manchester II encoder and two decoders (bus A / B), 4.5 us RT response time, 2048 x 16 message buffer {T/R, SA, word}

tx_a_p / tx_a_n / tx_b_p / tx_b_n and rx_* connect to two 1553 transceivers (p: positive, n: negative, both 0: idle).
Message buffer words are read and written one at a time through MEM_ADDR, MEM_WDATA, MEM_RDATA and CMD.host_wr / host_rd.
Not implemented: bus monitor mode, dynamic bus control (mode code 0 is illegal), selected transmitter shutdown (codes 20 / 21), illegalization tables per subaddress.

## Files

| File | Content |
|---|---|
| `rtl/MIL_STD_1553_top.sv` | protocol core |
| `rtl/MIL_STD_1553_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIL_STD_1553_tb.sv` | core testbench |
| `tb/MIL_STD_1553_apb_tb.sv`, `tb/apb/MIL_STD_1553_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIL_STD_1553_sva.sv`, `tb/cov/MIL_STD_1553_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIL_STD_1553.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `MIL_STD_1553_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `tx_a_p` | output | 1 | protocol pin, core port `tx_a_p` |
| `tx_a_n` | output | 1 | protocol pin, core port `tx_a_n` |
| `tx_b_p` | output | 1 | protocol pin, core port `tx_b_p` |
| `tx_b_n` | output | 1 | protocol pin, core port `tx_b_n` |
| `rx_a_p` | input | 1 | protocol pin, core port `rx_a_p` |
| `rx_a_n` | input | 1 | protocol pin, core port `rx_a_n` |
| `rx_b_p` | input | 1 | protocol pin, core port `rx_b_p` |
| `rx_b_n` | input | 1 | protocol pin, core port `rx_b_n` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_half` | input | 8 | TIMING[7:0] |
| `cfg_bc` | input | 1 | CTRL[0:0] |
| `cfg_resp_timeout` | input | 8 | TIMING[15:8] |
| `tx_a_p` | output | 1 | pin (pass-through) |
| `tx_a_n` | output | 1 | pin (pass-through) |
| `tx_b_p` | output | 1 | pin (pass-through) |
| `tx_b_n` | output | 1 | pin (pass-through) |
| `rx_a_p` | input | 1 | pin (pass-through) |
| `rx_a_n` | input | 1 | pin (pass-through) |
| `rx_b_p` | input | 1 | pin (pass-through) |
| `rx_b_n` | input | 1 | pin (pass-through) |
| `host_rd` | input | 1 | CMD[2:2] |
| `host_wr` | input | 1 | CMD[1:1] |
| `host_addr` | input | 11 | MEM_ADDR[10:0] |
| `host_wdata` | input | 16 | MEM_WDATA[15:0] |
| `host_rdata` | output | 16 | MEM_RDATA[15:0] |
| `cfg_rt_addr` | input | 5 | CTRL[6:2] |
| `cfg_bcast_en` | input | 1 | CTRL[1:1] |
| `cfg_sr` | input | 1 | CTRL[7:7] |
| `cfg_busy` | input | 1 | CTRL[8:8] |
| `cfg_ssf` | input | 1 | CTRL[9:9] |
| `cfg_tf` | input | 1 | CTRL[10:10] |
| `cfg_vector` | input | 16 | WORDS[15:0] |
| `cfg_bit_word` | input | 16 | WORDS[31:16] |
| `rt_msg` | output | 1 | RT_MSG capture |
| `rt_msg_cmd` | output | 16 | RT_MSG[15:0] |
| `rt_msg_bus` | output | 1 | RT_MSG[16:16] |
| `rt_msg_err` | output | 1 | RT_MSG[17:17] |
| `rt_msg_why` | output | 3 | RT_MSG[20:18] |
| `rt_msg_bcast` | output | 1 | RT_MSG[21:21] |
| `rt_msg_cnt` | output | 6 | RT_MSG[27:22] |
| `mc_sync` | output | 1 | IRQ_STATUS.SYNC |
| `mc_selftest` | output | 1 | IRQ_STATUS.SELF_TEST |
| `mc_reset` | output | 1 | IRQ_STATUS.RT_RESET |
| `mc_sync_data` | output | 1 | IRQ_STATUS.SYNC_DATA |
| `mc_data` | output | 16 | RT_STATUS[18:3] |
| `rt_tx_shut` | output | 2 | RT_STATUS[1:0] |
| `rt_tf_inh` | output | 1 | RT_STATUS[2:2] |
| `bc_start` | input | 1 | CMD[0:0] |
| `bc_type` | input | 3 | BC_CTRL[2:0] |
| `bc_bus` | input | 1 | BC_CTRL[3:3] |
| `bc_cmd1` | input | 16 | BC_CMD[15:0] |
| `bc_cmd2` | input | 16 | BC_CMD[31:16] |
| `bc_busy` | output | 1 | BC_STATUS[0:0] |
| `bc_done` | output | 1 | IRQ_STATUS.BC_DONE |
| `bc_err_noresp` | output | 1 | BC_STATUS[1:1] |
| `bc_err_addr` | output | 1 | BC_STATUS[2:2] |
| `bc_err_word` | output | 1 | BC_STATUS[3:3] |
| `bc_err_wc` | output | 1 | BC_STATUS[4:4] |
| `bc_stat1` | output | 16 | BC_STAT[15:0] |
| `bc_stat2` | output | 16 | BC_STAT[31:16] |
| `bc_cnt` | output | 6 | BC_STATUS[10:5] |

## APB wrapper

`MIL_STD_1553_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_a_p`, `tx_a_n`, `tx_b_p`, `tx_b_n`, `rx_a_p`, `rx_a_n`, `rx_b_p`, `rx_b_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x15530100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000002 | Terminal role and RT status bits |
| 0x018 | TIMING | RW | 0x00001C19 | Bit timing and BC response timeout |
| 0x01C | WORDS | RW | 0x00000000 | RT words for mode codes 16 and 19 |
| 0x020 | BC_CMD | RW | 0x00000000 | BC command words |
| 0x024 | BC_CTRL | RW | 0x00000000 | BC message |
| 0x028 | MEM_ADDR | RW | 0x00000000 | Message buffer address for CMD.host_rd / host_wr |
| 0x02C | MEM_WDATA | RW | 0x00000000 | Message buffer write data |
| 0x030 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x034 | MEM_RDATA | RO | core | Message buffer read data |
| 0x038 | BC_STATUS | RO | core | BC: result of the last message |
| 0x03C | BC_STAT | RO | core | BC: status words of the last message |
| 0x040 | RT_STATUS | RO | core | RT state set by mode codes |
| 0x044 | RT_MSG | RO (pop) | 0x00000000 | RT message report; reading it frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x048 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x1553 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `cfg_bc` | RW | 0x0 | 1 = bus controller, 0 = remote terminal |
| CTRL | 1 | `cfg_bcast_en` | RW | 0x1 | RT: accept broadcast commands (RT 31) |
| CTRL | 6:2 | `cfg_rt_addr` | RW | 0x0 | RT address 0..30 |
| CTRL | 7 | `cfg_sr` | RW | 0x0 | status word: service request |
| CTRL | 8 | `cfg_busy` | RW | 0x0 | status word: busy (no data stored or sent) |
| CTRL | 9 | `cfg_ssf` | RW | 0x0 | status word: subsystem flag |
| CTRL | 10 | `cfg_tf` | RW | 0x0 | status word: terminal flag (unless inhibited by mode code 6) |
| TIMING | 7:0 | `cfg_half` | RW | 0x19 | PCLK cycles per 0.5 us, 4..255 (25 at 50 MHz) |
| TIMING | 15:8 | `cfg_resp_timeout` | RW | 0x1C | BC: half bits from the last word to the middle of the response's sync (28 = 14 us) |
| WORDS | 15:0 | `cfg_vector` | RW | 0x0 | vector word (mode code 16) |
| WORDS | 31:16 | `cfg_bit_word` | RW | 0x0 | BIT word (mode code 19) |
| BC_CMD | 15:0 | `bc_cmd1` | RW | 0x0 | command word (RT-RT: the receive command) |
| BC_CMD | 31:16 | `bc_cmd2` | RW | 0x0 | RT-RT: the transmit command |
| BC_CTRL | 2:0 | `bc_type` | RW | 0x0 | 0 BC-RT, 1 RT-BC, 2 RT-RT, 3 mode code, 4 mode code with a data word from the RT, 5 mode code with a data word from the BC |
| BC_CTRL | 3 | `bc_bus` | RW | 0x0 | 0 bus A, 1 bus B |
| MEM_ADDR | 10:0 | `host_addr` | RW | 0x0 | {T/R, SA, word}; the BC sends from {1, 0, word} and receives into {0, 0, word} |
| MEM_WDATA | 15:0 | `host_wdata` | RW | 0x0 | word written by CMD.host_wr |
| CMD | 0 | `bc_start` | WO (pulse) | 0x0 | 1 = BC: send the message (when BC_STATUS.bc_busy = 0) |
| CMD | 1 | `host_wr` | WO (pulse) | 0x0 | 1 = write MEM_WDATA at MEM_ADDR |
| CMD | 2 | `host_rd` | WO (pulse) | 0x0 | 1 = read MEM_ADDR into MEM_RDATA |
| MEM_RDATA | 15:0 | `host_rdata` | RO | core | word read by CMD.host_rd |
| BC_STATUS | 0 | `bc_busy` | RO | core | a message is under way |
| BC_STATUS | 1 | `bc_err_noresp` | RO | core | no response |
| BC_STATUS | 2 | `bc_err_addr` | RO | core | a status word from the wrong RT |
| BC_STATUS | 3 | `bc_err_word` | RO | core | a word error (Manchester, parity, sync) |
| BC_STATUS | 4 | `bc_err_wc` | RO | core | too few or too many data words |
| BC_STATUS | 10:5 | `bc_cnt` | RO | core | data words received |
| BC_STAT | 15:0 | `bc_stat1` | RO | core | status word (RT-RT: of the transmitting RT) |
| BC_STAT | 31:16 | `bc_stat2` | RO | core | RT-RT: status word of the receiving RT |
| RT_STATUS | 1:0 | `rt_tx_shut` | RO | core | transmitter shut down, per bus (bit 0 A) |
| RT_STATUS | 2 | `rt_tf_inh` | RO | core | terminal flag inhibited |
| RT_STATUS | 18:3 | `mc_data` | RO | core | data word of the last synchronize-with-data mode code |
| RT_MSG | 15:0 | `rt_msg_cmd` | RO (pop) | 0x0 | command word |
| RT_MSG | 16 | `rt_msg_bus` | RO (pop) | 0x0 | bus (0 A, 1 B) |
| RT_MSG | 17 | `rt_msg_err` | RO (pop) | 0x0 | message error |
| RT_MSG | 20:18 | `rt_msg_why` | RO (pop) | 0x0 | 0 none, 1 word error, 2 word count, 3 illegal command, 4 RT-RT transfer error |
| RT_MSG | 21 | `rt_msg_bcast` | RO (pop) | 0x0 | broadcast command |
| RT_MSG | 27:22 | `rt_msg_cnt` | RO (pop) | 0x0 | data words received / sent |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BC_DONE | BC: the message ended (BC_STATUS, BC_STAT) |
| 1 | SYNC | RT: mode code synchronize |
| 2 | SELF_TEST | RT: mode code initiate self test |
| 3 | RT_RESET | RT: mode code reset remote terminal |
| 4 | SYNC_DATA | RT: mode code synchronize with data word (RT_STATUS.mc_data) |
| 5 | RT_MSG_AVAIL | RT_MSG captured a beat |
| 6 | RT_MSG_OVF | beat dropped, RT_MSG was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RT_MSG_AVAIL | RT_MSG holds an unread beat |

### Streams

* **RT_MSG** captures `rt_msg_cmd`, `rt_msg_bus`, `rt_msg_err`, `rt_msg_why`, `rt_msg_bcast`, `rt_msg_cnt` when `rt_msg` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RT_MSG_AVAIL. Reading RT_MSG pops it. A beat that arrives while the register is full is dropped and sets RT_MSG_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x15530100.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TIMING (0x018), WORDS (0x01C), BC_CMD (0x020), BC_CTRL (0x024), MEM_ADDR (0x028), MEM_WDATA (0x02C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To issue a command, write 1 to `bc_start` (CMD bit 0), `host_wr` (CMD bit 1), `host_rd` (CMD bit 2) at 0x030; the core sees a one-clock pulse, and the register reads 0.
6. Read MEM_RDATA (0x034) for the core's live `host_rdata`; it needs no clearing.
7. Read BC_STATUS (0x038) for the core's live `bc_busy`, `bc_err_noresp`, `bc_err_addr`, `bc_err_word`, `bc_err_wc`, `bc_cnt`; it needs no clearing.
8. Read BC_STAT (0x03C) for the core's live `bc_stat1`, `bc_stat2`; it needs no clearing.
9. Read RT_STATUS (0x040) for the core's live `rt_tx_shut`, `rt_tf_inh`, `mc_data`; it needs no clearing.
10. To receive on RT_MSG: wait for IRQ RT_MSG_AVAIL or FLAGS.RT_MSG_AVAIL (bit 0), then read RT_MSG (0x044). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RT_MSG_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and RT_MSG_OVF is set.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. RT: CTRL (cfg_rt_addr), TIMING, write the transmit buffers {1, SA, word}; on IRQ RT_MSG_AVAIL read RT_MSG and the received words {0, SA, word}.
2. BC: CTRL.cfg_bc = 1, TIMING; write the data words at {1, 0, word}, BC_CMD, BC_CTRL, CMD.bc_start; on IRQ BC_DONE read BC_STATUS, BC_STAT and the received words at {0, 0, word}.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.MIL_STD_1553 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.MIL_STD_1553 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/MIL_STD_1553_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.MIL_STD_1553 apb` | `TEST PASSED: MIL_STD_1553_apb`, then Yosys without `ERROR` | console, `work/MIL_STD_1553_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh MIL_STD_1553`<br>`bash scripts/cov/run_cov.sh MIL_STD_1553_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/MIL_STD_1553/score.json`, `work/cov/MIL_STD_1553_apb/score.json` |

Expected end of a step 4 run:

```
===== MIL_STD_1553 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/MIL_STD_1553_tb.sv`): drives `MIL_STD_1553_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/MIL_STD_1553_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/MIL_STD_1553_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/MIL_STD_1553_sva.sv`, `tb/cov/MIL_STD_1553_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIL_STD_1553_top.sv` | not run | | | | | |
| wrapper `rtl/MIL_STD_1553_apb.sv` | not run | | | | | |
