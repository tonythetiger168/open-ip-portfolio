# FlexRay synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/FlexRay_top.sv}
elaborate FlexRay_top
read_sdc ../syn/FlexRay.sdc
synthesize
report_area > rpt/FlexRay_area.rpt
report_timing > rpt/FlexRay_timing.rpt
write_verilog netlist/FlexRay_top.v
exit
