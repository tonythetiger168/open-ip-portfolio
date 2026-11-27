# LPDDR4 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LPDDR4_top.sv
elaborate LPDDR4_top
link
read_sdc ../syn/LPDDR4.sdc
compile -map_effort medium
report_area  > rpt/LPDDR4_area.rpt
report_timing > rpt/LPDDR4_timing.rpt
write -format ddc -output netlist/LPDDR4_top.ddc
write -format verilog -output netlist/LPDDR4_top.v
quit
