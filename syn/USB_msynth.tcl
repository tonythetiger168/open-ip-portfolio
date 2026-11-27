# USB synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB_top.sv}
elaborate USB_top
read_sdc ../syn/USB.sdc
synthesize
report_area > rpt/USB_area.rpt
report_timing > rpt/USB_timing.rpt
write_verilog netlist/USB_top.v
exit
