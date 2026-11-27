# I2S synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/I2S_top.sv}
elaborate I2S_top
read_sdc ../syn/I2S.sdc
synthesize
report_area > rpt/I2S_area.rpt
report_timing > rpt/I2S_timing.rpt
write_verilog netlist/I2S_top.v
exit
