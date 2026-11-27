# HBM3E synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HBM3E_top.sv
elaborate HBM3E_top
link
read_sdc ../syn/HBM3E.sdc
compile -map_effort medium
report_area  > rpt/HBM3E_area.rpt
report_timing > rpt/HBM3E_timing.rpt
write -format ddc -output netlist/HBM3E_top.ddc
write -format verilog -output netlist/HBM3E_top.v
quit
