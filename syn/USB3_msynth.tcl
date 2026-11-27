# USB3 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB3_top.sv}
elaborate USB3_top
read_sdc ../syn/USB3.sdc
synthesize
report_area > rpt/USB3_area.rpt
report_timing > rpt/USB3_timing.rpt
write_verilog netlist/USB3_top.v
exit
