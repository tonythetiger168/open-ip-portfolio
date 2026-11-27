# UEC synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UEC_top.sv}
elaborate UEC_top
read_sdc ../syn/UEC.sdc
synthesize
report_area > rpt/UEC_area.rpt
report_timing > rpt/UEC_timing.rpt
write_verilog netlist/UEC_top.v
exit
