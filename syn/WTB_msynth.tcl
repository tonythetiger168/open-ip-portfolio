# WTB synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/WTB_top.sv}
elaborate WTB_top
read_sdc ../syn/WTB.sdc
synthesize
report_area > rpt/WTB_area.rpt
report_timing > rpt/WTB_timing.rpt
write_verilog netlist/WTB_top.v
exit
