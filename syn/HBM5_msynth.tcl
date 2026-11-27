# HBM5 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HBM5_top.sv}
elaborate HBM5_top
read_sdc ../syn/HBM5.sdc
synthesize
report_area > rpt/HBM5_area.rpt
report_timing > rpt/HBM5_timing.rpt
write_verilog netlist/HBM5_top.v
exit
