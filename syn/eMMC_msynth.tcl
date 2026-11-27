# eMMC synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/eMMC_top.sv}
elaborate eMMC_top
read_sdc ../syn/eMMC.sdc
synthesize
report_area > rpt/eMMC_area.rpt
report_timing > rpt/eMMC_timing.rpt
write_verilog netlist/eMMC_top.v
exit
