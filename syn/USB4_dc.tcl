# USB4 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB4_top.sv
elaborate USB4_top
link
read_sdc ../syn/USB4.sdc
compile -map_effort medium
report_area  > rpt/USB4_area.rpt
report_timing > rpt/USB4_timing.rpt
write -format ddc -output netlist/USB4_top.ddc
write -format verilog -output netlist/USB4_top.v
quit
