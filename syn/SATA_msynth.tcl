# SATA synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SATA_top.sv}
elaborate SATA_top
read_sdc ../syn/SATA.sdc
synthesize
report_area > rpt/SATA_area.rpt
report_timing > rpt/SATA_timing.rpt
write_verilog netlist/SATA_top.v
exit
