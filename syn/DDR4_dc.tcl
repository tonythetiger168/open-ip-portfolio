# DDR4 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DDR4_top.sv
elaborate DDR4_top
link
read_sdc ../syn/DDR4.sdc
compile -map_effort medium
report_area  > rpt/DDR4_area.rpt
report_timing > rpt/DDR4_timing.rpt
write -format ddc -output netlist/DDR4_top.ddc
write -format verilog -output netlist/DDR4_top.v
quit
