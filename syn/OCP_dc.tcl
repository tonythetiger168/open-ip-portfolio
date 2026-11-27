# OCP synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/OCP_top.sv
elaborate OCP_top
link
read_sdc ../syn/OCP.sdc
compile -map_effort medium
report_area  > rpt/OCP_area.rpt
report_timing > rpt/OCP_timing.rpt
write -format ddc -output netlist/OCP_top.ddc
write -format verilog -output netlist/OCP_top.v
quit
