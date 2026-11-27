# eUSB2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/eUSB2_top.sv}
elaborate eUSB2_top
read_sdc ../syn/eUSB2.sdc
synthesize
report_area > rpt/eUSB2_area.rpt
report_timing > rpt/eUSB2_timing.rpt
write_verilog netlist/eUSB2_top.v
exit
