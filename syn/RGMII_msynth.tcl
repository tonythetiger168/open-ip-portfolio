# RGMII synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/RGMII_top.sv}
elaborate RGMII_top
read_sdc ../syn/RGMII.sdc
synthesize
report_area > rpt/RGMII_area.rpt
report_timing > rpt/RGMII_timing.rpt
write_verilog netlist/RGMII_top.v
exit
