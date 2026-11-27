# HBM3 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HBM3_top.sv}
elaborate HBM3_top
read_sdc ../syn/HBM3.sdc
synthesize
report_area > rpt/HBM3_area.rpt
report_timing > rpt/HBM3_timing.rpt
write_verilog netlist/HBM3_top.v
exit
