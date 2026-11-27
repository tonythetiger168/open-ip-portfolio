# GPIO synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/GPIO_top.sv}
elaborate GPIO_top
read_sdc ../syn/GPIO.sdc
synthesize
report_area > rpt/GPIO_area.rpt
report_timing > rpt/GPIO_timing.rpt
write_verilog netlist/GPIO_top.v
exit
