# SAS synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SAS_top.sv ../rtl/SATA_top.sv}
elaborate SAS_top
read_sdc ../syn/SAS.sdc
synthesize
report_area > rpt/SAS_area.rpt
report_timing > rpt/SAS_timing.rpt
write_verilog netlist/SAS_top.v
exit
