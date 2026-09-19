# DDR6 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DDR6_top.sv
elaborate DDR6_top
link
read_sdc ../syn/DDR6.sdc
compile -map_effort medium
report_area  > rpt/DDR6_area.rpt
report_timing > rpt/DDR6_timing.rpt
write -format ddc -output netlist/DDR6_top.ddc
write -format verilog -output netlist/DDR6_top.v
quit
