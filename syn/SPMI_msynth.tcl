# SPMI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SPMI_top.sv}
elaborate SPMI_top
read_sdc ../syn/SPMI.sdc
synthesize
report_area > rpt/SPMI_area.rpt
report_timing > rpt/SPMI_timing.rpt
write_verilog netlist/SPMI_top.v
exit
