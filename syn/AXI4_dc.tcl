# AXI4 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/AXI4_top.sv
elaborate AXI4_top
link
read_sdc ../syn/AXI4.sdc
compile -map_effort medium
report_area  > rpt/AXI4_area.rpt
report_timing > rpt/AXI4_timing.rpt
write -format ddc -output netlist/AXI4_top.ddc
write -format verilog -output netlist/AXI4_top.v
quit
