# Avalon-MM synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Avalon_MM_top.sv}
elaborate Avalon_MM_top
read_sdc ../syn/Avalon_MM.sdc
synthesize
report_area > rpt/Avalon_MM_area.rpt
report_timing > rpt/Avalon_MM_timing.rpt
write_verilog netlist/Avalon_MM_top.v
exit
