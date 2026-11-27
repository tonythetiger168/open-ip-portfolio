# HBM2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HBM2_top.sv}
elaborate HBM2_top
read_sdc ../syn/HBM2.sdc
synthesize
report_area > rpt/HBM2_area.rpt
report_timing > rpt/HBM2_timing.rpt
write_verilog netlist/HBM2_top.v
exit
