# TileLink (TL-UL/TL-C) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/TileLink__TL_UL_TL_C__top.sv}
elaborate TileLink__TL_UL_TL_C__top
read_sdc ../syn/TileLink__TL_UL_TL_C_.sdc
synthesize
report_area > rpt/TileLink__TL_UL_TL_C__area.rpt
report_timing > rpt/TileLink__TL_UL_TL_C__timing.rpt
write_verilog netlist/TileLink__TL_UL_TL_C__top.v
exit
