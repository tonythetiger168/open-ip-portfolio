# eUSB2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/eUSB2_top.sv
elaborate eUSB2_top
link
read_sdc ../syn/eUSB2.sdc
compile -map_effort medium
report_area  > rpt/eUSB2_area.rpt
report_timing > rpt/eUSB2_timing.rpt
write -format ddc -output netlist/eUSB2_top.ddc
write -format verilog -output netlist/eUSB2_top.v
quit
