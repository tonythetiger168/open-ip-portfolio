# STB isolated endpoint: UVM/RAL integration requirements

This is a reviewable implementation contract for a future UVM runtime, **not an implemented/passing UVM environment**. Use the single endpoint and pinned DUT source from profile.json. PR29 remains unadopted; no top-level STB integration or full native assertion coverage is claimed. Reuse the separately qualified persistent no-DPI library build when available; do not rebuild the same large library here. No UVM source, DPI backend or tool installation is changed by this CI delivery.

## Topology and register models

`stb_endpoint_env` needs independent APB control and AXI4-Lite memory agents, their passive monitors, one correlation ledger, the existing independent bytearray oracle, a CSR predictor and a native contract-coverage subscriber. All share the existing clock/reset. This is a target endpoint, not an AXI host/fabric/bridge model. Memory DW32/AW32, one outstanding request in each direction. A local correlation number is monitor metadata, not a DUT AXI ID signal.

| RAL object | Offset / size | Access and prediction |
|---|---|---|
| `id` uvm_reg |APB0x000,32bits|RO, reset0x414c0200; writes ignored|
| `irq_status` |APB0x004,bit0|W1C, reset0; previous core-error source is sampled into status; source set dominates a simultaneous W1C|
| `irq_enable` |APB0x008,bit0|RW, reset0; byte0 strobe gates writes|
| reserved word |APB0x00c|Legal decoded access, reads0, writes ignored; do not invent a writable RAL field|
| `scratch` |APB0x010,32bits|RW, reset0; four byte enables|
| `memory` uvm_mem |AXI byte0x000..0x3fc,256x32|Little-endian, aligned addresses, explicit defined-byte mask; contents not reset/zeroized by the RTL|

Use separate address maps and adapters for APB and AXI; identical byte addresses do not alias their storage. Map each32-bit element with four-byte stride and byte addressing. Invalid/misaligned requests are a separate future negative sequence contract and must not become legal memory indices. A native functional read-word denominator must not be invented from the accepted-AW word bins in this campaign.

## Transaction and predictor mappings

| Pin event, sampled before NBA | Monitor event | Mapping / ownership |
|---|---|---|
| `PSEL && PENABLE && PREADY` |APB completed read/write|Single access; payload must match prior setup. Adapter maps addr/data/PWRITE/PSTRB and PSLVERR. Predictor changes the mirror only on this event. No fabricated APB wait cycle.|
| `AWVALID && AWREADY` |Accepted write address|Allocate the one write correlation context. Capture full32-bit address; do not truncate before range/alignment validation.|
| `WVALID && WREADY` |Accepted write payload|Attach data/WSTRB to the accepted AW. Update independent bytearray only for valid addresses and selected bytes; reject unknown-byte reads later. WVALID may precede AW but W acceptance cannot precede it in this target.|
| `BVALID && BREADY` |Completed write response|Close the write context, report OKAY/SLVERR to the waiting frontdoor sequence. Do not apply the byte write twice through both monitor and automatic RAL prediction.|
| `ARVALID && ARREADY` |Accepted read address|Allocate one read context and capture oracle data for the defined byte range. This profile disallows overwriting its word until R completes.|
| `RVALID && RREADY` |Completed read response|Compare data/status and close the context. RVALID while stalled is also checked every cycle, not only at completion.|
| reset asserted |Aborted in-flight contexts|Use explicit aborted status and reset the CSR mirror. Do not clear the independent initialized memory solely because core reset asserted. Mid-transaction reset is not exercised by MEMORY-01.|

Use a negedge-driving clocking block and posedge passive monitor with input `#1step` semantics matching the existing trace. Monitor records must include campaign/cycle, channel, VALID/READY, address/data/strobes/status and reset epoch. The adapter/frontdoor returns only after the appropriate response completes; a sequence starting W early still holds its payload until the actual W handshake.

Disable duplicate automatic prediction when a passive predictor is installed. Do not treat the `uvm_mem` mirror as the independent oracle. IRQ-status prediction needs an explicit set-dominant callback/predictor with the documented previous-cycle source latency; built-in W1C access policy alone does not model simultaneous hardware set. Keep source/error state separate from masked external IRQ. Mirror/readback comparisons must honor the initialized-byte mask and implemented field widths.

## Sequences and acceptance ledger

| Sequence | Required completed traffic / checks |
|---|---|
| `memory_initialize_readback_seq` |Write all256words with full strobes, then read all256words. Every byte becomes defined before a valid read. This is the native before-prefix.|
| `order_strobe_matrix_seq` |AW-first/W-first/simultaneous presentation x16WSTRB, held stable until accepted; byte preservation and readback. No unsupported pre-AW W buffering assumption.|
| `response_backpressure_seq` |Zero/one/multiple B/R stalls, stable payload each stalled edge; new AW/AR held behind prior pending response.|
| `disjoint_duplex_seq` |Read one initialized word while writing another; no same-address overwrite while R pending.|
| `apb_control_during_wait_seq` |ID/status/enable/scratch readback and all16scratch strobes while AXI responses are held, retaining APB zero-wait behavior.|
| `memory_walking_data_seq` |Walking data at0x3fc, successful B and subsequent independent read comparison.|

For runtime qualification, require exact mapping to the existing3607cycle passive trace (339writes/342reads), not only a UVM end-of-test banner. Preserve independent oracle failure behavior for ignored WSTRB, BVALID-gated-by-BREADY and corrupt RDATA. Maintain the original9run/16mutant control gate separately. A UVM-generated equivalent schedule must record its own stimulus/provenance and is a new campaign if timing differs; do not merge its native DB with this one by seed or sequence name.

The finite functional inventory is355named proposal-profile bins: AW word256, order3, WSTRB16, data4, B-stall3, R-stall3, B-OKAY1, R-OKAY1, CSR4, CSR-strobe16 and order×WSTRB48. Eight executed SVA properties use16native USER antecedent/completion witnesses. These are distinct from a complete native assertion-attempt/success/failure/disabled inventory, whose denominator remains unknown. Native FSM states/arcs and full branch construct conformance remain BLOCKED. UVM/RAL runtime, arbitrary concurrency, reset recovery, SoC/physical and security closure remain NOT_RUN/NOT_CLOSED.
