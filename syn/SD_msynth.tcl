# SD synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SD_top.sv}
elaborate SD_top
read_sdc ../syn/SD.sdc
synthesize
report_area > rpt/SD_area.rpt
report_timing > rpt/SD_timing.rpt
write_verilog netlist/SD_top.v
exit
