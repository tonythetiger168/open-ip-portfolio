# ACE-Lite synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ACE_Lite_top.sv
elaborate ACE_Lite_top
link
read_sdc ../syn/ACE_Lite.sdc
compile -map_effort medium
report_area  > rpt/ACE_Lite_area.rpt
report_timing > rpt/ACE_Lite_timing.rpt
write -format ddc -output netlist/ACE_Lite_top.ddc
write -format verilog -output netlist/ACE_Lite_top.v
quit
