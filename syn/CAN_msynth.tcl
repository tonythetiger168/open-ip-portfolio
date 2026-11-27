# CAN synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CAN_top.sv}
elaborate CAN_top
read_sdc ../syn/CAN.sdc
synthesize
report_area > rpt/CAN_area.rpt
report_timing > rpt/CAN_timing.rpt
write_verilog netlist/CAN_top.v
exit
