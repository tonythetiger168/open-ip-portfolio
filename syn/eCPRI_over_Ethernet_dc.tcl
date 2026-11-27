# eCPRI over Ethernet synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/eCPRI_over_Ethernet_top.sv
elaborate eCPRI_over_Ethernet_top
link
read_sdc ../syn/eCPRI_over_Ethernet.sdc
compile -map_effort medium
report_area  > rpt/eCPRI_over_Ethernet_area.rpt
report_timing > rpt/eCPRI_over_Ethernet_timing.rpt
write -format ddc -output netlist/eCPRI_over_Ethernet_top.ddc
write -format verilog -output netlist/eCPRI_over_Ethernet_top.v
quit
