# HDMI 2.1 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HDMI_2_1_top.sv}
elaborate HDMI_2_1_top
read_sdc ../syn/HDMI_2_1.sdc
synthesize
report_area > rpt/HDMI_2_1_area.rpt
report_timing > rpt/HDMI_2_1_timing.rpt
write_verilog netlist/HDMI_2_1_top.v
exit
