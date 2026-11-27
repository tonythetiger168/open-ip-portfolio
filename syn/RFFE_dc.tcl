# RFFE synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/RFFE_top.sv
elaborate RFFE_top
link
read_sdc ../syn/RFFE.sdc
compile -map_effort medium
report_area  > rpt/RFFE_area.rpt
report_timing > rpt/RFFE_timing.rpt
write -format ddc -output netlist/RFFE_top.ddc
write -format verilog -output netlist/RFFE_top.v
quit
