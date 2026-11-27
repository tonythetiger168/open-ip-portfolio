# Ethernet-AVB-TSN synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Ethernet_AVB_TSN_top.sv}
elaborate Ethernet_AVB_TSN_top
read_sdc ../syn/Ethernet_AVB_TSN.sdc
synthesize
report_area > rpt/Ethernet_AVB_TSN_area.rpt
report_timing > rpt/Ethernet_AVB_TSN_timing.rpt
write_verilog netlist/Ethernet_AVB_TSN_top.v
exit
