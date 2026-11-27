# USB2.0 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB2_0_top.sv}
elaborate USB2_0_top
read_sdc ../syn/USB2_0.sdc
synthesize
report_area > rpt/USB2_0_area.rpt
report_timing > rpt/USB2_0_timing.rpt
write_verilog netlist/USB2_0_top.v
exit
