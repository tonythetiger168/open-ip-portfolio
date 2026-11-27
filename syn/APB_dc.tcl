# APB synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/APB_top.sv
elaborate APB_top
link
read_sdc ../syn/APB.sdc
compile -map_effort medium
report_area  > rpt/APB_area.rpt
report_timing > rpt/APB_timing.rpt
write -format ddc -output netlist/APB_top.ddc
write -format verilog -output netlist/APB_top.v
quit
