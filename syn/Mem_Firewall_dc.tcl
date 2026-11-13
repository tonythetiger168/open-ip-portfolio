# Mem_Firewall synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Mem_Firewall_top.sv}
elaborate Mem_Firewall_top
link
read_sdc ../syn/Mem_Firewall.sdc
compile -map_effort medium
report_area  > rpt/Mem_Firewall_area.rpt
report_timing > rpt/Mem_Firewall_timing.rpt
write -format ddc -output netlist/Mem_Firewall_top.ddc
write -format verilog -output netlist/Mem_Firewall_top.v
quit
