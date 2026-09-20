# DSI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DSI_top.sv
elaborate DSI_top
link
read_sdc ../syn/DSI.sdc
compile -map_effort medium
report_area  > rpt/DSI_area.rpt
report_timing > rpt/DSI_timing.rpt
write -format ddc -output netlist/DSI_top.ddc
write -format verilog -output netlist/DSI_top.v
quit
