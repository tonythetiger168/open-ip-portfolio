# Contributing to open-ip-portfolio

Thanks for your interest! This portfolio holds 117 protocol IP designs in
SystemVerilog. Contributions of all kinds are welcome: bug reports, bug fixes,
new protocol IPs, deeper testbench coverage, and documentation.

## Ground rules

### RTL (synthesizable code in `rtl/`)
- SystemVerilog-2012, single `always_ff @(posedge clk or negedge rst_n)` style
- **No** `initial`, `#delay`, `$display`, `force` in RTL (testbenches may use them)
- No dual-edge sensitivity lists; no runtime-variable loop bounds (yosys `proc`
  must be able to unroll every loop — use constant bounds + enable guards)
- Avoid `return` inside functions and `break` (tool compatibility)
- Keep module and file names stable; ports are public API — redesigns need an
  RFC issue first

### Testbenches (`tb/`)
- Self-checking with an `errors` counter; end with
  `TEST PASSED: <PROTOCOL>` or `TEST FAILED: %0d errors`
- Include a TIMEOUT guard and at least one error-injection (negative) check
- A fix is not complete without a test that fails before the fix and passes
  after (mutant verification)

### Build
- Every protocol must pass both:
  `make -f Makefile.<P> sim` and `make -f Makefile.<P> syn`
  using only the open toolchain (iverilog 11+, yosys 0.23+)
- CI (`scripts/ci_regression.sh`) runs all 117 protocols on every push

## Workflow

1. Open an issue describing the change (or comment on an existing one)
2. Fork, create a branch (`fix/<proto>-<topic>` or `feat/<proto>`)
3. Keep commits scoped to one protocol (plus shared deps if required)
4. If you change RTL that originates from a `gen_framework.py` template,
   patch the template too so regeneration stays in sync
5. Ensure CI is green; a maintainer will review and merge

## Coding reference

Look at existing mature IPs before writing new ones:
- `rtl/AXI4_top.sv` — channel handshake + burst + error semantics
- `rtl/CSE_top.sv` — real AES-128 (NIST-verified style)
- `rtl/I2C_top.sv` — open-drain bus slave with edge detection
- `tb/SAS_bitclks_tb.sv` — directed TB with parameterized bit rate

## License

By contributing you agree your contributions are licensed under Apache-2.0.
