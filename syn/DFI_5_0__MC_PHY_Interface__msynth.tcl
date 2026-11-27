# DFI 5.0 (MC-PHY Interface) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DFI_5_0__MC_PHY_Interface__top.sv}
elaborate DFI_5_0__MC_PHY_Interface__top
read_sdc ../syn/DFI_5_0__MC_PHY_Interface_.sdc
synthesize
report_area > rpt/DFI_5_0__MC_PHY_Interface__area.rpt
report_timing > rpt/DFI_5_0__MC_PHY_Interface__timing.rpt
write_verilog netlist/DFI_5_0__MC_PHY_Interface__top.v
exit
