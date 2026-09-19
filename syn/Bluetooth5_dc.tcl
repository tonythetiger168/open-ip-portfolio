# Bluetooth5 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Bluetooth5_top.sv
elaborate Bluetooth5_top
link
read_sdc ../syn/Bluetooth5.sdc
compile -map_effort medium
report_area  > rpt/Bluetooth5_area.rpt
report_timing > rpt/Bluetooth5_timing.rpt
write -format ddc -output netlist/Bluetooth5_top.ddc
write -format verilog -output netlist/Bluetooth5_top.v
quit
