# Crypto / Security Engine synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Crypto___Security_Engine_top.sv}
elaborate Crypto___Security_Engine_top
read_sdc ../syn/Crypto___Security_Engine.sdc
synthesize
report_area > rpt/Crypto___Security_Engine_area.rpt
report_timing > rpt/Crypto___Security_Engine_timing.rpt
write_verilog netlist/Crypto___Security_Engine_top.v
exit
