# DDR4 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DDR4_top.sv}
elaborate DDR4_top
read_sdc ../syn/DDR4.sdc
synthesize
report_area > rpt/DDR4_area.rpt
report_timing > rpt/DDR4_timing.rpt
write_verilog netlist/DDR4_top.v
exit
