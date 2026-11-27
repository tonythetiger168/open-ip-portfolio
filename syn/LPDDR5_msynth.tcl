# LPDDR5 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/LPDDR5_top.sv}
elaborate LPDDR5_top
read_sdc ../syn/LPDDR5.sdc
synthesize
report_area > rpt/LPDDR5_area.rpt
report_timing > rpt/LPDDR5_timing.rpt
write_verilog netlist/LPDDR5_top.v
exit
