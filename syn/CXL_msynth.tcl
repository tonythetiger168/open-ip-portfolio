# CXL synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CXL_top.sv}
elaborate CXL_top
read_sdc ../syn/CXL.sdc
synthesize
report_area > rpt/CXL_area.rpt
report_timing > rpt/CXL_timing.rpt
write_verilog netlist/CXL_top.v
exit
