# PWM synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/PWM_top.sv}
elaborate PWM_top
read_sdc ../syn/PWM.sdc
synthesize
report_area > rpt/PWM_area.rpt
report_timing > rpt/PWM_timing.rpt
write_verilog netlist/PWM_top.v
exit
