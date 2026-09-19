# USB2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB2_top.sv
elaborate USB2_top
link
read_sdc ../syn/USB2.sdc
compile -map_effort medium
report_area  > rpt/USB2_area.rpt
report_timing > rpt/USB2_timing.rpt
write -format ddc -output netlist/USB2_top.ddc
write -format verilog -output netlist/USB2_top.v
quit
