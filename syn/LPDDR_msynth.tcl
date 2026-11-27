# LPDDR synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LPDDR_top.sv}
elaborate LPDDR_top
read_sdc ../syn/LPDDR.sdc
synthesize
report_area > rpt/LPDDR_area.rpt
report_timing > rpt/LPDDR_timing.rpt
write_verilog netlist/LPDDR_top.v
exit
