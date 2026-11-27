# USB2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB2_top.sv}
elaborate USB2_top
read_sdc ../syn/USB2.sdc
synthesize
report_area > rpt/USB2_area.rpt
report_timing > rpt/USB2_timing.rpt
write_verilog netlist/USB2_top.v
exit
