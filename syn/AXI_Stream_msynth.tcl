# AXI-Stream synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/AXI_Stream_top.sv}
elaborate AXI_Stream_top
read_sdc ../syn/AXI_Stream.sdc
synthesize
report_area > rpt/AXI_Stream_area.rpt
report_timing > rpt/AXI_Stream_timing.rpt
write_verilog netlist/AXI_Stream_top.v
exit
