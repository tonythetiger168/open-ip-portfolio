# HSI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/HSI_top.sv}
elaborate HSI_top
read_sdc ../syn/HSI.sdc
synthesize
report_area > rpt/HSI_area.rpt
report_timing > rpt/HSI_timing.rpt
write_verilog netlist/HSI_top.v
exit
