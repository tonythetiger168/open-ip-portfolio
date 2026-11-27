# UALink synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UALink_top.sv
elaborate UALink_top
link
read_sdc ../syn/UALink.sdc
compile -map_effort medium
report_area  > rpt/UALink_area.rpt
report_timing > rpt/UALink_timing.rpt
write -format ddc -output netlist/UALink_top.ddc
write -format verilog -output netlist/UALink_top.v
quit
