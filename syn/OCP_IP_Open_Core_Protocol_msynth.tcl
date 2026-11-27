# OCP-IP Open Core Protocol synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/OCP_IP_Open_Core_Protocol_top.sv}
elaborate OCP_IP_Open_Core_Protocol_top
read_sdc ../syn/OCP_IP_Open_Core_Protocol.sdc
synthesize
report_area > rpt/OCP_IP_Open_Core_Protocol_area.rpt
report_timing > rpt/OCP_IP_Open_Core_Protocol_timing.rpt
write_verilog netlist/OCP_IP_Open_Core_Protocol_top.v
exit
