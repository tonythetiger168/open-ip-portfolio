# Avalon-ST synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Avalon_ST_top.sv
elaborate Avalon_ST_top
link
read_sdc ../syn/Avalon_ST.sdc
compile -map_effort medium
report_area  > rpt/Avalon_ST_area.rpt
report_timing > rpt/Avalon_ST_timing.rpt
write -format ddc -output netlist/Avalon_ST_top.ddc
write -format verilog -output netlist/Avalon_ST_top.v
quit
