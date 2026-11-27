# DDR synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DDR_top.sv}
elaborate DDR_top
read_sdc ../syn/DDR.sdc
synthesize
report_area > rpt/DDR_area.rpt
report_timing > rpt/DDR_timing.rpt
write_verilog netlist/DDR_top.v
exit
