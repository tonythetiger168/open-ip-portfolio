# D-PHY synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/D_PHY_top.sv}
elaborate D_PHY_top
read_sdc ../syn/D_PHY.sdc
synthesize
report_area > rpt/D_PHY_area.rpt
report_timing > rpt/D_PHY_timing.rpt
write_verilog netlist/D_PHY_top.v
exit
