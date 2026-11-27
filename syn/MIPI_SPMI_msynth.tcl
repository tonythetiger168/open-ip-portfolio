# MIPI SPMI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_SPMI_top.sv}
elaborate MIPI_SPMI_top
read_sdc ../syn/MIPI_SPMI.sdc
synthesize
report_area > rpt/MIPI_SPMI_area.rpt
report_timing > rpt/MIPI_SPMI_timing.rpt
write_verilog netlist/MIPI_SPMI_top.v
exit
