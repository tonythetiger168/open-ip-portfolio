# XGMII synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/XGMII_top.sv}
elaborate XGMII_top
read_sdc ../syn/XGMII.sdc
synthesize
report_area > rpt/XGMII_area.rpt
report_timing > rpt/XGMII_timing.rpt
write_verilog netlist/XGMII_top.v
exit
