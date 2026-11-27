# CSI-2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CSI_2_top.sv}
elaborate CSI_2_top
read_sdc ../syn/CSI_2.sdc
synthesize
report_area > rpt/CSI_2_area.rpt
report_timing > rpt/CSI_2_timing.rpt
write_verilog netlist/CSI_2_top.v
exit
