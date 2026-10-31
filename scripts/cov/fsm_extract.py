#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Extract FSMs (state variables, encodings, explicit arcs, clock/reset) from
a protocol's RTL with pyslang.

An FSM is any enum-typed variable written in a clocked procedural block.
Arcs are the explicit `state <= CONST` assignments, attributed to the
`case (state)` item (or `if (state == CONST)` branch) that encloses them;
an assignment outside any such dispatch is an arc from "*" (any state).
Assignments under the reset branch (`if (!rst_n)` / `if (rst)`) are reset
arcs and are not reported.

Usage: fsm_extract.py <PROTOCOL>     -> JSON on stdout
"""
import json, re, sys
from pyslang.syntax import SyntaxTree
from pyslang.ast import Compilation, SymbolKind, ExpressionKind, StatementKind, \
    TimingControlKind

def proto_sources(p):
    mk = open(f"Makefile.{p}").read()
    s = re.search(r"^S\s*:?=\s*(\S+)", mk, re.M).group(1)
    deps = re.search(r"^DEPS\s*:?=(.*)$", mk, re.M).group(1).split()
    return s, [f"rtl/{s}_top.sv"] + deps

def covlib_modules(p):
    """Modules of the Makefile's COVLIB files: IPs used as sub-blocks that are
    closed by their own coverage run, so their FSMs are not covered here."""
    mk = open(f"Makefile.{p}").read()
    m = re.search(r"^COVLIB\s*:?=(.*)$", mk, re.M)
    mods = set()
    for f in (m.group(1).split() if m else []):
        mods |= set(re.findall(r"^module\s+(\w+)", open(f).read(), re.M))
    return mods

def strip(e):
    while e is not None and e.kind == ExpressionKind.Conversion:
        e = e.operand
    return e

def const_val(e):
    e = strip(e)
    if e is None:
        return None
    if e.kind == ExpressionKind.NamedValue and e.symbol.kind == SymbolKind.EnumValue:
        return int(str(e.symbol.value).split("'")[-1].lstrip("bdhoBDHO") or 0, 0) \
            if False else _cv(e.symbol.value)
    c = e.constant
    if c is not None:
        return _cv(c)
    return None

def _cv(cv):
    s = str(cv)
    m = re.match(r"(\d+)'(s?)([bdho])([0-9a-fA-FxXzZ_]+)$", s)
    if m:
        base = {"b": 2, "d": 10, "h": 16, "o": 8}[m.group(3)]
        digits = m.group(4).replace("_", "")
        if re.search(r"[xXzZ]", digits):
            return None
        return int(digits, base)
    try:
        return int(s)
    except ValueError:
        return None

def named(e):
    e = strip(e)
    if e is not None and e.kind == ExpressionKind.NamedValue:
        return e.symbol
    return None

def is_reset_cond(e, rst_names):
    """`!rst_n`, `~rst_n`, `rst`, `rst_n == 0`, `reset`..."""
    e = strip(e)
    if e.kind == ExpressionKind.UnaryOp:
        s = named(e.operand)
        return s is not None and s.name in rst_names
    s = named(e)
    if s is not None and s.name in rst_names:
        return True
    if e.kind == ExpressionKind.BinaryOp and str(e.op).endswith("Equality"):
        s = named(e.left)
        return s is not None and s.name in rst_names and const_val(e.right) == 0
    return False

class Walker:
    def __init__(self, fsm_syms, rst_names):
        self.fsm = fsm_syms          # symbol -> record
        self.rst = rst_names

    def walk(self, st, ctx, in_reset):
        k = st.kind
        if k == StatementKind.List:
            for s in st.list:
                self.walk(s, ctx, in_reset)
        elif k == StatementKind.Block:
            self.walk(st.body, ctx, in_reset)
        elif k == StatementKind.Timed:
            self.walk(st.stmt, ctx, in_reset)
        elif k == StatementKind.Conditional:
            cond = st.conditions[0].expr
            if is_reset_cond(cond, self.rst):
                self.walk(st.ifTrue, ctx, True)
                if st.ifFalse is not None:
                    self.walk(st.ifFalse, ctx, False)
                return
            tctx = dict(ctx)
            ce = strip(cond)
            if ce.kind == ExpressionKind.BinaryOp and str(ce.op).endswith("Equality") \
                    and not str(ce.op).startswith("Wildcard"):
                s = named(ce.left)
                v = const_val(ce.right)
                if s in self.fsm and v is not None and "Inequality" not in str(ce.op):
                    tctx[s] = {v}
            self.walk(st.ifTrue, tctx, in_reset)
            if st.ifFalse is not None:
                self.walk(st.ifFalse, ctx, in_reset)
        elif k == StatementKind.Case:
            s = named(st.expr)
            listed = set()
            for it in st.items:
                ictx = dict(ctx)
                if s in self.fsm:
                    vals = {const_val(x) for x in it.expressions}
                    vals.discard(None)
                    listed |= vals
                    ictx[s] = vals
                self.walk(it.stmt, ictx, in_reset)
            if st.defaultCase is not None:
                dctx = dict(ctx)
                if s in self.fsm:
                    rest = set(self.fsm[s]["states"].values()) - listed
                    dctx[s] = rest            # empty set => unreachable default
                self.walk(st.defaultCase, dctx, in_reset)
        elif k == StatementKind.ExpressionStatement:
            self.expr(st.expr, ctx, in_reset)
        elif k in (StatementKind.ForLoop, StatementKind.RepeatLoop, StatementKind.WhileLoop):
            body = getattr(st, "body", None)
            if body is not None:
                self.walk(body, ctx, in_reset)

    def expr(self, e, ctx, in_reset):
        if e.kind != ExpressionKind.Assignment:
            return
        s = named(e.left)
        if s not in self.fsm or in_reset:
            return
        rec = self.fsm[s]
        rhs = strip(e.right)
        tos = []
        if rhs.kind == ExpressionKind.ConditionalOp:
            tos = [const_val(rhs.left), const_val(rhs.right)]
        else:
            tos = [const_val(rhs)]
        froms = ctx.get(s)
        for t in tos:
            if t is None:
                rec["nonconst_assign"] = True
                continue
            if froms is None:
                rec["arcs"].add(("*", t))
            else:
                for f in froms:
                    rec["arcs"].add((f, t))

def timing_info(blk):
    body = blk.body
    clk = rst = None
    if body.kind == StatementKind.Timed:
        t = body.timing
        evs = [t] if t.kind == TimingControlKind.SignalEvent else \
              list(t.events) if t.kind == TimingControlKind.EventList else []
        for ev in evs:
            s = named(ev.expr)
            if s is None:
                continue
            edge = str(ev.edge).split(".")[-1]
            if clk is None:
                clk = (s.name, edge)
            else:
                rst = (s.name, edge)
    return clk, rst

def extract(proto):
    s, srcs = proto_sources(proto)
    c = Compilation()
    for f in srcs:
        c.addSyntaxTree(SyntaxTree.fromFile(f))
    out = {}
    seen_defs = covlib_modules(proto)

    def do_instance(inst):
        body = inst.body
        dname = body.definition.name if hasattr(body, "definition") else inst.name
        if dname in seen_defs:
            return
        seen_defs.add(dname)
        fsms = {}
        enum_vars = []
        blocks = []
        children = []
        def v(sym):
            if sym.kind == SymbolKind.Variable and sym.type.canonicalType.kind == SymbolKind.EnumType:
                enum_vars.append(sym)
            elif sym.kind == SymbolKind.ProceduralBlock:
                blocks.append(sym)
            elif sym.kind == SymbolKind.Instance:
                children.append(sym)
        for m in body:
            v(m)
        for ev in enum_vars:
            et = ev.type.canonicalType
            states = {}
            for m in et:
                if m.kind == SymbolKind.EnumValue:
                    states[m.name] = _cv(m.value)
            fsms[ev] = {"var": ev.name, "width": et.bitWidth, "states": states,
                        "arcs": set(), "clock": None, "reset": None}
        for b in blocks:
            clk, rst = timing_info(b)
            if clk is None:
                continue
            rst_names = {rst[0]} if rst else set()
            rst_names |= {"rst", "rst_n", "reset", "reset_n", "rstn", "arst_n"}
            # which FSM vars are written in this block?
            w = Walker(fsms, rst_names)
            before = {k: set(r["arcs"]) for k, r in fsms.items()}
            w.walk(b.body, {}, False)
            for k, r in fsms.items():
                if r["arcs"] != before[k] or r["clock"] is None and _writes(b, k):
                    r["clock"] = r["clock"] or clk
                    r["reset"] = r["reset"] or rst
        res = []
        for k, r in fsms.items():
            if r["clock"] is None:
                continue          # enum var not a clocked state register
            r["arcs"] = sorted(r["arcs"], key=lambda a: (str(a[0]), a[1]))
            res.append(r)
        out[dname] = res
        for ch in children:
            do_instance(ch)

    for inst in c.getRoot().topInstances:
        do_instance(inst)
    return s, out

def _writes(blk, sym):
    found = []
    def v(n):
        if hasattr(n, "kind") and n.kind == ExpressionKind.Assignment:
            if named(n.left) is sym:
                found.append(1)
    try:
        blk.body.visit(v)
    except Exception:
        pass
    return bool(found)

if __name__ == "__main__":
    s, out = extract(sys.argv[1])
    print(json.dumps({"top": s, "modules": out}, indent=1, default=list))
