# SPDX-License-Identifier: Apache-2.0
# SAS Open IP -- sim & synthesis entry points
S      := SAS
DEPS   := rtl/SATA_top.sv
SIM    ?= iverilog
VFLAGS := -g2012 -Wall
SYN    ?= yosys

all: sim syn

sim:
	$(SIM) $(VFLAGS) -o simv rtl/$(S)_top.sv $(DEPS) tb/$(S)_tb.sv
	./simv

# functional sim at BIT_CLKS=4 (divided bit rate)
sim_bitclks:
	$(SIM) $(VFLAGS) -o simv_bitclks rtl/$(S)_top.sv $(DEPS) tb/$(S)_bitclks_tb.sv
	./simv_bitclks

syn:
	cd work && $(SYN) ../syn/$(S)_yosys.ys

clean:
	rm -f simv *.vcd work/*.json work/*_netlist.v
.PHONY: all sim syn clean
