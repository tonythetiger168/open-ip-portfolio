# USB3.2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB3_2_top.sv
elaborate USB3_2_top
link
read_sdc ../syn/USB3_2.sdc
compile -map_effort medium
report_area  > rpt/USB3_2_area.rpt
report_timing > rpt/USB3_2_timing.rpt
write -format ddc -output netlist/USB3_2_top.ddc
write -format verilog -output netlist/USB3_2_top.v
quit
