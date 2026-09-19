# CXL synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CXL_top.sv
elaborate CXL_top
link
read_sdc ../syn/CXL.sdc
compile -map_effort medium
report_area  > rpt/CXL_area.rpt
report_timing > rpt/CXL_timing.rpt
write -format ddc -output netlist/CXL_top.ddc
write -format verilog -output netlist/CXL_top.v
quit
