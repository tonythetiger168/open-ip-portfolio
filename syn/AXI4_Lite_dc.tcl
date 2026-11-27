# AXI4-Lite synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/AXI4_Lite_top.sv
elaborate AXI4_Lite_top
link
read_sdc ../syn/AXI4_Lite.sdc
compile -map_effort medium
report_area  > rpt/AXI4_Lite_area.rpt
report_timing > rpt/AXI4_Lite_timing.rpt
write -format ddc -output netlist/AXI4_Lite_top.ddc
write -format verilog -output netlist/AXI4_Lite_top.v
quit
