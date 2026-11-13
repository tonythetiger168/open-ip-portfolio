# USB_PD: design specification

USB Power Delivery sink (UFP) controller. It has a CC-line BMC encoder and decoder, simplified to one unit interval per clock and without 4b5b data coding, plus a policy engine that negotiates a fixed-supply contract (9 V when offered, otherwise 5 V). Core `USB_PD_top` (`rtl/USB_PD_top.sv`), testbench `tb/USB_PD_tb.sv`, checker `tb/cov/USB_PD_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one BMC unit interval per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cc_rxd` | input | 1 | CC line level received | - | `clk` | - |
| `cc_txd` | output | 1 | CC line level driven (meaningful while `cc_tx_en`) | - | `clk` | 1 |
| `cc_tx_en` | output | 1 | this sink drives the CC wire (preamble to EOP) | high | `clk` | 0 |
| `vbus_ok` | output | 1 | explicit contract established (after PS_RDY) | high | `clk` | 0 |
| `irq` | output | 1 | protocol error level: set by an error, cleared by the next good message or a HardReset | high | `clk` | 0 |

The checker uses ports only.

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB_PD.md`](../ip/USB_PD.md) (source: `scripts/apb/specs/USB_PD.json`); do not edit by hand.

`USB_PD_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cc_rxd`, `cc_txd`, `cc_tx_en`, `vbus_ok`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Contract state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5044 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `vbus_ok` | RO | core | explicit contract established (PS_RDY received); same as the vbus_ok pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | bad CRC, bad EOP or more than two objects (no GoodCRC sent), a GoodCRC with the wrong MessageID, or a Request given up after its retries. Held in the core until the next good message or a HardReset, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50440200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `vbus_ok`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line coding and frames

- **BMC:** a 1 toggles the line at the unit-interval boundary, and a 0 holds it. The decoder treats a level change between consecutive clocks as 1. The line starts high after reset.
- **K-codes:** 5 bits, sent MSB first.

  | K-code | Value |
  |---|---|
  | Sync-1 | 11000 |
  | Sync-2 | 10001 |
  | RST-1 | 00111 |
  | RST-2 | 11001 |
  | EOP | 01101 |

  SOP = Sync-1 Sync-1 Sync-1 Sync-2. HardReset = RST-1 RST-1 RST-1 RST-2.
- **Frame:**
  1. Preamble: 16 bits 0101...
  2. SOP.
  3. 16-bit header, LSB first: {ext, numobj[2:0], msgid[2:0], power role, spec rev[1:0], data role, msgtype[4:0]}.
  4. 0..2 data objects of 32 bits, LSB first.
  5. CRC-32, LSB first: polynomial 0x04C11DB7 reflected, initial value all ones, sent complemented. It covers the header and the objects.
  6. EOP.
- **Receive check:** a frame is good when the CRC register over header, objects and CRC equals the residue 0xDEBB20E3 and the EOP is right.
- **Inter-frame gap:** after the EOP the sink releases CC (`cc_tx_en` = 0) and waits 3 clocks before it can start the next frame.
- **Half duplex:** the receiver ignores the line while the sink transmits.

### 3.2 Messages sent

| Message | Header | Data object |
|---|---|---|
| GoodCRC | control type 1, numobj 0, msgid = the received message's | none |
| Request | data type 2, numobj 1, msgid = MessageIDCounter | {0, object position 2 (9 V) or 1, 8'h00, operating current, max current}, both currents = the selected PDO's max current in 10 mA units |

Both use power role 0 (sink), spec rev 10 and data role 0 (UFP). A pending GoodCRC is sent before a pending Request.

### 3.3 Policy engine

1. **WAIT_CAPS:** Source_Capabilities (data type 1) is answered with GoodCRC. A PDO is chosen:
   - object 2 if it exists and its voltage field (bits 19:10, 50 mV units) is 180 (9 V);
   - otherwise object 1.

   `vbus_ok` = 0, and the Request is queued.
2. **WAIT_GCRC:** wait for GoodCRC with msgid = MessageIDCounter. That increments the counter and moves to WAIT_ACCEPT.
3. **WAIT_ACCEPT:** Accept moves to WAIT_PSRDY. Reject moves back to WAIT_CAPS.
4. **WAIT_PSRDY:** PS_RDY sets `vbus_ok` = 1 and moves to CONTRACT.
5. **CONTRACT:** a new Source_Capabilities drops `vbus_ok` and renegotiates from step 1.

Every good received message other than GoodCRC is answered with GoodCRC. Messages that do not fit the state (for example PS_RDY without a Request) change nothing.

### 3.4 Request retry

The GoodCRC timer runs from the end of the Request transmission. Without the GoodCRC within GCRC_TO clocks, the Request is sent again with the same msgid, up to N_RETRY times. After that the engine gives up: `irq` = 1 and back to WAIT_CAPS. A GoodCRC with another msgid sets `irq` and is otherwise ignored.

### 3.5 irq

`irq` is a level, set by any of these errors:
- a bad CRC or framing (EOP);
- numobj > 2 (the frame is dropped at the header);
- a GoodCRC msgid mismatch;
- giving up a Request.

Bad frames get no GoodCRC and do not change the policy state. The next good message clears `irq`.

### 3.6 Reset and HardReset

Reset: `cc_tx_en` = 0, `cc_txd` = 1, `vbus_ok` = 0, `irq` = 0, WAIT_CAPS, MessageIDCounter 0.

A HardReset ordered set, detected while the receiver hunts for SOP (and the sink is not transmitting), does the following:
- returns the policy engine to WAIT_CAPS;
- clears `vbus_ok`, `irq`, the pending messages and the MessageIDCounter.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `GCRC_TO` | 200 | >= 1 | CRCReceiveTimer in clocks after the Request is sent |
| `N_RETRY` | 2 | >= 0 | Request retries without GoodCRC before giving up |

## 5. Errors and corner cases

- Only fixed-supply PDOs at positions 1 and 2 are considered. A 9 V PDO at any other position is not chosen.
- A PDO with 0 mA max current still gives a contract (the Request asks for 0 mA).
- Bad frames received during a contract keep the contract.
- The receiver's MessageID is not tracked for duplicates. A repeated message is answered again.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "frame starts high" | the first preamble bit starts from a high line | §3.1 |
| "preamble" | 16 alternating preamble bits | §3.1 |
| "SOP" | SOP ordered set | §3.1 |
| "frame CRC" | CRC-32 of every sent frame | §3.1 |
| "EOP" | EOP K-code | §3.1 |
| "frame length" | frame lengths of GoodCRC and Request | §3.2 |
| "reset outputs" | reset values | §3.6 |
| "contract dropped by new caps" | new Source_Capabilities drop `vbus_ok` and renegotiate | §3.3 |
| "5V contract" | 5 V PDO only: Request of object 1 | §3.3 |
| "contract kept" | the contract stays without new messages | §3.3 |
| "no contract after reject" | Reject returns to waiting for capabilities | §3.3 |
| "ps_rdy without request ignored" | PS_RDY outside WAIT_PSRDY does nothing | §3.3 |
| "wrong GoodCRC id irq" | GoodCRC with another MessageID sets irq | §3.4 |
| "irq cleared by good message" | the next good message clears irq | §3.5 |
| "contract after wrong id" | the right GoodCRC still completes the Request | §3.4 |
| "give-up irq" | no GoodCRC after N_RETRY retries: irq | §3.4 |
| "irq cleared by caps" | new capabilities clear irq | §3.5 |
| "contract after retry" | a retried Request completes | §3.4 |
| "bad CRC irq" | a bad CRC sets irq, no GoodCRC | §3.5 |
| "irq cleared" | irq cleared by a good message | §3.5 |
| "bad EOP irq" | a bad EOP sets irq | §3.5 |
| "too many objects irq" | more than 2 objects sets irq | §3.5 |
| "contract survives noise" | bad frames do not drop the contract | §3.5 |
| "hard reset from contract" | HardReset drops the contract | §3.6 |
| "irq before hard reset" | (TB setup) irq set before the HardReset | §3.6 |
| "hard reset clears irq" | HardReset clears irq | §3.6 |
| "zero-current contract" | a PDO with 0 mA still gives a contract | §3.3 |
| "reset clears contract" | `rst_n` clears the contract | §3.6 |
| a_reset_outputs | in reset: not driving, `cc_txd` = 1, no contract, no irq | §3.6 |
| a_cc_tx_en | `cc_tx_en` equals the reference model every clock | §3.1, §3.2 |
| a_cc_txd | while driving, `cc_txd` equals the model's BMC line | §3.1 |
| a_vbus_ok | `vbus_ok` as the model | §3.3 |
| a_irq | `irq` as the model | §3.5 |
