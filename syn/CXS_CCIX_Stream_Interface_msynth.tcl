# CXS CCIX Stream Interface synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CXS_CCIX_Stream_Interface_top.sv}
elaborate CXS_CCIX_Stream_Interface_top
read_sdc ../syn/CXS_CCIX_Stream_Interface.sdc
synthesize
report_area > rpt/CXS_CCIX_Stream_Interface_area.rpt
report_timing > rpt/CXS_CCIX_Stream_Interface_timing.rpt
write_verilog netlist/CXS_CCIX_Stream_Interface_top.v
exit
