# ATB synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ATB_top.sv
elaborate ATB_top
link
read_sdc ../syn/ATB.sdc
compile -map_effort medium
report_area  > rpt/ATB_area.rpt
report_timing > rpt/ATB_timing.rpt
write -format ddc -output netlist/ATB_top.ddc
write -format verilog -output netlist/ATB_top.v
quit
