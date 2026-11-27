# HBM4 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HBM4_top.sv
elaborate HBM4_top
link
read_sdc ../syn/HBM4.sdc
compile -map_effort medium
report_area  > rpt/HBM4_area.rpt
report_timing > rpt/HBM4_timing.rpt
write -format ddc -output netlist/HBM4_top.ddc
write -format verilog -output netlist/HBM4_top.v
quit
