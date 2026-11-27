# APB synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/APB_top.sv}
elaborate APB_top
read_sdc ../syn/APB.sdc
synthesize
report_area > rpt/APB_area.rpt
report_timing > rpt/APB_timing.rpt
write_verilog netlist/APB_top.v
exit
