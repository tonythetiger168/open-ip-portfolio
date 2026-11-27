# GDDR5 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/GDDR5_top.sv}
elaborate GDDR5_top
read_sdc ../syn/GDDR5.sdc
synthesize
report_area > rpt/GDDR5_area.rpt
report_timing > rpt/GDDR5_timing.rpt
write_verilog netlist/GDDR5_top.v
exit
