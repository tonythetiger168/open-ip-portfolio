#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the APB4 register wrapper of one IP from scripts/apb/specs/<P>.json.

  python3 scripts/apb/gen_apb.py UART            # one IP
  python3 scripts/apb/gen_apb.py --all           # every spec

Writes
  rtl/<P>_apb.sv          APB4 slave wrapping the unchanged core rtl/<P>_top.sv
  tb/<P>_apb_tb.sv        self-checking TB: generic register tests, then the
                          IP-specific task ip_func() from tb/apb/<P>_apb_func.svh
  tb/cov/<P>_apb_sva.sv   checker bound into the wrapper (register model, SVA, FC)
  syn/<P>_apb_yosys.ys    synthesis script of core + wrapper
  docs/ip/<P>.md          IP page: overview, pins, register map, verification

Register map (32-bit words, PADDR[11:0], byte addresses):
  0x000 ID          RO   {code[15:0], major[7:0], minor[7:0]}
  0x004 IRQ_STATUS  W1C  sticky interrupt bits (see per-IP table)
  0x008 IRQ_ENABLE  RW   irq = |(IRQ_STATUS & IRQ_ENABLE)
  0x00C FLAGS       RO   stream state: TX holding register full, RX data available
  0x010 SCRATCH     RW   32-bit scratch register
  0x014 ...         per-IP registers in spec order

Spec ("regs" entries, ports are core ports):
  {"name", "kind": "rw",  "fields": [port | {"port", "reset", "desc"}]}  core inputs
  {"name", "kind": "ro",  "fields": [port | {"port", "desc"}]}           core outputs
  {"name", "kind": "cmd", "fields": [...]}   1-bit core inputs, write-1 pulses one clock
  {"name", "kind": "stream_in",  "data", "valid", ["ready"]}   core input stream:
      the holding register is presented with valid=1 until ready; writing the
      last word commits it; any write while full is dropped and sets <NAME>_OVF;
      the handshake sets <NAME>_DONE. Without "ready", committing pulses valid.
  {"name", "kind": "stream_out", "data", "valid"}   core output stream: a valid
      beat is captured when the register is empty (or popped in the same clock),
      sets <NAME>_AVAIL; reading the last word pops it; a beat arriving while
      full is dropped and sets <NAME>_OVF.
  "irqs": [{"name", "port", "desc"}]   1-bit core outputs latched into IRQ_STATUS
  "tie": {port: "value"}               core inputs tied off
Every other core port passes through to the wrapper unchanged. The core clock
and reset are PCLK and PRESETN (spec "clock"/"reset" name the core's ports).
"""
import json, math, os, re, sys
from pyslang import syntax, ast

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC_DIR = os.path.join(ROOT, "scripts", "apb", "specs")
AW = 12


def core_ports(path, top):
    t = syntax.SyntaxTree.fromFile(path)
    comp = ast.Compilation()
    comp.addSyntaxTree(t)
    inst = next(i for i in comp.getRoot().topInstances if i.name == top)
    width = {p.name: p.type.bitWidth for p in inst.body.portList}
    dirn = {p.name: ("input" if "In" in str(p.direction) else
                     "output" if "Out" in str(p.direction) else "inout")
            for p in inst.body.portList}
    mod = next(m for m in t.root.members if str(m.header.name).strip() == top)
    params = []
    if mod.header.parameters is not None:
        for d in mod.header.parameters.declarations:
            if str(d).strip() != ",":
                params.append(str(d).strip())
    decl, last = {}, None
    for pd in mod.header.ports.ports:
        if str(pd).strip() == ",":
            continue
        name = str(pd.declarator).strip().split()[0]
        hdr = str(pd.header).strip() if pd.header is not None else ""
        if hdr and re.match(r"(input|output|inout)\b", hdr):
            last = hdr
        decl[name] = re.sub(r"\s+", " ", last or hdr)
    order = [p.name for p in inst.body.portList]
    header = []
    for ln in open(path).read().split("\n"):
        if ln.startswith("//"):
            header.append(ln[2:].strip())
        elif header:
            break
    return order, width, dirn, decl, params, header


def param_names(params):
    out = []
    for p in params:
        m = re.search(r"(\w+)\s*=", p)
        if m:
            out.append(m.group(1))
    return out


class Field:
    def __init__(self, name, port, lo, w, plo, reset=0, desc=""):
        self.name, self.port, self.lo, self.w, self.plo = name, port, lo, w, plo
        self.reset, self.desc = reset, desc


class Word:
    def __init__(self, name, kind, reg=None, desc=""):
        self.name, self.kind, self.reg, self.desc = name, kind, reg, desc
        self.fields, self.off, self.last = [], 0, True

    @property
    def wb(self):
        return max((f.lo + f.w for f in self.fields), default=0)

    def reset(self):
        v = 0
        for f in self.fields:
            v |= (f.reset & ((1 << f.w) - 1)) << f.lo
        return v


def data_ports(r):
    return r["data"] if isinstance(r["data"], list) else [r["data"]]


def norm_fields(lst):
    out = []
    for f in lst:
        out.append({"port": f} if isinstance(f, str) else dict(f))
    return out


def pack(regname, kind, fields, width, desc):
    """Pack core ports LSB-first into 32-bit words; a port wider than the
    room left starts a new word, a port wider than 32 bits spans words."""
    words, cur, pos = [], [], 0
    def flush():
        nonlocal cur, pos
        if cur:
            words.append(cur)
        cur, pos = [], 0
    for f in fields:
        w = width[f["port"]]
        rst = int(str(f.get("reset", 0)), 0)
        if w > 32:
            flush()
            for k in range(math.ceil(w / 32)):
                cw = min(32, w - 32 * k)
                words.append([Field(f'{f["port"]}[{32*k+cw-1}:{32*k}]', f["port"], 0, cw, 32 * k,
                                    rst >> (32 * k), f.get("desc", ""))])
            continue
        if pos + w > 32:
            flush()
        cur.append(Field(f["port"], f["port"], pos, w, 0, rst, f.get("desc", "")))
        pos += w
    flush()
    out = []
    for i, fl in enumerate(words):
        wd = Word(regname if len(words) == 1 else f"{regname}{i}", kind, regname, desc)
        wd.fields = fl
        wd.last = i == len(words) - 1
        out.append(wd)
    return out


def layout(spec, width, dirn):
    words = [Word("ID", "id", desc="IP identification: code, major and minor version"),
             Word("IRQ_STATUS", "irq_status", desc="Sticky interrupt bits, write 1 to clear"),
             Word("IRQ_ENABLE", "irq_enable", desc="Interrupt enables; irq = |(IRQ_STATUS & IRQ_ENABLE)"),
             Word("FLAGS", "flags", desc="Stream holding-register state"),
             Word("SCRATCH", "scratch", desc="Scratch register, no effect on the core")]
    irqb, flagb, mapped = [], [], set()
    for q in spec.get("irqs", []):
        assert dirn[q["port"]] == "output" and width[q["port"]] == 1, q
        irqb.append((q["name"], q.get("desc", f"core output {q['port']} was high"), q["port"]))
        mapped.add(q["port"])
    for r in spec["regs"]:
        k = r["kind"]
        if k in ("rw", "ro", "cmd"):
            fl = norm_fields(r["fields"])
            for f in fl:
                exp = "output" if k == "ro" else "input"
                assert dirn[f["port"]] == exp, (r["name"], f["port"], dirn[f["port"]])
                if k == "cmd":
                    assert width[f["port"]] == 1, f
                mapped.add(f["port"])
            words += pack(r["name"], k, fl, width, r.get("desc", ""))
        elif k in ("stream_in", "stream_out"):
            exp = "input" if k == "stream_in" else "output"
            dports = data_ports(r)
            assert all(dirn[p] == exp for p in dports) and dirn[r["valid"]] == exp, r
            mapped |= set(dports) | {r["valid"]}
            if r.get("ready"):
                assert dirn[r["ready"]] == ("output" if k == "stream_in" else "input"), r
                mapped.add(r["ready"])
            ws = pack(r["name"], "sin" if k == "stream_in" else "sout",
                      [{"port": p, "desc": r.get("fdesc", {}).get(p, r.get("desc", "") if len(dports) == 1 else "")}
                       for p in dports], width,
                      r.get("desc", ""))
            for w in ws:
                w.reg = r["name"]
            words += ws
            if k == "stream_in" and r.get("ready"):
                irqb.append((f'{r["name"]}_DONE', f"{r['name']} beat accepted by the core", None))
                irqb.append((f'{r["name"]}_OVF', f"write to {r['name']} while full (dropped)", None))
                flagb.append((f'{r["name"]}_FULL', f"{r['name']} holds a beat the core has not taken"))
            if k == "stream_out":
                irqb.append((f'{r["name"]}_AVAIL', f"{r['name']} captured a beat", None))
                irqb.append((f'{r["name"]}_OVF', f"beat dropped, {r['name']} was full", None))
                flagb.append((f'{r["name"]}_AVAIL', f"{r['name']} holds an unread beat"))
        else:
            raise SystemExit(f"unknown kind {k}")
    for p in spec.get("tie", {}):
        assert dirn[p] == "input", p
        mapped.add(p)
    assert 0 < len(irqb) <= 32 and len(flagb) <= 32
    names = [n for n, _, _ in irqb]
    assert len(set(names)) == len(names), f"duplicate interrupt names: {names}"
    for i, w in enumerate(words):
        w.off = 4 * i
    assert 4 * len(words) <= (1 << AW)
    return words, irqb, flagb, mapped


def vbits(w):
    return "" if w == 1 else f"[{w-1}:0]"


def hexs(v, w=32):
    return f"{w}'h{v:0{(w+3)//4}X}"


def streams(spec):
    return [r for r in spec["regs"] if r["kind"] in ("stream_in", "stream_out")]


def stream_words(words, name):
    return [w for w in words if w.reg == name and w.kind in ("sin", "sout")]


def irq_index(irqb, name):
    return [n for n, _, _ in irqb].index(name)


def flag_index(flagb, name):
    return [n for n, _ in flagb].index(name)


def all_hits(words, ws):
    return " | ".join(f"hit[{words.index(w)}]" for w in ws)


def gen_rtl(P, spec, core):
    order, width, dirn, decl, params, header = core
    words, irqb, flagb, mapped = layout(spec, width, dirn)
    clk, rst = spec.get("clock", "clk"), spec.get("reset", "rst_n")
    pt = [p for p in order if p not in mapped and p not in (clk, rst)]
    code, ver = int(spec["code"], 0), spec["version"]
    maj, mnr = (int(x) for x in ver.split("."))
    NW, NI = len(words), len(irqb)
    L = []
    a = L.append
    a("// SPDX-License-Identifier: Apache-2.0")
    a("// " + "=" * 76)
    a(f"// {P}_apb: APB4 register wrapper around {P}_top (generated by")
    a(f"// scripts/apb/gen_apb.py from scripts/apb/specs/{P}.json; do not edit)")
    a("// " + "-" * 76)
    a("//  - APB4 slave, zero wait states (PREADY = PSEL & PENABLE), 32-bit data,")
    a(f"//    {AW}-bit byte address; PSLVERR on an unmapped or misaligned access.")
    a("//  - PSTRB byte lanes apply to every writable register.")
    a("//  - The core runs on PCLK/PRESETN; protocol pins pass through unchanged.")
    a("//  - Register map: docs/ip/" + P + ".md")
    a("// " + "=" * 76)
    if params:
        a(f"module {P}_apb #(")
        a(",\n".join("  " + p for p in params))
        a(") (")
    else:
        a(f"module {P}_apb (")
    ports = ["  input  logic        PCLK", "  input  logic        PRESETN",
             "  input  logic        PSEL", "  input  logic        PENABLE",
             "  input  logic        PWRITE", f"  input  logic [{AW-1}:0] PADDR",
             "  input  logic [31:0] PWDATA", "  input  logic [3:0]  PSTRB",
             "  output logic [31:0] PRDATA", "  output logic        PREADY",
             "  output logic        PSLVERR", "  output logic        irq"]
    ports += [f"  {decl[p]} {p}" for p in pt]
    a(",\n".join(ports))
    a(");")
    a(f"  localparam logic [31:0] ID_VALUE = 32'h{code:04X}{maj:02X}{mnr:02X};")
    a("")
    a("  // ---------------- core ----------------")
    for p in order:
        if p in mapped and p not in spec.get("tie", {}):
            a(f"  logic {vbits(width[p]):<8} c_{p};")
    pn = param_names(params)
    conn = [f".{clk}(PCLK)", f".{rst}(PRESETN)"]
    for p in order:
        if p in (clk, rst):
            continue
        if p in spec.get("tie", {}):
            conn.append(f".{p}({spec['tie'][p]})")
        elif p in mapped:
            conn.append(f".{p}(c_{p})")
        else:
            conn.append(f".{p}({p})")
    pp = (" #(" + ", ".join(f".{n}({n})" for n in pn) + ")") if pn else ""
    a(f"  {P}_top{pp} u_core (")
    a(",\n".join("    " + c for c in conn))
    a("  );")
    a("")
    a("  // ---------------- APB decode ----------------")
    a("  wire        acc     = PSEL & PENABLE;")
    a("  wire        wr      = acc & PWRITE;")
    a("  wire        rd      = acc & ~PWRITE;")
    a("  wire [31:0] wmask   = {{8{PSTRB[3]}}, {8{PSTRB[2]}}, {8{PSTRB[1]}}, {8{PSTRB[0]}}};")
    a(f"  logic [{NW-1}:0] hit;")
    a("  always_comb begin")
    a("    hit = '0;")
    a(f"    if (PADDR[1:0] == 2'b00 && PADDR[{AW-1}:2] < {AW-2}'d{NW}) hit[PADDR[{AW-1}:2]] = 1'b1;")
    a("  end")
    a("  assign PREADY  = acc;")
    a("  assign PSLVERR = acc & ~|hit;")
    a("")
    a("  // ---------------- registers ----------------")
    a(f"  logic [{NI-1}:0] irq_status, irq_enable, irq_set;")
    a("  logic [31:0] scratch;")
    for w in words:
        i = words.index(w)
        if w.kind == "rw":
            a(f"  logic [{w.wb-1}:0] r_{w.name};   // {hexs(w.off, AW)} {w.name}")
        elif w.kind == "cmd":
            a(f"  logic [{w.wb-1}:0] p_{w.name};   // {hexs(w.off, AW)} {w.name} (pulses)")
        elif w.kind in ("sin", "sout"):
            a(f"  logic [{w.wb-1}:0] h_{w.name};   // {hexs(w.off, AW)} {w.name} holding register")
    for r in streams(spec):
        n = r["name"]
        if r["kind"] == "stream_in":
            a(f"  logic {'full_' + n if r.get('ready') else 'vld_' + n};")
        else:
            a(f"  logic avail_{n};")
    a("")
    a("  always_ff @(posedge PCLK or negedge PRESETN) begin")
    a("    if (!PRESETN) begin")
    a("      irq_status <= '0; irq_enable <= '0; scratch <= '0;")
    for w in words:
        if w.kind == "rw":
            a(f"      r_{w.name} <= {w.wb}'h{w.reset():X};")
        elif w.kind == "cmd":
            a(f"      p_{w.name} <= '0;")
        elif w.kind in ("sin", "sout"):
            a(f"      h_{w.name} <= '0;")
    for r in streams(spec):
        n = r["name"]
        if r["kind"] == "stream_in":
            a(f"      {'full_' + n if r.get('ready') else 'vld_' + n} <= 1'b0;")
        else:
            a(f"      avail_{n} <= 1'b0;")
    a("    end else begin")
    a(f"      irq_status <= (irq_status & ~((wr && hit[1]) ? PWDATA[{NI-1}:0] & wmask[{NI-1}:0] : '0)) | irq_set;")
    a(f"      if (wr && hit[2]) irq_enable <= (irq_enable & ~wmask[{NI-1}:0]) | (PWDATA[{NI-1}:0] & wmask[{NI-1}:0]);")
    a("      if (wr && hit[4]) scratch <= (scratch & ~wmask) | (PWDATA & wmask);")
    for w in words:
        i = words.index(w)
        m = f"wmask[{w.wb-1}:0]"
        d = f"PWDATA[{w.wb-1}:0]"
        if w.kind == "rw":
            a(f"      if (wr && hit[{i}]) r_{w.name} <= (r_{w.name} & ~{m}) | ({d} & {m});")
        elif w.kind == "cmd":
            a(f"      p_{w.name} <= (wr && hit[{i}]) ? {d} & {m} : '0;")
    for r in streams(spec):
        n = r["name"]
        ws = stream_words(words, n)
        last = words.index(ws[-1])
        if r["kind"] == "stream_in" and r.get("ready"):
            for w in ws:
                i = words.index(w)
                m, d = f"wmask[{w.wb-1}:0]", f"PWDATA[{w.wb-1}:0]"
                a(f"      if (wr && hit[{i}] && !full_{n}) h_{w.name} <= (h_{w.name} & ~{m}) | ({d} & {m});")
            a(f"      if (wr && hit[{last}] && !full_{n}) full_{n} <= 1'b1;")
            a(f"      else if (full_{n} && c_{r['ready']}) full_{n} <= 1'b0;")
        elif r["kind"] == "stream_in":
            for w in ws:
                i = words.index(w)
                m, d = f"wmask[{w.wb-1}:0]", f"PWDATA[{w.wb-1}:0]"
                a(f"      if (wr && hit[{i}]) h_{w.name} <= (h_{w.name} & ~{m}) | ({d} & {m});")
            a(f"      vld_{n} <= wr && hit[{last}];")
        else:
            a(f"      if (c_{r['valid']} && (!avail_{n} || (rd && hit[{last}]))) begin")
            for w in ws:
                for f in w.fields:
                    dst = f"h_{w.name}[{f.lo + f.w - 1}:{f.lo}]" if w.wb > 1 else f"h_{w.name}"
                    src = f"c_{f.port}[{f.plo + f.w - 1}:{f.plo}]" if width[f.port] > 1 else f"c_{f.port}"
                    a(f"        {dst} <= {src};")
            a(f"        avail_{n} <= 1'b1;")
            a(f"      end else if (rd && hit[{last}]) avail_{n} <= 1'b0;")
    a("    end")
    a("  end")
    a("")
    a("  // ---------------- core inputs ----------------")
    for w in words:
        for f in w.fields:
            src = {"rw": "r_", "cmd": "p_", "sin": "h_"}.get(w.kind)
            if not src:
                continue
            sl = f"{src}{w.name}[{f.lo + f.w - 1}:{f.lo}]" if w.wb > 1 else f"{src}{w.name}"
            dst = f"c_{f.port}[{f.plo + f.w - 1}:{f.plo}]" if width[f.port] > 1 and (w.kind == "sin" or width[f.port] > 32) else f"c_{f.port}"
            a(f"  assign {dst} = {sl};")
    for r in streams(spec):
        if r["kind"] == "stream_in":
            n = r["name"]
            a(f"  assign c_{r['valid']} = {'full_' + n if r.get('ready') else 'vld_' + n};")
    a("")
    a("  // ---------------- interrupts and flags ----------------")
    a("  always_comb begin")
    a("    irq_set = '0;")
    for i, (n, _, port) in enumerate(irqb):
        if port:
            a(f"    irq_set[{i}] = c_{port};")
    for r in streams(spec):
        n = r["name"]
        ws = stream_words(words, n)
        last = words.index(ws[-1])
        if r["kind"] == "stream_in" and r.get("ready"):
            a(f"    irq_set[{irq_index(irqb, n + '_DONE')}] = full_{n} & c_{r['ready']};")
            a(f"    irq_set[{irq_index(irqb, n + '_OVF')}] = wr & ({all_hits(words, ws)}) & full_{n};")
        elif r["kind"] == "stream_out":
            a(f"    irq_set[{irq_index(irqb, n + '_AVAIL')}] = c_{r['valid']} & (~avail_{n} | (rd & hit[{last}]));")
            a(f"    irq_set[{irq_index(irqb, n + '_OVF')}] = c_{r['valid']} & avail_{n} & ~(rd & hit[{last}]);")
    a("  end")
    a("  assign irq = |(irq_status & irq_enable);")
    fl = []
    for n, _ in flagb:
        fl.append(f"full_{n[:-5]}" if n.endswith("_FULL") else f"avail_{n[:-6]}")
    if fl:
        a(f"  wire [{len(fl)-1}:0] flags = {{{', '.join(reversed(fl))}}};")
    a("")
    a("  // ---------------- read mux ----------------")
    a("  logic [31:0] rdata;")
    a("  always_comb begin")
    a("    rdata = '0;")
    a(f"    case (PADDR[{AW-1}:2])")
    for i, w in enumerate(words):
        if w.kind == "id":
            v = "ID_VALUE"
        elif w.kind == "irq_status":
            v = "32'(irq_status)"
        elif w.kind == "irq_enable":
            v = "32'(irq_enable)"
        elif w.kind == "flags":
            if not flagb:
                continue
            v = "32'(flags)"
        elif w.kind == "scratch":
            v = "scratch"
        elif w.kind == "rw":
            v = f"32'(r_{w.name})"
        elif w.kind == "cmd":
            continue
        elif w.kind in ("sin", "sout"):
            v = f"32'(h_{w.name})"
        else:   # ro
            parts = []
            for f in reversed(w.fields):
                parts.append(f"c_{f.port}[{f.plo + f.w - 1}:{f.plo}]" if width[f.port] > 32 else f"c_{f.port}")
            v = f"32'({{{', '.join(parts)}}})"   # fields are packed from bit 0
        a(f"      {AW-2}'d{i}: rdata = {v};")
    a("      default: rdata = '0;")
    a("    endcase")
    a("  end")
    a("  assign PRDATA = (rd && |hit) ? rdata : '0;")
    a("endmodule")
    return "\n".join(L) + "\n", words, irqb, flagb, pt


def main():
    args = sys.argv[1:]
    if args == ["--all"]:
        args = sorted(f[:-5] for f in os.listdir(SPEC_DIR) if f.endswith(".json"))
    for P in args:
        gen_one(P)


def gen_one(P):
    spec = json.load(open(os.path.join(SPEC_DIR, P + ".json")))
    core = core_ports(os.path.join(ROOT, "rtl", P + "_top.sv"), P + "_top")
    rtl, words, irqb, flagb, pt = gen_rtl(P, spec, core)
    import gen_apb_tb
    files = {
        f"rtl/{P}_apb.sv": rtl,
        f"tb/{P}_apb_tb.sv": gen_apb_tb.gen_tb(P, spec, core, words, irqb, flagb, pt),
        f"tb/cov/{P}_apb_sva.sv": gen_apb_tb.gen_sva(P, spec, core, words, irqb, flagb, pt),
        f"syn/{P}_apb_yosys.ys": gen_apb_tb.gen_syn(P, spec),
        f"docs/ip/{P}.md": gen_apb_tb.gen_doc(P, spec, core, words, irqb, flagb, pt),
    }
    mk = os.path.join(ROOT, f"Makefile.{P}")
    mtxt = open(mk).read()
    if "\napb:" not in mtxt:
        mtxt = mtxt.replace("\nclean:", "\napb:\n"
            "\t$(SIM) $(VFLAGS) -I tb -o simv_apb rtl/$(S)_top.sv $(DEPS) rtl/$(S)_apb.sv tb/$(S)_apb_tb.sv\n"
            "\t./simv_apb\n"
            "\tcd work && $(SYN) ../syn/$(S)_apb_yosys.ys\n\nclean:")
        mtxt = mtxt.replace("rm -f simv ", "rm -f simv simv_apb ")
        mtxt = mtxt.replace(".PHONY: all sim syn clean", ".PHONY: all sim syn apb clean")
        files[f"Makefile.{P}"] = mtxt
    for f, txt in files.items():
        os.makedirs(os.path.dirname(os.path.join(ROOT, f)), exist_ok=True)
        open(os.path.join(ROOT, f), "w").write(txt)
    print(f"{P}: {len(words)} words, {len(irqb)} irq bits, {len(pt)} pass-through pins")


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
