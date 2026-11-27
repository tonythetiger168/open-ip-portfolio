# SCM_SSD synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SCM_SSD_top.sv}
elaborate SCM_SSD_top
read_sdc ../syn/SCM_SSD.sdc
synthesize
report_area > rpt/SCM_SSD_area.rpt
report_timing > rpt/SCM_SSD_timing.rpt
write_verilog netlist/SCM_SSD_top.v
exit
