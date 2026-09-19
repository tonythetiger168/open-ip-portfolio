# Ethernet-AVB-TSN synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Ethernet_AVB_TSN_top.sv
elaborate Ethernet_AVB_TSN_top
link
read_sdc ../syn/Ethernet_AVB_TSN.sdc
compile -map_effort medium
report_area  > rpt/Ethernet_AVB_TSN_area.rpt
report_timing > rpt/Ethernet_AVB_TSN_timing.rpt
write -format ddc -output netlist/Ethernet_AVB_TSN_top.ddc
write -format verilog -output netlist/Ethernet_AVB_TSN_top.v
quit
