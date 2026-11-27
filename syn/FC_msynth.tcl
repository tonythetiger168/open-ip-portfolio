# FC synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/FC_top.sv}
elaborate FC_top
read_sdc ../syn/FC.sdc
synthesize
report_area > rpt/FC_area.rpt
report_timing > rpt/FC_timing.rpt
write_verilog netlist/FC_top.v
exit
