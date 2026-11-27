# LPDDR5X synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LPDDR5X_top.sv}
elaborate LPDDR5X_top
read_sdc ../syn/LPDDR5X.sdc
synthesize
report_area > rpt/LPDDR5X_area.rpt
report_timing > rpt/LPDDR5X_timing.rpt
write_verilog netlist/LPDDR5X_top.v
exit
