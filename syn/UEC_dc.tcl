# UEC synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UEC_top.sv
elaborate UEC_top
link
read_sdc ../syn/UEC.sdc
compile -map_effort medium
report_area  > rpt/UEC_area.rpt
report_timing > rpt/UEC_timing.rpt
write -format ddc -output netlist/UEC_top.ddc
write -format verilog -output netlist/UEC_top.v
quit
