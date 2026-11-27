# DisplayPort2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DisplayPort2_top.sv}
elaborate DisplayPort2_top
read_sdc ../syn/DisplayPort2.sdc
synthesize
report_area > rpt/DisplayPort2_area.rpt
report_timing > rpt/DisplayPort2_timing.rpt
write_verilog netlist/DisplayPort2_top.v
exit
