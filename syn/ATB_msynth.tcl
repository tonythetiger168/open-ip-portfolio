# ATB synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ATB_top.sv}
elaborate ATB_top
read_sdc ../syn/ATB.sdc
synthesize
report_area > rpt/ATB_area.rpt
report_timing > rpt/ATB_timing.rpt
write_verilog netlist/ATB_top.v
exit
