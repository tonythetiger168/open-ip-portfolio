# GDDR5 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/GDDR5_top.sv
elaborate GDDR5_top
link
read_sdc ../syn/GDDR5.sdc
compile -map_effort medium
report_area  > rpt/GDDR5_area.rpt
report_timing > rpt/GDDR5_timing.rpt
write -format ddc -output netlist/GDDR5_top.ddc
write -format verilog -output netlist/GDDR5_top.v
quit
