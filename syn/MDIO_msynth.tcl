# MDIO synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MDIO_top.sv}
elaborate MDIO_top
read_sdc ../syn/MDIO.sdc
synthesize
report_area > rpt/MDIO_area.rpt
report_timing > rpt/MDIO_timing.rpt
write_verilog netlist/MDIO_top.v
exit
