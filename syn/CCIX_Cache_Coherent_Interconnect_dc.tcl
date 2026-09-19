# CCIX Cache Coherent Interconnect synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CCIX_Cache_Coherent_Interconnect_top.sv
elaborate CCIX_Cache_Coherent_Interconnect_top
link
read_sdc ../syn/CCIX_Cache_Coherent_Interconnect.sdc
compile -map_effort medium
report_area  > rpt/CCIX_Cache_Coherent_Interconnect_area.rpt
report_timing > rpt/CCIX_Cache_Coherent_Interconnect_timing.rpt
write -format ddc -output netlist/CCIX_Cache_Coherent_Interconnect_top.ddc
write -format verilog -output netlist/CCIX_Cache_Coherent_Interconnect_top.v
quit
