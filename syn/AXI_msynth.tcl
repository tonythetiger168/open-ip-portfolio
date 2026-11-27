# AXI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/AXI_top.sv}
elaborate AXI_top
read_sdc ../syn/AXI.sdc
synthesize
report_area > rpt/AXI_area.rpt
report_timing > rpt/AXI_timing.rpt
write_verilog netlist/AXI_top.v
exit
