# ACE-Lite synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ACE_Lite_top.sv}
elaborate ACE_Lite_top
read_sdc ../syn/ACE_Lite.sdc
synthesize
report_area > rpt/ACE_Lite_area.rpt
report_timing > rpt/ACE_Lite_timing.rpt
write_verilog netlist/ACE_Lite_top.v
exit
