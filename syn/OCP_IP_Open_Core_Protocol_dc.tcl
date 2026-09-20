# OCP-IP Open Core Protocol synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/OCP_IP_Open_Core_Protocol_top.sv
elaborate OCP_IP_Open_Core_Protocol_top
link
read_sdc ../syn/OCP_IP_Open_Core_Protocol.sdc
compile -map_effort medium
report_area  > rpt/OCP_IP_Open_Core_Protocol_area.rpt
report_timing > rpt/OCP_IP_Open_Core_Protocol_timing.rpt
write -format ddc -output netlist/OCP_IP_Open_Core_Protocol_top.ddc
write -format verilog -output netlist/OCP_IP_Open_Core_Protocol_top.v
quit
