# DDR5 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DDR5_top.sv}
elaborate DDR5_top
read_sdc ../syn/DDR5.sdc
synthesize
report_area > rpt/DDR5_area.rpt
report_timing > rpt/DDR5_timing.rpt
write_verilog netlist/DDR5_top.v
exit
