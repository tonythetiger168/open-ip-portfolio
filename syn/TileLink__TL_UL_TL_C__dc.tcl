# TileLink (TL-UL/TL-C) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/TileLink__TL_UL_TL_C__top.sv
elaborate TileLink__TL_UL_TL_C__top
link
read_sdc ../syn/TileLink__TL_UL_TL_C_.sdc
compile -map_effort medium
report_area  > rpt/TileLink__TL_UL_TL_C__area.rpt
report_timing > rpt/TileLink__TL_UL_TL_C__timing.rpt
write -format ddc -output netlist/TileLink__TL_UL_TL_C__top.ddc
write -format verilog -output netlist/TileLink__TL_UL_TL_C__top.v
quit
