# HBM synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HBM_top.sv}
elaborate HBM_top
read_sdc ../syn/HBM.sdc
synthesize
report_area > rpt/HBM_area.rpt
report_timing > rpt/HBM_timing.rpt
write_verilog netlist/HBM_top.v
exit
