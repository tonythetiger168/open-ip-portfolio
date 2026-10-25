// SPDX-License-Identifier: Apache-2.0
// Shared macros for the per-protocol coverage checkers (tb/cov/<P>_sva.sv).
// Used only by the Verilator flow (bind + concurrent SVA + covergroups); iverilog never
// compiles tb/cov/.
//
// Every checker module declares `COV_CLOCKING(clk, disable_expr) first.
//
// SVA coverage contract (scored by scripts/cov/score.py):
//   * each assertion `name` gets a companion cover `name__ante` on its
//     antecedent (invariants: on "out of reset"), so an assertion that is
//     never exercised non-vacuously shows up as an SVA hole;
//   * a failing assertion prints "SVA_FAIL: <name>" and is scored as failed.
// Functional coverage = covergroup bins + cover properties named fc_*.
`ifndef COV_MACROS_SVH
`define COV_MACROS_SVH

`define COV_CLOCKING(CLK, DIS) \
  default clocking cov_cb @(posedge CLK); endclocking \
  default disable iff (DIS); \
  logic cov_in_rst_q = 1'b0; \
  always @(posedge CLK) cov_in_rst_q <= (DIS);

// A |-> C, with antecedent cover
`define SVA_IMP(NAME, ANTE, CONS) \
  NAME: assert property ((ANTE) |-> (CONS)) \
    else $display("SVA_FAIL: %s @%0t", `"NAME`", $time); \
  NAME``__ante: cover property (ANTE);

// A |=> C, with antecedent cover
`define SVA_NXT(NAME, ANTE, CONS) \
  NAME: assert property ((ANTE) |=> (CONS)) \
    else $display("SVA_FAIL: %s @%0t", `"NAME`", $time); \
  NAME``__ante: cover property (ANTE);

// invariant (checked every clock out of reset)
`define SVA_INV(NAME, EXPR) \
  NAME: assert property (EXPR) \
    else $display("SVA_FAIL: %s @%0t", `"NAME`", $time); \
  NAME``__ante: cover property (1'b1);

// A |-> C checked while reset is asserted (reset-value checks); only from
// the second reset clock on, once the asynchronous reset has landed
`define SVA_RST(NAME, ANTE, CONS) \
  NAME: assert property (disable iff (1'b0) (cov_in_rst_q && (ANTE)) |-> (CONS)) \
    else $display("SVA_FAIL: %s @%0t", `"NAME`", $time); \
  NAME``__ante: cover property (disable iff (1'b0) cov_in_rst_q && (ANTE));

// A |-> C on a second clock (multi-clock IPs); default disable iff applies
`define SVA_IMP_CK(NAME, CK, ANTE, CONS) \
  NAME: assert property (@(posedge CK) (ANTE) |-> (CONS)) \
    else $display("SVA_FAIL: %s @%0t", `"NAME`", $time); \
  NAME``__ante: cover property (@(posedge CK) (ANTE));

// functional cover property
`define FC(NAME, PROP) fc_``NAME: cover property (PROP);
// functional cover property on a second clock
`define FC_CK(NAME, CK, PROP) fc_``NAME: cover property (@(posedge CK) (PROP));
// functional cover property that stays live through reset (reset scenarios)
`define FC_RST(NAME, PROP) fc_``NAME: cover property (disable iff (1'b0) PROP);

`endif
