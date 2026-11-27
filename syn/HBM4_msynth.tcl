# HBM4 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HBM4_top.sv}
elaborate HBM4_top
read_sdc ../syn/HBM4.sdc
synthesize
report_area > rpt/HBM4_area.rpt
report_timing > rpt/HBM4_timing.rpt
write_verilog netlist/HBM4_top.v
exit
