# I2S Audio synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/I2S_Audio_top.sv}
elaborate I2S_Audio_top
read_sdc ../syn/I2S_Audio.sdc
synthesize
report_area > rpt/I2S_Audio_area.rpt
report_timing > rpt/I2S_Audio_timing.rpt
write_verilog netlist/I2S_Audio_top.v
exit
