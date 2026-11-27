# USB-PD synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB_PD_top.sv}
elaborate USB_PD_top
read_sdc ../syn/USB_PD.sdc
synthesize
report_area > rpt/USB_PD_area.rpt
report_timing > rpt/USB_PD_timing.rpt
write_verilog netlist/USB_PD_top.v
exit
