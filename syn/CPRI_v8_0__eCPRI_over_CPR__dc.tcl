# CPRI v8.0 (eCPRI over CPR) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CPRI_v8_0__eCPRI_over_CPR__top.sv
elaborate CPRI_v8_0__eCPRI_over_CPR__top
link
read_sdc ../syn/CPRI_v8_0__eCPRI_over_CPR_.sdc
compile -map_effort medium
report_area  > rpt/CPRI_v8_0__eCPRI_over_CPR__area.rpt
report_timing > rpt/CPRI_v8_0__eCPRI_over_CPR__timing.rpt
write -format ddc -output netlist/CPRI_v8_0__eCPRI_over_CPR__top.ddc
write -format verilog -output netlist/CPRI_v8_0__eCPRI_over_CPR__top.v
quit
