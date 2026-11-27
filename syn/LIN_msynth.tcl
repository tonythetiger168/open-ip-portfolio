# LIN synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LIN_top.sv}
elaborate LIN_top
read_sdc ../syn/LIN.sdc
synthesize
report_area > rpt/LIN_area.rpt
report_timing > rpt/LIN_timing.rpt
write_verilog netlist/LIN_top.v
exit
