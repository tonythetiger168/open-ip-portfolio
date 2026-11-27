# GMII synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/GMII_top.sv}
elaborate GMII_top
read_sdc ../syn/GMII.sdc
synthesize
report_area > rpt/GMII_area.rpt
report_timing > rpt/GMII_timing.rpt
write_verilog netlist/GMII_top.v
exit
