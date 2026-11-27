# LPDDR synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LPDDR_top.sv
elaborate LPDDR_top
link
read_sdc ../syn/LPDDR.sdc
compile -map_effort medium
report_area  > rpt/LPDDR_area.rpt
report_timing > rpt/LPDDR_timing.rpt
write -format ddc -output netlist/LPDDR_top.ddc
write -format verilog -output netlist/LPDDR_top.v
quit
