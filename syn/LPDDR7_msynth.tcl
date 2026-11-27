# LPDDR7 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LPDDR7_top.sv}
elaborate LPDDR7_top
read_sdc ../syn/LPDDR7.sdc
synthesize
report_area > rpt/LPDDR7_area.rpt
report_timing > rpt/LPDDR7_timing.rpt
write_verilog netlist/LPDDR7_top.v
exit
