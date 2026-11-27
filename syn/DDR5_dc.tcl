# DDR5 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DDR5_top.sv
elaborate DDR5_top
link
read_sdc ../syn/DDR5.sdc
compile -map_effort medium
report_area  > rpt/DDR5_area.rpt
report_timing > rpt/DDR5_timing.rpt
write -format ddc -output netlist/DDR5_top.ddc
write -format verilog -output netlist/DDR5_top.v
quit
