# CCIX Cache Coherent Interconnect synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CCIX_Cache_Coherent_Interconnect_top.sv}
elaborate CCIX_Cache_Coherent_Interconnect_top
read_sdc ../syn/CCIX_Cache_Coherent_Interconnect.sdc
synthesize
report_area > rpt/CCIX_Cache_Coherent_Interconnect_area.rpt
report_timing > rpt/CCIX_Cache_Coherent_Interconnect_timing.rpt
write_verilog netlist/CCIX_Cache_Coherent_Interconnect_top.v
exit
