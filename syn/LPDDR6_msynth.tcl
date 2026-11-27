# LPDDR6 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LPDDR6_top.sv}
elaborate LPDDR6_top
read_sdc ../syn/LPDDR6.sdc
synthesize
report_area > rpt/LPDDR6_area.rpt
report_timing > rpt/LPDDR6_timing.rpt
write_verilog netlist/LPDDR6_top.v
exit
