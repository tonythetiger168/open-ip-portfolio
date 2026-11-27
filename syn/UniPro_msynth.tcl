# UniPro synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UniPro_top.sv}
elaborate UniPro_top
read_sdc ../syn/UniPro.sdc
synthesize
report_area > rpt/UniPro_area.rpt
report_timing > rpt/UniPro_timing.rpt
write_verilog netlist/UniPro_top.v
exit
