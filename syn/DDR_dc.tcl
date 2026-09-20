# DDR synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DDR_top.sv
elaborate DDR_top
link
read_sdc ../syn/DDR.sdc
compile -map_effort medium
report_area  > rpt/DDR_area.rpt
report_timing > rpt/DDR_timing.rpt
write -format ddc -output netlist/DDR_top.ddc
write -format verilog -output netlist/DDR_top.v
quit
