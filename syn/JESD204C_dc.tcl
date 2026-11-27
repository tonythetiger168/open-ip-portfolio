# JESD204C synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/JESD204C_top.sv
elaborate JESD204C_top
link
read_sdc ../syn/JESD204C.sdc
compile -map_effort medium
report_area  > rpt/JESD204C_area.rpt
report_timing > rpt/JESD204C_timing.rpt
write -format ddc -output netlist/JESD204C_top.ddc
write -format verilog -output netlist/JESD204C_top.v
quit
