# CHI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CHI_top.sv
elaborate CHI_top
link
read_sdc ../syn/CHI.sdc
compile -map_effort medium
report_area  > rpt/CHI_area.rpt
report_timing > rpt/CHI_timing.rpt
write -format ddc -output netlist/CHI_top.ddc
write -format verilog -output netlist/CHI_top.v
quit
