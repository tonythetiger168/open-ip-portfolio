# Avalon-MM synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Avalon_MM_top.sv
elaborate Avalon_MM_top
link
read_sdc ../syn/Avalon_MM.sdc
compile -map_effort medium
report_area  > rpt/Avalon_MM_area.rpt
report_timing > rpt/Avalon_MM_timing.rpt
write -format ddc -output netlist/Avalon_MM_top.ddc
write -format verilog -output netlist/Avalon_MM_top.v
quit
