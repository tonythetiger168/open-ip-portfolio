# AXI4 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/AXI4_top.sv}
elaborate AXI4_top
read_sdc ../syn/AXI4.sdc
synthesize
report_area > rpt/AXI4_area.rpt
report_timing > rpt/AXI4_timing.rpt
write_verilog netlist/AXI4_top.v
exit
