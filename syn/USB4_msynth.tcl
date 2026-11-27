# USB4 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB4_top.sv}
elaborate USB4_top
read_sdc ../syn/USB4.sdc
synthesize
report_area > rpt/USB4_area.rpt
report_timing > rpt/USB4_timing.rpt
write_verilog netlist/USB4_top.v
exit
