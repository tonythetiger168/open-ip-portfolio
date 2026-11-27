# JESD204C synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/JESD204C_top.sv}
elaborate JESD204C_top
read_sdc ../syn/JESD204C.sdc
synthesize
report_area > rpt/JESD204C_area.rpt
report_timing > rpt/JESD204C_timing.rpt
write_verilog netlist/JESD204C_top.v
exit
