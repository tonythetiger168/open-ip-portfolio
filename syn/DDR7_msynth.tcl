# DDR7 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DDR7_top.sv}
elaborate DDR7_top
read_sdc ../syn/DDR7.sdc
synthesize
report_area > rpt/DDR7_area.rpt
report_timing > rpt/DDR7_timing.rpt
write_verilog netlist/DDR7_top.v
exit
