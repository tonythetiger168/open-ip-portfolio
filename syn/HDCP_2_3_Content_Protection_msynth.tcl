# HDCP 2.3 Content Protection synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HDCP_2_3_Content_Protection_top.sv}
elaborate HDCP_2_3_Content_Protection_top
read_sdc ../syn/HDCP_2_3_Content_Protection.sdc
synthesize
report_area > rpt/HDCP_2_3_Content_Protection_area.rpt
report_timing > rpt/HDCP_2_3_Content_Protection_timing.rpt
write_verilog netlist/HDCP_2_3_Content_Protection_top.v
exit
