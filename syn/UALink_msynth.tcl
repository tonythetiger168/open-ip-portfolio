# UALink synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UALink_top.sv}
elaborate UALink_top
read_sdc ../syn/UALink.sdc
synthesize
report_area > rpt/UALink_area.rpt
report_timing > rpt/UALink_timing.rpt
write_verilog netlist/UALink_top.v
exit
