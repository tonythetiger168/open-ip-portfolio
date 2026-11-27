# M-PHY synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/M_PHY_top.sv}
elaborate M_PHY_top
read_sdc ../syn/M_PHY.sdc
synthesize
report_area > rpt/M_PHY_area.rpt
report_timing > rpt/M_PHY_timing.rpt
write_verilog netlist/M_PHY_top.v
exit
