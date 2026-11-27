# Bluetooth5 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Bluetooth5_top.sv}
elaborate Bluetooth5_top
read_sdc ../syn/Bluetooth5.sdc
synthesize
report_area > rpt/Bluetooth5_area.rpt
report_timing > rpt/Bluetooth5_timing.rpt
write_verilog netlist/Bluetooth5_top.v
exit
