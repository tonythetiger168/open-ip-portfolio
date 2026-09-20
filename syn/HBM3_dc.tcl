# HBM3 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HBM3_top.sv
elaborate HBM3_top
link
read_sdc ../syn/HBM3.sdc
compile -map_effort medium
report_area  > rpt/HBM3_area.rpt
report_timing > rpt/HBM3_timing.rpt
write -format ddc -output netlist/HBM3_top.ddc
write -format verilog -output netlist/HBM3_top.v
quit
