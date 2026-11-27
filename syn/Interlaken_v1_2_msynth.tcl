# Interlaken v1.2 synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Interlaken_v1_2_top.sv}
elaborate Interlaken_v1_2_top
read_sdc ../syn/Interlaken_v1_2.sdc
synthesize
report_area > rpt/Interlaken_v1_2_area.rpt
report_timing > rpt/Interlaken_v1_2_timing.rpt
write_verilog netlist/Interlaken_v1_2_top.v
exit
