# AXI4-Lite synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/AXI4_Lite_top.sv}
elaborate AXI4_Lite_top
read_sdc ../syn/AXI4_Lite.sdc
synthesize
report_area > rpt/AXI4_Lite_area.rpt
report_timing > rpt/AXI4_Lite_timing.rpt
write_verilog netlist/AXI4_Lite_top.v
exit
