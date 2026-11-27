# ACE synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ACE_top.sv}
elaborate ACE_top
read_sdc ../syn/ACE.sdc
synthesize
report_area > rpt/ACE_area.rpt
report_timing > rpt/ACE_timing.rpt
write_verilog netlist/ACE_top.v
exit
