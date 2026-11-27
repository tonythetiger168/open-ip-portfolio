# MIPI RFFE synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_RFFE_top.sv}
elaborate MIPI_RFFE_top
read_sdc ../syn/MIPI_RFFE.sdc
synthesize
report_area > rpt/MIPI_RFFE_area.rpt
report_timing > rpt/MIPI_RFFE_timing.rpt
write_verilog netlist/MIPI_RFFE_top.v
exit
