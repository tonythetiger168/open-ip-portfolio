# UniPro-Mem synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UniPro_Mem_top.sv}
elaborate UniPro_Mem_top
read_sdc ../syn/UniPro_Mem.sdc
synthesize
report_area > rpt/UniPro_Mem_area.rpt
report_timing > rpt/UniPro_Mem_timing.rpt
write_verilog netlist/UniPro_Mem_top.v
exit
