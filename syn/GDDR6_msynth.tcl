# GDDR6 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/GDDR6_top.sv}
elaborate GDDR6_top
read_sdc ../syn/GDDR6.sdc
synthesize
report_area > rpt/GDDR6_area.rpt
report_timing > rpt/GDDR6_timing.rpt
write_verilog netlist/GDDR6_top.v
exit
