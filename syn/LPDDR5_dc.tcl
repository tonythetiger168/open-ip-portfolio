# LPDDR5 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LPDDR5_top.sv
elaborate LPDDR5_top
link
read_sdc ../syn/LPDDR5.sdc
compile -map_effort medium
report_area  > rpt/LPDDR5_area.rpt
report_timing > rpt/LPDDR5_timing.rpt
write -format ddc -output netlist/LPDDR5_top.ddc
write -format verilog -output netlist/LPDDR5_top.v
quit
