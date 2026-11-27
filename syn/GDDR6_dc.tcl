# GDDR6 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/GDDR6_top.sv
elaborate GDDR6_top
link
read_sdc ../syn/GDDR6.sdc
compile -map_effort medium
report_area  > rpt/GDDR6_area.rpt
report_timing > rpt/GDDR6_timing.rpt
write -format ddc -output netlist/GDDR6_top.ddc
write -format verilog -output netlist/GDDR6_top.v
quit
