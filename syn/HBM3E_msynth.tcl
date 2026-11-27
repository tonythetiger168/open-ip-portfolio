# HBM3E synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HBM3E_top.sv}
elaborate HBM3E_top
read_sdc ../syn/HBM3E.sdc
synthesize
report_area > rpt/HBM3E_area.rpt
report_timing > rpt/HBM3E_timing.rpt
write_verilog netlist/HBM3E_top.v
exit
