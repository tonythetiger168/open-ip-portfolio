# SPMI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SPMI_top.sv
elaborate SPMI_top
link
read_sdc ../syn/SPMI.sdc
compile -map_effort medium
report_area  > rpt/SPMI_area.rpt
report_timing > rpt/SPMI_timing.rpt
write -format ddc -output netlist/SPMI_top.ddc
write -format verilog -output netlist/SPMI_top.v
quit
