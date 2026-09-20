# CAN synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CAN_top.sv
elaborate CAN_top
link
read_sdc ../syn/CAN.sdc
compile -map_effort medium
report_area  > rpt/CAN_area.rpt
report_timing > rpt/CAN_timing.rpt
write -format ddc -output netlist/CAN_top.ddc
write -format verilog -output netlist/CAN_top.v
quit
