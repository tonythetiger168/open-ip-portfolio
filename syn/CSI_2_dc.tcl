# CSI-2 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CSI_2_top.sv
elaborate CSI_2_top
link
read_sdc ../syn/CSI_2.sdc
compile -map_effort medium
report_area  > rpt/CSI_2_area.rpt
report_timing > rpt/CSI_2_timing.rpt
write -format ddc -output netlist/CSI_2_top.ddc
write -format verilog -output netlist/CSI_2_top.v
quit
