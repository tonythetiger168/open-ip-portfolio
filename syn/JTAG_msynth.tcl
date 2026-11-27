# JTAG synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/JTAG_top.sv}
elaborate JTAG_top
read_sdc ../syn/JTAG.sdc
synthesize
report_area > rpt/JTAG_area.rpt
report_timing > rpt/JTAG_timing.rpt
write_verilog netlist/JTAG_top.v
exit
