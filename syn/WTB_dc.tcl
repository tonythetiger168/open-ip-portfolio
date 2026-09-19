# WTB synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/WTB_top.sv
elaborate WTB_top
link
read_sdc ../syn/WTB.sdc
compile -map_effort medium
report_area  > rpt/WTB_area.rpt
report_timing > rpt/WTB_timing.rpt
write -format ddc -output netlist/WTB_top.ddc
write -format verilog -output netlist/WTB_top.v
quit
