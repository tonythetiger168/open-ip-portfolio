# Wishbone synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Wishbone_top.sv
elaborate Wishbone_top
link
read_sdc ../syn/Wishbone.sdc
compile -map_effort medium
report_area  > rpt/Wishbone_area.rpt
report_timing > rpt/Wishbone_timing.rpt
write -format ddc -output netlist/Wishbone_top.ddc
write -format verilog -output netlist/Wishbone_top.v
quit
