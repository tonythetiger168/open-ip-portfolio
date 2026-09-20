# ACE synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ACE_top.sv
elaborate ACE_top
link
read_sdc ../syn/ACE.sdc
compile -map_effort medium
report_area  > rpt/ACE_area.rpt
report_timing > rpt/ACE_timing.rpt
write -format ddc -output netlist/ACE_top.ddc
write -format verilog -output netlist/ACE_top.v
quit
