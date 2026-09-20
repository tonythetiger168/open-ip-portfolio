# USB2.0 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB2_0_top.sv
elaborate USB2_0_top
link
read_sdc ../syn/USB2_0.sdc
compile -map_effort medium
report_area  > rpt/USB2_0_area.rpt
report_timing > rpt/USB2_0_timing.rpt
write -format ddc -output netlist/USB2_0_top.ddc
write -format verilog -output netlist/USB2_0_top.v
quit
