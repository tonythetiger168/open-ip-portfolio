# OCP synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/OCP_top.sv}
elaborate OCP_top
read_sdc ../syn/OCP.sdc
synthesize
report_area > rpt/OCP_area.rpt
report_timing > rpt/OCP_timing.rpt
write_verilog netlist/OCP_top.v
exit
