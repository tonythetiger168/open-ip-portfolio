# UFS synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UFS_top.sv ../rtl/SATA_top.sv}
elaborate UFS_top
read_sdc ../syn/UFS.sdc
synthesize
report_area > rpt/UFS_area.rpt
report_timing > rpt/UFS_timing.rpt
write_verilog netlist/UFS_top.v
exit
