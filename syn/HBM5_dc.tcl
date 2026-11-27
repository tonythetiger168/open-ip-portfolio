# HBM5 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HBM5_top.sv
elaborate HBM5_top
link
read_sdc ../syn/HBM5.sdc
compile -map_effort medium
report_area  > rpt/HBM5_area.rpt
report_timing > rpt/HBM5_timing.rpt
write -format ddc -output netlist/HBM5_top.ddc
write -format verilog -output netlist/HBM5_top.v
quit
