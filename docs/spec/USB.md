# USB: design specification

USB 1.1 Full-Speed device controller with EP0 (control) and EP1 (interrupt IN). It covers the PHY layer (NRZI, bit stuffing, EOP, bus reset on tri-state pads) and the protocol layer (SYNC, PID, CRC5 / CRC16, handshakes, DATA0 / DATA1). It answers standard and one vendor request in hardware. Core `USB_top` (`rtl/USB_top.sv`), testbench `tb/USB_tb.sv`, checker `tb/cov/USB_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock (BIT_CLKS clocks per USB bit time) | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `dp` | inout | 1 | D+ pad: driven while `tx_oe`, else Z (pull-up on D+ assumed: idle J = {dp, dm} = 10) | - | `clk` | Z |
| `dm` | inout | 1 | D- pad | - | `clk` | Z |
| `irq` | output | 1 | sticky: a token / data packet with a bad CRC or stuffing; cleared by the next good token addressed to the device | high | `clk` | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `tx_oe` | 1 | the device drives `dp` / `dm` (from the SYNC to the end of the EOP J bit) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB.md`](../ip/USB.md) (source: `scripts/apb/specs/USB.json`); do not edit by hand.

`USB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dp`, `dm`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55310200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5531 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RXERR | token or data packet with a bad CRC5 / CRC16 or a bit-stuffing error. Held in the core until the next good token addressed to the device, so the bit is set again on every clock until then |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55310200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line

- **Line states:** `{dp, dm}` = 10 J (idle), 01 K, 00 SE0.
- **Bit timing:** one bit time is BIT_CLKS clocks.
- **Receiver:**
  - A bit timer is resynchronised on every J/K transition and samples at BIT_CLKS / 2 - 1.
  - NRZI decoding: no transition means 1.
  - After six 1s the next bit must be a stuffed 0, which is removed. A 1 there is a stuffing error.
  - An SE0 ends the packet.
  - The receiver is disabled while the device transmits.
- **Bus reset:** SE0 for 32 bit times while not driving returns the device to its default state:
  - address 0, unconfigured;
  - all toggles 0;
  - no transfer in progress.

  EP1's counter and `irq` are kept.
- **Transmitter:** it sends SYNC (0x80, KJKJKJKK), the PID, the payload and the CRC16 with NRZI and bit stuffing. A stuffed 0 is also inserted when six 1s end right before the EOP. Then it sends the EOP: SE0 for 2 bits and J for 1 bit, after which it releases the pads (`tx_oe` = 0).
- **Turnaround:** a response starts 4 bit times after the end of the host packet.

### 3.2 Packets

- **PID byte:** PID[3:0] followed by its complement. A bad check nibble drops the packet silently.
- **Token:** ADDR[6:0], ENDP[3:0] and CRC5 (polynomial 0x05, initial value all ones, sent inverted).
- **Data:** payload (up to 8 bytes kept) and CRC16 (polynomial 0x8005, initial value all ones, sent inverted). The payload is LSB first.
- **Handshakes:** ACK 0x2, NAK 0xA, STALL 0xE.
- **Tokens:** OUT 0x1, IN 0x9, SETUP 0xD, SOF 0x5. SOF and received handshakes are ignored outside the handshake wait.

### 3.3 Transactions

- **IN token** to the device's address:
  - EP0: the pending control data, a zero-length status packet, or STALL.
  - EP1: the counter when configured, NAK otherwise.
  - Any other endpoint: STALL.

  After a data packet the device waits up to 32 bit times for the host's handshake.
  - ACK advances the toggle and the state.
  - Anything else, or a timeout, leaves everything unchanged, so the same data is sent again on the next IN.
- **OUT / SETUP token** to the device's address: the next DATA packet is expected.
  - A good CRC16 gets ACK, or STALL if the endpoint is not 0, or for an OUT while EP0 is stalled.
  - Data with the wrong toggle (a retransmission) is ACKed but not applied.
  - SETUP always uses DATA0, and resets the OUT toggle to 1 and the EP0 IN toggle to 1.
  - A SETUP data packet that is not 8 bytes stalls EP0.

### 3.4 EP0 control requests

| Request | bmRequestType / bRequest | Condition | Response |
|---|---|---|---|
| GET_DESCRIPTOR | 0x80 / 0x06 | wValue 0x0100 (device) or 0x0200 (configuration 0) | the descriptor, see the table below |
| GET_STATUS | 0x80 / 0x00 (device) | wValue 0, wLength 2 | two zero bytes (bus powered, no remote wakeup, no halt) |
| GET_STATUS | 0x81 / 0x00 (interface) | interface 0, configured | two zero bytes |
| GET_STATUS | 0x82 / 0x00 (endpoint) | EP0 OUT / IN, or EP1 IN when configured | two zero bytes |
| GET_CONFIGURATION | 0x80 / 0x08 | wLength 1 | one byte, the configuration |
| SET_ADDRESS | 0x00 / 0x05 | address < 128 | takes effect after the ACKed status stage |
| SET_CONFIGURATION | 0x00 / 0x09 | value 0 or 1 | takes effect after the ACKed status stage |
| Vendor | 0x40 / 0x01 | wLength 0 | presets the EP1 counter to {wIndex, wValue}, after the status stage |

Descriptors:

| Descriptor | Length | Content |
|---|---|---|
| Device | 18 bytes | bcdUSB 2.00, bMaxPacketSize0 8, idVendor 0x1209, idProduct 0x0001, bcdDevice 1.00, one configuration |
| Configuration 0 | 25 bytes | configuration (bus powered, 100 mA), interface (one endpoint, vendor class 0xFF), and EP1 IN endpoint (interrupt, wMaxPacketSize 4, bInterval 10) |

Rules:
- Descriptor data is sent in packets of up to 8 bytes and truncated to wLength. A transfer that ends on a full 8-byte packet is followed by a zero-length packet when the host asks again.
- An OUT data packet during the IN data stage ends the request (the status stage).
- Any other request stalls EP0 (STALL on IN and OUT) until the next SETUP.

### 3.5 EP1

EP1 is interrupt IN. It sends the 4-byte counter, LSB first. The counter is incremented on each ACK and starts at 0 after reset. The device NAKs EP1 until it is configured.

### 3.6 irq

`irq` is set by a token or expected data packet with a bad CRC5 / CRC16 or a stuffing error. Such a packet gets no response. `irq` stays set until the next good token addressed to the device.

### 3.7 Reset

Pads released (`tx_oe` = 0), `irq` = 0, address 0, unconfigured, toggles 0, EP1 counter 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `BIT_CLKS` | 4 | >= 2 (even recommended) | clk cycles per USB bit time; the sample point is BIT_CLKS / 2 - 1 |

## 5. Errors and corner cases

- A packet with a bad SYNC or PID check is ignored without `irq`. Only CRC and stuffing errors set it.
- A bad token gets no response, so the host times out and retries.
- A lost ACK from the host makes the device resend the same data with the same toggle.
- A duplicated OUT / SETUP data packet (wrong toggle) is ACKed and discarded.
- A SET_ADDRESS whose status stage is not ACKed does not change the address.
- Payload bytes beyond 8 are CRC-checked but not stored.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "device PID check" | every device packet has a valid PID / check nibble | §3.2 |
| "device CRC16" | every device data packet has the right CRC16 | §3.2 |
| "descriptor length" | descriptor data truncated to wLength and the descriptor size | §3.4 |
| "status stage not zero length" | the status stage IN is a zero-length packet | §3.4 |
| "get_status" | GET_STATUS returns two zero bytes | §3.4 |
| "get_configuration value" | GET_CONFIGURATION returns the configuration | §3.4 |
| "ep1 counter" | EP1 returns the 4-byte counter, incremented on ACK | §3.5 |
| "reset state" | pads released and no irq in reset | §3.7 |
| "ZLP after full descriptor" | a descriptor that ends on a full packet is followed by a ZLP | §3.4 |
| a_reset_outputs | in reset: `tx_oe` = 0, no irq | §3.7 |
| a_tx_oe | `tx_oe` equals the bus-fed reference model every clock | §3.1, §3.3 |
| a_line | while driving, `{dp, dm}` equals the model's symbol | §3.1, §3.2 |
| a_irq | `irq` as the model | §3.6 |
