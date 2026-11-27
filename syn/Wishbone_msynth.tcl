# Wishbone synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Wishbone_top.sv}
elaborate Wishbone_top
read_sdc ../syn/Wishbone.sdc
synthesize
report_area > rpt/Wishbone_area.rpt
report_timing > rpt/Wishbone_timing.rpt
write_verilog netlist/Wishbone_top.v
exit
