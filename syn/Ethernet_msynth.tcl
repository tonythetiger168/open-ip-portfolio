# Ethernet synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Ethernet_top.sv}
elaborate Ethernet_top
read_sdc ../syn/Ethernet.sdc
synthesize
report_area > rpt/Ethernet_area.rpt
report_timing > rpt/Ethernet_timing.rpt
write_verilog netlist/Ethernet_top.v
exit
