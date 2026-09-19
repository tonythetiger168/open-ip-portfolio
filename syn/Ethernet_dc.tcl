# Ethernet synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Ethernet_top.sv
elaborate Ethernet_top
link
read_sdc ../syn/Ethernet.sdc
compile -map_effort medium
report_area  > rpt/Ethernet_area.rpt
report_timing > rpt/Ethernet_timing.rpt
write -format ddc -output netlist/Ethernet_top.ddc
write -format verilog -output netlist/Ethernet_top.v
quit
