# LPDDR6 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LPDDR6_top.sv
elaborate LPDDR6_top
link
read_sdc ../syn/LPDDR6.sdc
compile -map_effort medium
report_area  > rpt/LPDDR6_area.rpt
report_timing > rpt/LPDDR6_timing.rpt
write -format ddc -output netlist/LPDDR6_top.ddc
write -format verilog -output netlist/LPDDR6_top.v
quit
