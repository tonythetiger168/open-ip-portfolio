# gem5 config fragment for DDR controller co-verification
# Usage: gem5.opt ddr_gem5.py --cmd "access sequence"
# Produces m5out/dramctrl.trace with activate/rd/wr commands per address,
# comparable against the RTL trace port output (same cmd/addr semantics).
import m5
from m5.objects import *

system = System()
system.clk_domain = SrcClockDomain(clock="1GHz")
system.mem_mode = "timing"
system.mem_ranges = [AddrRange("256MB")]

system.membus = SystemXBar()
system.mem_ctrl = MemCtrl()
system.mem_ctrl.dram = DDR4_2400_8x8()   # swap: DDR3_1600_8x8, LPDDR4, etc.
system.mem_ctrl.dram.range = system.mem_ranges[0]
system.mem_ctrl.port = system.membus.master

# Enable DRAM command tracing (gem5 must be built with --trace-flags=DRAM)
# m5.trace.enable("DRAM")

system.system_port = system.membus.slave
root = Root(full_system=False, system=system)
m5.instantiate()
m5.simulate()
