# C-PHY synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/C_PHY_top.sv}
elaborate C_PHY_top
read_sdc ../syn/C_PHY.sdc
synthesize
report_area > rpt/C_PHY_area.rpt
report_timing > rpt/C_PHY_timing.rpt
write_verilog netlist/C_PHY_top.v
exit
