# RFFE synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/RFFE_top.sv}
elaborate RFFE_top
read_sdc ../syn/RFFE.sdc
synthesize
report_area > rpt/RFFE_area.rpt
report_timing > rpt/RFFE_timing.rpt
write_verilog netlist/RFFE_top.v
exit
