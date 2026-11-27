# USB3.2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB3_2_top.sv}
elaborate USB3_2_top
read_sdc ../syn/USB3_2.sdc
synthesize
report_area > rpt/USB3_2_area.rpt
report_timing > rpt/USB3_2_timing.rpt
write_verilog netlist/USB3_2_top.v
exit
