# 1-Wire synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/_1_Wire_top.sv}
elaborate _1_Wire_top
read_sdc ../syn/_1_Wire.sdc
synthesize
report_area > rpt/_1_Wire_area.rpt
report_timing > rpt/_1_Wire_timing.rpt
write_verilog netlist/_1_Wire_top.v
exit
