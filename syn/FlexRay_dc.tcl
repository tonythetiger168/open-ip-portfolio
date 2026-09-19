# FlexRay synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/FlexRay_top.sv
elaborate FlexRay_top
link
read_sdc ../syn/FlexRay.sdc
compile -map_effort medium
report_area  > rpt/FlexRay_area.rpt
report_timing > rpt/FlexRay_timing.rpt
write -format ddc -output netlist/FlexRay_top.ddc
write -format verilog -output netlist/FlexRay_top.v
quit
