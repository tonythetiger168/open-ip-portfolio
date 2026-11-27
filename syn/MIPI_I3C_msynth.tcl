# MIPI I3C synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_I3C_top.sv}
elaborate MIPI_I3C_top
read_sdc ../syn/MIPI_I3C.sdc
synthesize
report_area > rpt/MIPI_I3C_area.rpt
report_timing > rpt/MIPI_I3C_timing.rpt
write_verilog netlist/MIPI_I3C_top.v
exit
