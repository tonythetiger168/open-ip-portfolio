# I2C synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/I2C_top.sv}
elaborate I2C_top
read_sdc ../syn/I2C.sdc
synthesize
report_area > rpt/I2C_area.rpt
report_timing > rpt/I2C_timing.rpt
write_verilog netlist/I2C_top.v
exit
