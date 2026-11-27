# GDDR7 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/GDDR7_top.sv}
elaborate GDDR7_top
read_sdc ../syn/GDDR7.sdc
synthesize
report_area > rpt/GDDR7_area.rpt
report_timing > rpt/GDDR7_timing.rpt
write_verilog netlist/GDDR7_top.v
exit
