# DisplayPort2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DisplayPort2_top.sv
elaborate DisplayPort2_top
link
read_sdc ../syn/DisplayPort2.sdc
compile -map_effort medium
report_area  > rpt/DisplayPort2_area.rpt
report_timing > rpt/DisplayPort2_timing.rpt
write -format ddc -output netlist/DisplayPort2_top.ddc
write -format verilog -output netlist/DisplayPort2_top.v
quit
