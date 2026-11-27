# 1-Wire synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/_1_Wire_top.sv
elaborate _1_Wire_top
link
read_sdc ../syn/_1_Wire.sdc
compile -map_effort medium
report_area  > rpt/_1_Wire_area.rpt
report_timing > rpt/_1_Wire_timing.rpt
write -format ddc -output netlist/_1_Wire_top.ddc
write -format verilog -output netlist/_1_Wire_top.v
quit
