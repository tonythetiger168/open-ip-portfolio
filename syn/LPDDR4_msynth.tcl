# LPDDR4 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LPDDR4_top.sv}
elaborate LPDDR4_top
read_sdc ../syn/LPDDR4.sdc
synthesize
report_area > rpt/LPDDR4_area.rpt
report_timing > rpt/LPDDR4_timing.rpt
write_verilog netlist/LPDDR4_top.v
exit
