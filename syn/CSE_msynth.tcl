# CSE synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CSE_top.sv}
elaborate CSE_top
read_sdc ../syn/CSE.sdc
synthesize
report_area > rpt/CSE_area.rpt
report_timing > rpt/CSE_timing.rpt
write_verilog netlist/CSE_top.v
exit
