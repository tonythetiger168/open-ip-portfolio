# SAS synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SAS_top.sv
elaborate SAS_top
link
read_sdc ../syn/SAS.sdc
compile -map_effort medium
report_area  > rpt/SAS_area.rpt
report_timing > rpt/SAS_timing.rpt
write -format ddc -output netlist/SAS_top.ddc
write -format verilog -output netlist/SAS_top.v
quit
