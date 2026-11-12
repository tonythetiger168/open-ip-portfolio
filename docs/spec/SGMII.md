<!-- SPDX-License-Identifier: Apache-2.0 -->
# SGMII: design specification

A 1000BASE-X / SGMII PCS (IEEE 802.3 clauses 36 and 37, Cisco SGMII MAC side) between a GMII MAC
interface and a ten-bit SerDes interface: 8b/10b with running disparity, ordered sets, the
code-group aligner and synchronisation state machine, packet framing, false carrier, and clause 37
auto-negotiation. Not implemented: SGMII rate adaptation (at 10 / 100 Mb/s the MAC repeats each
byte), carrier extension, EEE, the PHY side of SGMII and next pages. Core `SGMII_top`
(`rtl/SGMII_top.sv`), testbench `tb/SGMII_tb.sv` (a link-partner PCS model), checker
`tb/cov/SGMII_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Transmit positions alternate even / odd from reset (the first group
is even). Receive positions alternate from the comma that started synchronisation (that comma is
even).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | 125 MHz clock; one code group per clock each way | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `gtxd` | input | 8 | GMII transmit byte | - | `clk` | - |
| `gtx_en` | input | 1 | GMII transmit enable (a packet, preamble included) | high | `clk` | - |
| `gtx_er` | input | 1 | GMII transmit error: send /V/ for this byte | high | `clk` | - |
| `grxd` | output | 8 | GMII receive byte | - | `clk` | 0 |
| `grx_dv` | output | 1 | GMII receive data valid | high | `clk` | 0 |
| `grx_er` | output | 1 | GMII receive error (or false carrier with `grx_dv` low) | high | `clk` | 0 |
| `tx_code` | output | 10 | ten-bit code group to the SerDes; bit 9 is bit a, the first on the line | - | `clk` | 0 |
| `rx_code` | input | 10 | ten bits from the SerDes, any alignment; bit 9 first | - | `clk` | - |
| `mode_sgmii` | input | 1 | 1 SGMII (MAC side), 0 1000BASE-X | - | `clk` | - |
| `an_en` | input | 1 | auto-negotiation enable | high | `clk` | - |
| `an_restart` | input | 1 | restart auto-negotiation (level, sampled each clock) | high | `clk` | - |
| `adv` | input | 16 | 1000BASE-X abilities: [5] FD, [6] HD, [8:7] pause, [13:12] remote fault; [14] is ignored | - | `clk` | - |
| `sync_ok` | output | 1 | code-group synchronisation acquired; combinational from the state | high | comb | 0 |
| `an_done` | output | 1 | auto-negotiation in LINK_OK; combinational | high | comb | 0 |
| `link_up` | output | 1 | link status (section 3.7); combinational | high | comb | 0 |
| `lp_ability` | output | 16 | partner's config word ([14]: it acknowledged) | - | `clk` | 0 |
| `speed` | output | 2 | 00 10, 01 100, 10 1000 Mb/s; combinational | - | comb | 10 |
| `full_duplex` | output | 1 | resolved duplex; combinational | high | comb | 0 |
| `irq_link` | output | 1 | one-clock pulse after `link_up` changed | high | `clk` | 0 |
| `irq_an` | output | 1 | one-clock pulse: auto-negotiation completed | high | `clk` | 0 |
| `irq_err` | output | 1 | one-clock pulse: receive error (section 5) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads `an` (in its link-down message and to check IDLE_DETECT); fsm_cov binds the four
state registers. Keep these names and encodings.

| Signal | Width | Meaning |
|---|---|---|
| `an` | 3 | AN: 0 DISABLED, 1 AN_RESTART, 2 ABILITY_DETECT, 3 ACKNOWLEDGE_DETECT, 4 COMPLETE_ACKNOWLEDGE, 5 IDLE_DETECT, 6 LINK_OK |
| `ts` | 2 | transmit: 0 IDLE (ordered sets), 1 PKT, 2 first /R/, 3 second /R/ |
| `sy` | 4 | synchronisation: 0 LOSS, 1 COMMA_DETECT_1, 2 ACQUIRE_SYNC_1, 3 COMMA_DETECT_2, 4 ACQUIRE_SYNC_2, 5 COMMA_DETECT_3, 6..9 SYNC_ACQUIRED_1..4 |
| `rs` | 3 | receive: 0 IDLE, 1 after K28.5, 2 config low byte, 3 config high byte, 4 PKT, 5 after /T/ |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SGMII.md`](../ip/SGMII.md) (source: `scripts/apb/specs/SGMII.json`); do not edit by hand.

`SGMII_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gtxd`, `gtx_en`, `gtx_er`, `grxd`, `grx_dv`, `grx_er`, `tx_code`, `rx_code`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53470100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state |
| 0x018 | LP_ABILITY | RO | core | The partner's config word captured by auto-negotiation |
| 0x01C | CTRL | RW | 0x00000681 | Mode and advertised abilities |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5347 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `sync_ok` | RO | core | code-group synchronisation acquired (clause 36 synchronisation in SYNC_ACQUIRED_1..4) |
| STATUS | 1 | `an_done` | RO | core | auto-negotiation in LINK_OK |
| STATUS | 2 | `link_up` | RO | core | sync and AN done (and the PHY's link bit in SGMII mode), or sync with AN disabled |
| STATUS | 4:3 | `speed` | RO | core | 00 10, 01 100, 10 1000 Mb/s (the partner's speed in SGMII mode, always 10 in 1000BASE-X) |
| STATUS | 5 | `full_duplex` | RO | core | duplex result: partner bit 12 in SGMII mode, adv[5] and partner bit 5 in 1000BASE-X |
| LP_ABILITY | 15:0 | `lp_ability` | RO | core | the partner's base page; [14] is set once it acknowledged |
| CTRL | 0 | `an_en` | RW | 0x1 | auto-negotiation enable (0: data as soon as sync is acquired) |
| CTRL | 1 | `mode_sgmii` | RW | 0x0 | 1: SGMII (MAC side, sends 0x0001, SGMII link timer), 0: 1000BASE-X |
| CTRL | 17:2 | `adv` | RW | 0x1A0 | 1000BASE-X abilities sent in /C/ ([5] FD, [6] HD, [8:7] pause, [13:12] remote fault, [15] next page); [14] is ignored |
| CMD | 0 | `an_restart` | WO (pulse) | 0x0 | write 1: restart auto-negotiation |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LINK | link_up changed |
| 1 | AN | auto-negotiation completed |
| 2 | ERR | an invalid code group or a comma on an odd position while in sync, a false carrier, or an error in a received packet |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53470100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. Read STATUS (0x014) for the core's live `sync_ok`, `an_done`, `link_up`, `speed`, `full_duplex`; it needs no clearing.
6. Read LP_ABILITY (0x018) for the core's live `lp_ability`; it needs no clearing.
7. To issue a command, write 1 to `an_restart` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 8b/10b

Clause 36 tables, symbol bits abcdei fghj, bit a in `tx_code[9]` / `rx_code[9]`. Transmit running
disparity starts at RD- after reset. Special groups: /K28.5/ comma, /S/ = K27.7, /T/ = K29.7,
/R/ = K23.7, /V/ = K30.7.

### 3.2 Transmit

`tx_code` is registered: the group chosen from this clock's `gtx*` and state appears after the
edge. The transmitter sends what the AN state asks (xmit): CONFIG in AN_RESTART, ABILITY_DETECT,
ACKNOWLEDGE_DETECT, COMPLETE_ACKNOWLEDGE; IDLE in IDLE_DETECT; DATA in DISABLED and LINK_OK. The
xmit choice is taken over only at ordered-set boundaries.

| Mode | Groups |
|---|---|
| CONFIG | /C1/ K28.5 D21.5 lo hi, /C2/ K28.5 D2.2 lo hi, repeated; the config word is latched at each 8-group boundary |
| IDLE / DATA between packets | /I/: K28.5 on an even position, then D5.6 (/I1/) when the K28.5 left RD+, else D16.2 (/I2/); /I/ always ends at RD- |
| DATA, packet | at an even position with `gtx_en` high: /S/ in place of that byte; then each byte as data, /V/ for a byte with `gtx_er`; in the first clock with `gtx_en` low: /T/, then /R/; a second /R/ when /T/ was odd |

If `gtx_en` rises on an odd position, that byte goes in place of the /I/ data group (lost) and
/S/ replaces the next one, so the packet loses one more preamble byte.

Config word sent: 0 in AN_RESTART; otherwise 1000BASE-X: `adv` with bit 14 cleared, SGMII: 0x0001;
bit 14 (ACK) set in ACKNOWLEDGE_DETECT and COMPLETE_ACKNOWLEDGE.

### 3.3 Receive alignment and decode

Each clock the last two `rx_code` words form a 20-bit window. While sync is LOSS, a comma (bits
a..g = 0011111 or 1100000) at any of the ten offsets sets the offset (the lowest one found); the
offset is then kept. The aligned group is registered (one clock), then decoded. A group is valid
when it is in the tables and is the right form for the running disparity; the running disparity
then follows the group (for an invalid group, its last unbalanced sub-block decides). A group is
bad when invalid, or a comma on an odd position.

### 3.4 Synchronisation (figure 36-9)

| State | Event | Next |
|---|---|---|
| LOSS | comma | COMMA_DETECT_1 (comma is even) |
| COMMA_DETECT_n | valid data group / other | ACQUIRE_SYNC_n (n=1,2) or SYNC_ACQUIRED_1 (n=3) / LOSS |
| ACQUIRE_SYNC_n | bad group / comma (even) / other | LOSS / COMMA_DETECT_n+1 / stay |
| SYNC_ACQUIRED_1 | bad group | SYNC_ACQUIRED_2 |
| SYNC_ACQUIRED_2..4 | bad / 3 good in a row | one state down (from 4: LOSS) / one state up |

`sync_ok` = SYNC_ACQUIRED_1..4. Three bad groups keep sync; the fourth (without three good ones in
between) loses it.

### 3.5 Receive packets and ordered sets

Only while `sync_ok`; `grx*` are registered (two clocks after `rx_code`).

- Between packets: an even comma starts an ordered set. K28.5 + D21.5 / D2.2 + two valid data
  groups is a config word (low byte first); K28.5 + D5.6 / D16.2 is an /I/. /S/ on an even
  position while xmit is DATA starts a packet: `grx_dv` = 1 with `grxd` = 0x55. /R/ after /T/ is
  ignored. Any other special or invalid group while xmit is DATA is a false carrier: `grx_er` = 1,
  `grxd` = 0x0E, `grx_dv` = 0, `irq_err`.
- In a packet: each data group gives `grx_dv` with the byte; /V/, any other special or an invalid
  group gives `grx_dv` + `grx_er` (+ `irq_err`). /T/ ends the packet. A comma ends it early with
  `grx_dv` + `grx_er` (+ `irq_err`).

### 3.6 Auto-negotiation (clause 37)

Received config words are counted: a word whose abilities (bit 14 masked) match the previous one
extends the ability run; one equal to the previous with bit 14 set extends the acknowledge run.
Runs restart at an /I/ or loss of sync.

| State | Leaves when |
|---|---|
| any (with `an_en`) | entered from DISABLED, `an_restart`, or `sync_ok` falling: AN_RESTART with the link timer loaded |
| AN_RESTART (sends 0) | link timer expired: ABILITY_DETECT |
| ABILITY_DETECT | the 3rd (or later) matching non-zero word: ACKNOWLEDGE_DETECT, `lp_ability` = word |
| ACKNOWLEDGE_DETECT | the 3rd (or later) matching word with ACK: same abilities as `lp_ability`: COMPLETE_ACKNOWLEDGE (`lp_ability` = word, timer loaded); else AN_RESTART |
| COMPLETE_ACKNOWLEDGE | timer expired: IDLE_DETECT, timer loaded |
| IDLE_DETECT | 3 matching config words: AN_RESTART; timer expired and 3 /I/ seen: LINK_OK, `irq_an` |
| LINK_OK | 3 matching config words: AN_RESTART |

In ACKNOWLEDGE_DETECT and COMPLETE_ACKNOWLEDGE three zero words (the partner restarted) give
AN_RESTART. `an_en` low forces DISABLED. Link timer: `LT_X` clocks in 1000BASE-X, `LT_SG` in SGMII.

### 3.7 Results and link

- `link_up` = `sync_ok` && (!`an_en` \|\| (LINK_OK && (1000BASE-X \|\| `lp_ability[15]`))).
- `speed` = `lp_ability[11:10]` in SGMII, else 10 (1000 Mb/s).
- `full_duplex` = `lp_ability[12]` in SGMII, else `adv[5]` && `lp_ability[5]`.
- `irq_link` pulses for one clock in the clock after `link_up` changed.

### 3.8 Reset

`tx_code` = 0 (one clock, then valid groups), GMII receive outputs 0, AN DISABLED (then AN_RESTART
in the first clock with `an_en`), sync LOSS, `lp_ability` = 0, all pulses 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `LT_X` | 1250000 | 1 and up | 1000BASE-X link timer in clocks (10 ms at 125 MHz) |
| `LT_SG` | 200000 | 1 and up | SGMII link timer in clocks (1.6 ms) |

## 5. Errors and corner cases

`irq_err` pulses for: a bad code group while in sync; a false carrier; an error or early end
inside a received packet. Packets are only received while xmit is DATA (AN done or off); /S/ in
other modes is ignored. Rate adaptation is not done: `speed` is reported only.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "TX packet" | every GMII TX packet appears on the line as /S/, the bytes (/V/ for `gtx_er`), /T/; at most the first preamble byte replaced, one more lost when it starts odd | §3.2 |
| "TX packet byte" | each data byte (and /V/) in order | §3.2 |
| "PCS sent an invalid code group" | every `tx_code` is a valid code for the running disparity | §3.1 |
| "comma on an odd position" | commas only on even positions | §3.2 |
| "comma inside a TX packet" | no comma between /S/ and /T/ | §3.2 |
| "/T/ on an odd position followed by one /R/" | /T/ odd is followed by /R/ /R/ | §3.2 |
| "/C1/ and /C2/ do not alternate" | /C/ alternates K28.5 D21.5 and K28.5 D2.2 | §3.2 |
| "/I/ ends at RD+" | after /I/ the running disparity is negative | §3.2 |
| "/I1/ / /I2/ chosen against the disparity" | /I1/ after RD+, /I2/ after RD- | §3.2 |
| "ordered set K28.5" | K28.5 is followed by D21.5, D2.2, D5.6 or D16.2 | §3.2 |
| "/S/ on an odd position" | /S/ only on even positions | §3.2 |
| "special code in a TX packet" | only data and /V/ inside a packet | §3.2 |
| "stray code group" | no other groups outside packets and ordered sets | §3.2 |
| "sync with group" | a bad group often enough keeps sync from being reached | §3.4 |
| "grx_er without irq_err" | every receive error also pulses `irq_err` | §3.5, §5 |
| "ability detect after" | ACKNOWLEDGE_DETECT only after three matching config words | §3.6 |
| "acknowledge detect after" | COMPLETE_ACKNOWLEDGE only after three matching words with ACK | §3.6 |
| "GMII RX dv" | no receive output when none is expected | §3.5 |
| "GMII RX" | every received packet byte, error and false carrier as expected | §3.5 |
| "no link" | the link comes up against the partner | §3.6, §3.7 |
| "AN off: sync without AN" | with `an_en` low, `link_up` = `sync_ok` | §3.7 |
| "link up at reset" | no `link_up` after reset | §3.8 |
| "1000BASE-X result lp" | `lp_ability`, `full_duplex` and `speed` after 1000BASE-X AN | §3.6, §3.7 |
| "all abilities" | an all-ones partner word | §3.6 |
| "half duplex partner" | FD only when both advertise it | §3.7 |
| "SGMII speed" | SGMII takes speed and duplex from the PHY's word | §3.7 |
| "SGMII with the PHY's link bit clear" | no `link_up` when lp[15] = 0 in SGMII | §3.7 |
| "sync lost after three bad code groups" | three bad groups keep sync | §3.4 |
| "sync kept after four bad code groups" | the fourth bad group loses sync | §3.4 |
| "an_restart" | `an_restart` drops `an_done` | §3.6 |
| "partner restart not seen" | three zero config words restart | §3.6 |
| "changed abilities: lp" | changed abilities restart and resolve the new word | §3.6 |
| "idle detect not reached" | IDLE_DETECT after complete acknowledge | §3.6 |
| "outputs in reset" | reset values | §3.8 |
| a_tx_valid | every `tx_code` is valid for the running disparity | §3.1 |
| a_tx_comma_even | commas on even positions | §3.2 |
| a_tx_sop_even | /S/ on even positions | §3.2 |
| a_tx_idle | /I/ form against the disparity | §3.2 |
| a_tx_data | packet bytes and /V/ | §3.2 |
| a_tx_eop | /T/ when `gtx_en` falls | §3.2 |
| a_tx_r | /R/ after /T/ | §3.2 |
| a_tx_r2 | second /R/ after an odd /T/ | §3.2 |
| a_tx_cfg_alt | /C1/ /C2/ alternate with the config word | §3.2 |
| a_rx_gmii | GMII receive outputs as the checker's model | §3.5 |
| a_irq_err | `irq_err` | §5 |
| a_sync | `sync_ok` | §3.4 |
| a_an | AN state and `an_done` | §3.6 |
| a_link | `link_up` / `irq_link` | §3.7 |
| a_result | `lp_ability`, `speed`, `full_duplex` | §3.7 |
| a_no_x | no X on outputs | §1 |
| a_rst | reset values | §3.8 |
