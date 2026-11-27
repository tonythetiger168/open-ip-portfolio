# USB3 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB3_top.sv
elaborate USB3_top
link
read_sdc ../syn/USB3.sdc
compile -map_effort medium
report_area  > rpt/USB3_area.rpt
report_timing > rpt/USB3_timing.rpt
write -format ddc -output netlist/USB3_top.ddc
write -format verilog -output netlist/USB3_top.v
quit
