# I3C synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/I3C_top.sv}
elaborate I3C_top
read_sdc ../syn/I3C.sdc
synthesize
report_area > rpt/I3C_area.rpt
report_timing > rpt/I3C_timing.rpt
write_verilog netlist/I3C_top.v
exit
