# eCPRI over Ethernet synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/eCPRI_over_Ethernet_top.sv}
elaborate eCPRI_over_Ethernet_top
read_sdc ../syn/eCPRI_over_Ethernet.sdc
synthesize
report_area > rpt/eCPRI_over_Ethernet_area.rpt
report_timing > rpt/eCPRI_over_Ethernet_timing.rpt
write_verilog netlist/eCPRI_over_Ethernet_top.v
exit
