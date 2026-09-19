# CSE synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CSE_top.sv
elaborate CSE_top
link
read_sdc ../syn/CSE.sdc
compile -map_effort medium
report_area  > rpt/CSE_area.rpt
report_timing > rpt/CSE_timing.rpt
write -format ddc -output netlist/CSE_top.ddc
write -format verilog -output netlist/CSE_top.v
quit
