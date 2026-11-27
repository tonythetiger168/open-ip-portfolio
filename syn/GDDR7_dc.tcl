# GDDR7 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/GDDR7_top.sv
elaborate GDDR7_top
link
read_sdc ../syn/GDDR7.sdc
compile -map_effort medium
report_area  > rpt/GDDR7_area.rpt
report_timing > rpt/GDDR7_timing.rpt
write -format ddc -output netlist/GDDR7_top.ddc
write -format verilog -output netlist/GDDR7_top.v
quit
