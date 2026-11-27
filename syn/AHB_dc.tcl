# AHB synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/AHB_top.sv
elaborate AHB_top
link
read_sdc ../syn/AHB.sdc
compile -map_effort medium
report_area  > rpt/AHB_area.rpt
report_timing > rpt/AHB_timing.rpt
write -format ddc -output netlist/AHB_top.ddc
write -format verilog -output netlist/AHB_top.v
quit
