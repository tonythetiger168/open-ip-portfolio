# LPDDR5X synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LPDDR5X_top.sv
elaborate LPDDR5X_top
link
read_sdc ../syn/LPDDR5X.sdc
compile -map_effort medium
report_area  > rpt/LPDDR5X_area.rpt
report_timing > rpt/LPDDR5X_timing.rpt
write -format ddc -output netlist/LPDDR5X_top.ddc
write -format verilog -output netlist/LPDDR5X_top.v
quit
