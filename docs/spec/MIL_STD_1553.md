<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIL_STD_1553: design specification

A MIL-STD-1553B terminal that works as a bus controller (BC) or a remote terminal (RT) on
dual-redundant buses A / B: Manchester II encoder and per-bus decoders, a 2048 x 16 message
buffer with a host port, RT receive / transmit / RT-RT / broadcast / mode-code handling with the
status word, and BC messages of six types with response checking. Not implemented: dynamic bus
control acceptance, instrumentation bit, the 14 us no-response limit as a fixed value (it is
`cfg_resp_timeout`), transformer-coupled analog levels, bus monitor mode. Core
`MIL_STD_1553_top` (`rtl/MIL_STD_1553_top.sv`, with sub-modules `MIL_STD_1553_dec` and
`MIL_STD_1553_enc`), testbench `tb/MIL_STD_1553_tb.sv`, checker `tb/cov/MIL_STD_1553_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. H = `cfg_half` clocks (one half bit). Words are 16 bits MSB first;
command fields: RT[15:11], T/R[10], SA[9:5], word count / mode code[4:0] (count 0 = 32).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_half` | input | 8 | clocks per half bit (0.5 us), 4..255 | - | `clk` | - |
| `cfg_bc` | input | 1 | 1 bus controller, 0 remote terminal | - | `clk` | - |
| `cfg_resp_timeout` | input | 8 | response timeout in half bits (from the end of the last word to the response sync) | - | `clk` | - |
| `tx_a_p` | output | 1 | bus A positive; combinational from the encoder | high | comb | 0 |
| `tx_a_n` | output | 1 | bus A negative | high | comb | 0 |
| `tx_b_p` | output | 1 | bus B positive | high | comb | 0 |
| `tx_b_n` | output | 1 | bus B negative | high | comb | 0 |
| `rx_a_p` | input | 1 | bus A positive level seen (synchronised inside) | high | async | - |
| `rx_a_n` | input | 1 | bus A negative level seen | high | async | - |
| `rx_b_p` | input | 1 | bus B positive | high | async | - |
| `rx_b_n` | input | 1 | bus B negative | high | async | - |
| `host_rd` | input | 1 | read the message buffer; `host_rdata` the next clock | high | `clk` | - |
| `host_wr` | input | 1 | write the message buffer | high | `clk` | - |
| `host_addr` | input | 11 | buffer address {T/R, SA[4:0], word[4:0]} | - | `clk` | - |
| `host_wdata` | input | 16 | buffer write data | - | `clk` | - |
| `host_rdata` | output | 16 | buffer read data | - | `clk` | 0 |
| `cfg_rt_addr` | input | 5 | RT address | - | `clk` | - |
| `cfg_bcast_en` | input | 1 | RT accepts broadcast (address 31) | high | `clk` | - |
| `cfg_sr` | input | 1 | status: service request | high | `clk` | - |
| `cfg_busy` | input | 1 | status: busy (no data stored or sent) | high | `clk` | - |
| `cfg_ssf` | input | 1 | status: subsystem flag | high | `clk` | - |
| `cfg_tf` | input | 1 | status: terminal flag (unless inhibited) | high | `clk` | - |
| `cfg_vector` | input | 16 | vector word (mode code 16) | - | `clk` | - |
| `cfg_bit_word` | input | 16 | BIT word (mode code 19) | - | `clk` | - |
| `rt_msg` | output | 1 | one-clock pulse: an RT message ended; `rt_msg_*` valid | high | `clk` | 0 |
| `rt_msg_cmd` | output | 16 | command word of the message | - | `clk` | 0 |
| `rt_msg_bus` | output | 1 | bus of the message: 0 A, 1 B | - | `clk` | 0 |
| `rt_msg_err` | output | 1 | the message error bit was set by this message | high | `clk` | 0 |
| `rt_msg_why` | output | 3 | 0 none, 1 word error, 2 word count, 3 illegal, 4 RT-RT | - | `clk` | 0 |
| `rt_msg_bcast` | output | 1 | the command was broadcast | high | `clk` | 0 |
| `rt_msg_cnt` | output | 6 | data words received (receive) or sent (transmit) | - | `clk` | 0 |
| `mc_sync` | output | 1 | one-clock pulse: mode code 1 synchronize | high | `clk` | 0 |
| `mc_selftest` | output | 1 | one-clock pulse: mode code 3 initiate self test | high | `clk` | 0 |
| `mc_reset` | output | 1 | one-clock pulse: mode code 8 reset RT | high | `clk` | 0 |
| `mc_sync_data` | output | 1 | one-clock pulse: mode code 17 data word received | high | `clk` | 0 |
| `mc_data` | output | 16 | data word of a received mode code | - | `clk` | 0 |
| `rt_tx_shut` | output | 2 | transmitter shut down, per bus (bit 0 A) | high | `clk` | 0 |
| `rt_tf_inh` | output | 1 | terminal flag inhibited | high | `clk` | 0 |
| `bc_start` | input | 1 | BC: start a message (idle, `cfg_bc` = 1) | high | `clk` | - |
| `bc_type` | input | 3 | BC message type (section 3.6) | - | `clk` | - |
| `bc_bus` | input | 1 | BC bus: 0 A, 1 B | - | `clk` | - |
| `bc_cmd1` | input | 16 | first command word | - | `clk` | - |
| `bc_cmd2` | input | 16 | second command word (RT-RT transmit command) | - | `clk` | - |
| `bc_busy` | output | 1 | BC message in progress | high | `clk` | 0 |
| `bc_done` | output | 1 | one-clock pulse: BC message finished; results valid | high | `clk` | 0 |
| `bc_err_noresp` | output | 1 | no response in time | high | `clk` | 0 |
| `bc_err_addr` | output | 1 | status word from the wrong RT | high | `clk` | 0 |
| `bc_err_word` | output | 1 | word error or unexpected data word in place of a status | high | `clk` | 0 |
| `bc_err_wc` | output | 1 | too few / too many data words | high | `clk` | 0 |
| `bc_stat1` | output | 16 | first status word received | - | `clk` | 0 |
| `bc_stat2` | output | 16 | second status word (RT-RT receiver) | - | `clk` | 0 |
| `bc_cnt` | output | 6 | data words received | - | `clk` | 0 |

### Internal signals used by the verification

The checker (`.*`) and the TB watch the message-buffer port of the terminal.

| Signal | Width | Meaning |
|---|---|---|
| `mem_rd` | 1 | the terminal reads the buffer this clock (data in `mem_rdata` the next clock) |
| `mem_wr` | 1 | the terminal writes the buffer this clock |
| `mem_addr` | 11 | terminal buffer address {T/R, SA, word} |
| `mem_wdata` | 16 | terminal write data (a received data word) |
| `mem_rdata` | 16 | terminal read data |

fsm_cov also binds `rs` (RT: 0 IDLE, 1 RXD, 2 RTST, 3 GAP, 4 TX) and `bs` (BC: 0 IDLE, 1 TX, 2
WAIT, 3 RXD, 4 CHK).

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIL_STD_1553.md`](../ip/MIL_STD_1553.md) (source: `scripts/apb/specs/MIL_STD_1553.json`); do not edit by hand.

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

### Programming sequence

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
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line coding

A word is 40 half bits: a sync of 3 half bits at one level and 3 at the other (command / status
sync: positive then negative; data sync: negative then positive), then 16 data bits and an odd
parity bit, each as two half bits (1 = positive then negative). Positive drives `tx_x_p`, negative
`tx_x_n`; idle drives neither. Only one bus transmits at a time. Words of one transmission are
contiguous (the next sync follows the previous parity bit directly).

### 3.2 Decoder (one per bus)

`rx_*` pass two synchroniser flops. A level that lasted 2.5..3.5 half bits (5 H <= 2 x run <= 7
H) and changes to the opposite level marks the sync middle (a word starts); the 34 half bits after
the sync are sampled in their middles. The word is bad on a Manchester error (equal halves, idle,
or both levels), a broken second sync half, or even parity. A word whose sync middle comes while
this terminal is transmitting on that bus is ignored.

### 3.3 RT command acceptance

With `cfg_bc` = 0, a good command-sync word on either bus whose RT field is `cfg_rt_addr`, or 31
with `cfg_bcast_en`, starts a message on that bus. It supersedes any message in progress
(aborting a transmission at once, without a report). Unless it is mode code 2 or 18 it becomes the
"last command" and clears the message error bit; the broadcast-received bit = (RT = 31).

### 3.4 RT messages

- Receive (T/R = 0, SA 1..30): the data words must follow contiguously; each is stored at {0, SA,
  n} when its decoding ends (not with `cfg_busy`). A bad word: word error. A command-sync word:
  word count error, except the first word after the command being a transmit command to another
  RT (not 31): RT-RT receive; the other RT's status must then come (its address, within
  `cfg_resp_timeout` half bits) before the data words, else RT-RT error. Fewer words (no word
  starting within 4 half bits, 2 us, after the previous one): word count error.
- Transmit (T/R = 1): status word, then the data words from {1, SA, i} (none with `cfg_busy`).
  Broadcast transmit commands are illegal (no status).
- After the last expected word the RT waits 5 half bits (2.5 us) from the end of decoding; a word
  starting meanwhile is a word count error. Then it sends the status word (and data), unless the
  command was broadcast or the bus's transmitter is shut down (then only the report).

Errors (word, word count, RT-RT) set the message error bit and end the message without a status
word. Status word: {RT address, message error, 1'b0, `cfg_sr`, 3'b000, broadcast received,
`cfg_busy`, `cfg_ssf`, 1'b0, `cfg_tf` && !`rt_tf_inh`}.

`rt_msg` pulses at the end of every message (error, status sent, or no status) with the command,
bus, error, reason, broadcast flag and word count.

### 3.5 Mode codes (SA 0 or 31)

| T/R | Code | Action | Data word | Broadcast |
|---|---|---|---|---|
| 1 | 1 | `mc_sync` | - | allowed |
| 1 | 2 | (transmit status word) | - | illegal |
| 1 | 3 | `mc_selftest` | - | allowed |
| 1 | 4 / 5 | shut down / override the other bus's transmitter (`rt_tx_shut`) | - | allowed |
| 1 | 6 / 7 | inhibit / override the terminal flag (`rt_tf_inh`) | - | allowed |
| 1 | 8 | reset RT: `mc_reset`, `rt_tx_shut` = 0, `rt_tf_inh` = 0 (after the status; at once when broadcast) | - | allowed |
| 1 | 16 | - | `cfg_vector` | illegal |
| 1 | 18 | - | the last command word | illegal |
| 1 | 19 | - | `cfg_bit_word` | illegal |
| 0 | 17 | `mc_sync_data`, `mc_data` = the received word | received | allowed |
| others | | illegal: message error, status only | | |

Actions 1..7 happen at the command. Legal broadcast mode codes report at once (17 after its data
word) and send no status; illegal broadcast ones report reason 3 without a status.

### 3.6 BC messages

`bc_start` (idle, `cfg_bc` = 1) takes the inputs, raises `bc_busy`, clears the results and sends
on `bc_bus`:

| `bc_type` | Words sent | Response |
|---|---|---|
| 0 BC-RT | cmd1, data from {1, 0, i} | status |
| 1 RT-BC | cmd1 | status + data (stored at {0, 0, n}) |
| 2 RT-RT | cmd1, cmd2 (both command syncs) | transmitter status + data, then receiver status |
| 3 mode code, no data | cmd1 | status |
| 4 mode code, data from RT | cmd1 | status + one data word |
| 5 mode code, data to RT | cmd1, word {1, 0, 0} | status |

The response sync must start within `cfg_resp_timeout` half bits after the BC's last word, else
`bc_err_noresp`. A status with the wrong address gives `bc_err_addr`; a bad word or a data word
in place of a status, `bc_err_word`. A status with message error (bit 10) or busy (bit 3) carries
no data. Data: a bad word gives `bc_err_word`, a command-sync word or a gap of 4 half bits
`bc_err_wc`. After the last expected word the BC waits 4 half bits; a word starting then sets
`bc_err_wc`. Broadcast (cmd1 RT = 31, type != 2) ends after sending; an RT-RT with a broadcast
receive command ends after the data. Every message ends with `bc_done` (one clock) and
`bc_busy` low, the error flags, `bc_stat1`, `bc_stat2`, `bc_cnt` holding until the next start.

### 3.7 Message buffer

2048 x 16 words, address {T/R, SA, word}. Host reads return `host_rdata` the next clock. A host
write to the word the terminal writes in the same clock is dropped.

### 3.8 Reset

All outputs 0, both state machines idle, no transmission; the buffer is not reset.

## 4. Parameters

None.

## 5. Errors and corner cases

- `cfg_bc` = 1 holds the RT idle; `cfg_bc` = 0 holds the BC idle.
- Illegal mode codes with T/R = 0 and code >= 16 still take their data word (`mc_data` is
  updated) but give no `mc_sync_data`.
- A shut-down transmitter suppresses all RT transmissions on that bus; commands are still
  executed and reported.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "BC: no bc_done" | each BC message ends with `bc_done` | §3.6 |
| "BC: busy with bc_done" | `bc_busy` low when `bc_done` | §3.6 |
| "synchronize: no mc_sync" | mode code 1 | §3.5 |
| "self test: no mc_selftest" | mode code 3 | §3.5 |
| "shutdown B" | mode code 4 on A shuts down B | §3.5 |
| "override B" | mode code 5 on A | §3.5 |
| "shutdown A" | mode code 4 on B shuts down A | §3.5 |
| "reset RT" | mode code 8 after its status | §3.5 |
| "vector word" | mode code 16 sends `cfg_vector` | §3.5 |
| "sync with data" | mode code 17 data word | §3.5 |
| "last command word" | mode code 18 sends the previous command | §3.5 |
| "last command: itself not stored" | mode codes 2 and 18 do not replace the last command / status | §3.5 |
| "BIT word" | mode code 19 sends `cfg_bit_word` | §3.5 |
| "illegal mode code 3 (T/R = 0) ran the self test" | illegal codes have no effect | §3.5 |
| "illegal mode code 20 synchronized" | as above | §3.5 |
| "broadcast sync" | broadcast mode codes execute without status | §3.5 |
| "broadcast sync with data" | broadcast 17 | §3.5 |
| "broadcast shutdown" | broadcast 4 | §3.5 |
| "broadcast override" | broadcast 5 | §3.5 |
| "broadcast inhibit TF" | broadcast 6 | §3.5 |
| "broadcast reset" | broadcast 8 | §3.5 |
| "busy: data stored" | with `cfg_busy` no data is stored | §3.4 |
| "RT-RT from the BFM: data" | RT-RT receive stores the transmitter's data | §3.4 |
| "superseded receive: no sync" | a new command supersedes a message | §3.3 |
| "superseded transmit: BC word error" | a new command aborts a transmission | §3.3 |
| "BC error case" | each BC error flag for its fault | §3.6 |
| "BC from the BFM: data" | BC stores received data words | §3.6 |
| "host port" | host reads / writes the buffer | §3.7 |
| "host write next to an RT write" | the terminal's write wins on the same word | §3.7 |
| "reset values" | reset values | §3.8 |
| "idle configuration sweep started a transfer" | nothing is sent without a command / `bc_start` | §3.3, §3.6 |
| a_tx_not_both_levels | never p and n together | §3.1 |
| a_tx_one_bus | never both buses at once | §3.1 |
| a_rt_status_word | the RT status word as the checker's model | §3.4 |
| a_rt_response_time | the status starts 5 half bits after the last word | §3.4 |
| a_rt_data_words | RT data words as the model | §3.4 |
| a_rt_memory_write | RT buffer writes as the model | §3.4 |
| a_rt_report_command | `rt_msg_cmd` / bus / bcast as the model | §3.4 |
| a_rt_report_words_sent | `rt_msg_cnt` for transmit messages | §3.4 |
| a_rt_report_count | `rt_msg_cnt` for receive messages | §3.4 |
| a_bc_words_sent | BC words as the model | §3.6 |
| a_bc_result | BC results as the model | §3.6 |
| a_bc_done_pulse | `bc_done` is one clock | §3.6 |
| a_bc_errors_exclusive | at most one BC error flag | §3.6 |
| a_rt_quiet_in_bc_mode | no RT activity with `cfg_bc` = 1 | §3.3 |
| a_bc_quiet_in_rt_mode | no BC activity with `cfg_bc` = 0 | §3.6 |
| a_rt_why_range | `rt_msg_why` <= 4 | §3.4 |
