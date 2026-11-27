# CHI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/CHI_top.sv}
elaborate CHI_top
read_sdc ../syn/CHI.sdc
synthesize
report_area > rpt/CHI_area.rpt
report_timing > rpt/CHI_timing.rpt
write_verilog netlist/CHI_top.v
exit
