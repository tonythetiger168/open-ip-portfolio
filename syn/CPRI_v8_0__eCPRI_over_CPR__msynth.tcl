# CPRI v8.0 (eCPRI over CPR) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CPRI_v8_0__eCPRI_over_CPR__top.sv}
elaborate CPRI_v8_0__eCPRI_over_CPR__top
read_sdc ../syn/CPRI_v8_0__eCPRI_over_CPR_.sdc
synthesize
report_area > rpt/CPRI_v8_0__eCPRI_over_CPR__area.rpt
report_timing > rpt/CPRI_v8_0__eCPRI_over_CPR__timing.rpt
write_verilog netlist/CPRI_v8_0__eCPRI_over_CPR__top.v
exit
