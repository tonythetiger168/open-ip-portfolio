# AXI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/AXI_top.sv
elaborate AXI_top
link
read_sdc ../syn/AXI.sdc
compile -map_effort medium
report_area  > rpt/AXI_area.rpt
report_timing > rpt/AXI_timing.rpt
write -format ddc -output netlist/AXI_top.ddc
write -format verilog -output netlist/AXI_top.v
quit
