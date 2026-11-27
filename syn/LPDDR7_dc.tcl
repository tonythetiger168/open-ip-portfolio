# LPDDR7 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LPDDR7_top.sv
elaborate LPDDR7_top
link
read_sdc ../syn/LPDDR7.sdc
compile -map_effort medium
report_area  > rpt/LPDDR7_area.rpt
report_timing > rpt/LPDDR7_timing.rpt
write -format ddc -output netlist/LPDDR7_top.ddc
write -format verilog -output netlist/LPDDR7_top.v
quit
