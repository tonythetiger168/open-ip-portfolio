# HBM2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HBM2_top.sv
elaborate HBM2_top
link
read_sdc ../syn/HBM2.sdc
compile -map_effort medium
report_area  > rpt/HBM2_area.rpt
report_timing > rpt/HBM2_timing.rpt
write -format ddc -output netlist/HBM2_top.ddc
write -format verilog -output netlist/HBM2_top.v
quit
