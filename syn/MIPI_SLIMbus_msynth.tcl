# MIPI SLIMbus synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_SLIMbus_top.sv}
elaborate MIPI_SLIMbus_top
read_sdc ../syn/MIPI_SLIMbus.sdc
synthesize
report_area > rpt/MIPI_SLIMbus_area.rpt
report_timing > rpt/MIPI_SLIMbus_timing.rpt
write_verilog netlist/MIPI_SLIMbus_top.v
exit
