# Interlaken v1.2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Interlaken_v1_2_top.sv
elaborate Interlaken_v1_2_top
link
read_sdc ../syn/Interlaken_v1_2.sdc
compile -map_effort medium
report_area  > rpt/Interlaken_v1_2_area.rpt
report_timing > rpt/Interlaken_v1_2_timing.rpt
write -format ddc -output netlist/Interlaken_v1_2_top.ddc
write -format verilog -output netlist/Interlaken_v1_2_top.v
quit
