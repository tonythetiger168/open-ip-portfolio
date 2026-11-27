# Avalon-ST synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Avalon_ST_top.sv}
elaborate Avalon_ST_top
read_sdc ../syn/Avalon_ST.sdc
synthesize
report_area > rpt/Avalon_ST_area.rpt
report_timing > rpt/Avalon_ST_timing.rpt
write_verilog netlist/Avalon_ST_top.v
exit
