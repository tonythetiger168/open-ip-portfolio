# MIPI DBI (Display Bus Interface) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_DBI__Display_Bus_Interface__top.sv}
elaborate MIPI_DBI__Display_Bus_Interface__top
read_sdc ../syn/MIPI_DBI__Display_Bus_Interface_.sdc
synthesize
report_area > rpt/MIPI_DBI__Display_Bus_Interface__area.rpt
report_timing > rpt/MIPI_DBI__Display_Bus_Interface__timing.rpt
write_verilog netlist/MIPI_DBI__Display_Bus_Interface__top.v
exit
