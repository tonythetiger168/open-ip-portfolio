# AHB synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/AHB_top.sv}
elaborate AHB_top
read_sdc ../syn/AHB.sdc
synthesize
report_area > rpt/AHB_area.rpt
report_timing > rpt/AHB_timing.rpt
write_verilog netlist/AHB_top.v
exit
