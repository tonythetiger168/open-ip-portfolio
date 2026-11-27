# HBM synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HBM_top.sv
elaborate HBM_top
link
read_sdc ../syn/HBM.sdc
compile -map_effort medium
report_area  > rpt/HBM_area.rpt
report_timing > rpt/HBM_timing.rpt
write -format ddc -output netlist/HBM_top.ddc
write -format verilog -output netlist/HBM_top.v
quit
