# USB2: design specification

USB 2.0 high-speed capable device controller with EP0 (control) and EP1 (interrupt IN). It adds three things to the full-speed USB core: a scaled digital model of the chirp speed-detection handshake, SOF frame / microframe tracking, and speed-dependent EP0 packet sizes with a device_qualifier descriptor. The packet layer uses the same NRZI line coding in both speeds; signalling levels are not modelled. Core `USB2_top` (`rtl/USB2_top.sv`), testbench `tb/USB2_tb.sv`, checker `tb/cov/USB2_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (BIT_CLKS clocks per USB bit time) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `dp` | inout | 1 | D+ pad: driven while `tx_oe` (packet) or `ch_oe` (chirp K, 0), else Z; idle J = {dp, dm} = 10 | - | `clk` | Z |
| `dm` | inout | 1 | D- pad (1 during chirp K) | - | `clk` | Z |
| `irq` | output | 1 | sticky: a token / SOF / data packet with a bad CRC or stuffing; cleared by the next good token addressed to the device | high | `clk` | 0 |
| `hs_mode` | output | 1 | 1 after a successful chirp handshake; cleared by bus reset | high | `clk` | 0 |
| `frame_no` | output | 11 | frame number of the last good SOF | - | `clk` | 0 |
| `uframe` | output | 3 | good SOFs seen with this frame number, minus 1 (microframe in high speed) | - | `clk` | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `tx_oe` | 1 | the device drives a packet (SYNC to the end of the EOP J bit) |
| `ch_oe` | 1 | the device drives chirp K (chirp FSM in CH_K) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB2.md`](../ip/USB2.md) (source: `scripts/apb/specs/USB2.json`); do not edit by hand.

`USB2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dp`, `dm`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link speed |
| 0x018 | FRAME | RO | core | SOF tracking |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5548 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `hs_mode` | RO | core | high speed: set by a successful chirp handshake, cleared by the next bus reset |
| FRAME | 10:0 | `frame_no` | RO | core | frame number of the last good SOF |
| FRAME | 13:11 | `uframe` | RO | core | SOFs seen with this frame number, minus 1 (the microframe in high speed) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RXERR | token or data packet with a bad CRC5 / CRC16 or a bit-stuffing error. Held in the core until the next good token addressed to the device, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55480200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `hs_mode`; it needs no clearing.
5. Read FRAME (0x018) for the core's live `frame_no`, `uframe`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line

- **Line states:** `{dp, dm}` = 10 J (idle), 01 K, 00 SE0. One bit time is BIT_CLKS clocks.
- **Receiver:**
  - A bit timer is resynchronised on each J/K transition and samples at BIT_CLKS / 2 - 1.
  - NRZI decoding: no transition means 1.
  - A stuffed 0 after six 1s is removed; a 1 there is a stuffing error.
  - An SE0 ends the packet.
  - The receiver is off while the device transmits or chirps.
- **Transmitter:** SYNC 0x80, PID, payload and CRC16 with NRZI and stuffing (also before the EOP). Then the EOP: SE0 for 2 bits and J for 1 bit.
- **Turnaround:** a response starts 4 bit times after the host packet.
- **Bus reset:** SE0 for 32 bit times while not driving.

### 3.2 Chirp speed detection (`hs_mode`)

1. A bus reset clears `hs_mode` and waits for the host to release SE0.
2. The device drives chirp K (`dp` = 0, `dm` = 1, `ch_oe` = 1) for CHIRP_K clocks.
3. The device listens for host chirps K, J, K, J, K, J. Each chirp counts once its level has lasted CHIRP_MIN clocks; a different level restarts the count of the current chirp.
4. After the sixth chirp (three K-J pairs): `hs_mode` = 1.
5. If CHIRP_WAIT clocks pass first, the device stays at full speed.

`hs_mode` stays until the next bus reset. Packets are not received during the handshake.

### 3.3 Packets

- **PID:** a PID with its complement nibble. A bad check is dropped silently.
- **Token:** ADDR[6:0], ENDP[3:0] and CRC5 (polynomial 0x05, initial value all ones, inverted). The SOF token carries the 11-bit frame number in place of ADDR / ENDP.
- **Data:** payload and CRC16 (polynomial 0x8005, initial value all ones, inverted).
- **Handshakes:** ACK, NAK, STALL.

### 3.4 Transactions

- **IN token** to the device's address:
  - EP0: control data, a zero-length status packet, or STALL.
  - EP1: the counter when configured, NAK otherwise.
  - Any other endpoint: STALL.

  The device then waits 32 bit times for the handshake. ACK advances the toggle and the state; anything else, or a timeout, makes the device resend the same data on the next IN.
- **OUT / SETUP** to the device's address: the DATA packet is ACKed, or STALLed for a non-zero endpoint or a stalled EP0.
  - A wrong-toggle (duplicate) packet is ACKed but not applied.
  - SETUP data must be 8 bytes, otherwise EP0 stalls.

### 3.5 EP0 control requests

| Request | bmRequestType / bRequest | Condition | Response |
|---|---|---|---|
| GET_DESCRIPTOR | 0x80 / 0x06 | wValue 0x0100 (device) or 0x0600 (device_qualifier) | the descriptor, see below |
| GET_CONFIGURATION | 0x80 / 0x08 | wLength 1 | one byte |
| SET_ADDRESS | 0x00 / 0x05 | address < 128 | takes effect after the ACKed status stage |
| SET_CONFIGURATION | 0x00 / 0x09 | value 0 or 1 | takes effect after the ACKed status stage |
| Vendor | 0x40 / 0x01 | wLength 0 | presets the EP1 counter to {wIndex, wValue} |

Descriptors:

| Descriptor | Length | Content |
|---|---|---|
| Device | 18 bytes | bcdUSB 2.00, bMaxPacketSize0 8 (full speed) or 64 (high speed), idVendor 0x1209, idProduct 0x0001, bcdDevice 1.00, one configuration |
| device_qualifier | 10 bytes | describes the other speed: bMaxPacketSize0 64 at full speed, 8 at high speed; one configuration |

Rules:
- Data goes out in packets of up to 8 bytes at full speed, or 64 at high speed (one packet), truncated to wLength. A transfer that ends on a full packet is followed by a ZLP.
- Every other request stalls EP0 until the next SETUP. This includes GET_STATUS and the configuration descriptor.

### 3.6 EP1

EP1 sends a 4-byte counter (LSB first), incremented on each ACK and 0 after reset. It NAKs while unconfigured.

### 3.7 SOF and irq

- **Good SOF:** a good SOF with the same frame number as `frame_no` increments `uframe`. A new number loads `frame_no` and clears `uframe`.
- **SOF with a bad CRC5:** sets `irq`.
- **Other errors:** `irq` is also set by a token, or by expected data, with a bad CRC or stuffing. Such packets get no response.
- **Clearing:** `irq` is cleared by the next good token addressed to the device. A SOF does not clear it.

### 3.8 Reset

Pads released, `irq` = 0, `hs_mode` = 0 (full speed, chirp FSM idle until a bus reset), `frame_no` = `uframe` = 0, address 0, unconfigured.

A bus reset clears the address, the configuration, the toggles and `hs_mode`. It keeps the EP1 counter, `irq` and the frame number.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `BIT_CLKS` | 4 | >= 2 | clk cycles per USB bit time |
| `CHIRP_K` | 64 | >= 1 | device chirp K length, clocks |
| `CHIRP_MIN` | 16 | >= 2 | minimum host chirp length, clocks |
| `CHIRP_WAIT` | 512 | > 6 * CHIRP_MIN | time allowed for the host chirps, clocks |

## 5. Errors and corner cases

- Host chirps shorter than CHIRP_MIN are not counted, so the handshake times out to full speed.
- A host that never releases SE0 after a bus reset keeps the device in the chirp-reset state.
- A lost host ACK makes the device resend the same data with the same toggle.
- A duplicated OUT / SETUP data packet is ACKed and discarded.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "device PID check" | every device packet has a valid PID / check nibble | §3.3 |
| "device CRC16" | every device data packet has the right CRC16 | §3.3 |
| "descriptor byte" | descriptor contents per speed | §3.5 |
| "high-speed descriptor not one packet" | in high speed the 18-byte descriptor is one packet (max 64) | §3.5 |
| "descriptor length" | descriptor data truncated to wLength | §3.5 |
| "status stage not zero length" | the status stage IN is a zero-length packet | §3.5 |
| "get_configuration value" | GET_CONFIGURATION returns the configuration | §3.5 |
| "ep1 counter" | EP1 returns the 4-byte counter, incremented on ACK | §3.6 |
| "no device chirp K" | the device chirps K after a bus reset | §3.2 |
| "device chirp K lasted" | chirp K lasts CHIRP_K clocks | §3.2 |
| "high-speed handshake" | three K-J pairs switch to `hs_mode` | §3.2 |
| "full-speed fallback" | no host chirps within CHIRP_WAIT: full speed | §3.2 |
| "SOF" | `frame_no` / `uframe` track the SOFs | §3.7 |
| "reset state" | pads released, no irq, full speed in reset | §3.8 |
| "ZLP after full descriptor" | a descriptor that ends on a full packet is followed by a ZLP | §3.5 |
| a_reset_outputs | in reset: no drive, no irq, full speed, frame 0 | §3.8 |
| a_tx_oe | `tx_oe` equals the bus-fed reference model every clock | §3.1, §3.4 |
| a_line | while driving a packet, `{dp, dm}` equals the model's symbol | §3.1, §3.3 |
| a_irq | `irq` as the model | §3.7 |
| a_chirp_k | `ch_oe` as the model | §3.2 |
| a_chirp_line | during chirp K, `{dp, dm}` = 01 | §3.2 |
| a_hs_mode | `hs_mode` as the model | §3.2 |
| a_frame | `frame_no` / `uframe` as the model | §3.7 |
