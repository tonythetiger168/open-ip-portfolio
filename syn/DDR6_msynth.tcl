# DDR6 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DDR6_top.sv}
elaborate DDR6_top
read_sdc ../syn/DDR6.sdc
synthesize
report_area > rpt/DDR6_area.rpt
report_timing > rpt/DDR6_timing.rpt
write_verilog netlist/DDR6_top.v
exit
