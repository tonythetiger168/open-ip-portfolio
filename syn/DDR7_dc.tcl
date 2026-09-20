# DDR7 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DDR7_top.sv
elaborate DDR7_top
link
read_sdc ../syn/DDR7.sdc
compile -map_effort medium
report_area  > rpt/DDR7_area.rpt
report_timing > rpt/DDR7_timing.rpt
write -format ddc -output netlist/DDR7_top.ddc
write -format verilog -output netlist/DDR7_top.v
quit
