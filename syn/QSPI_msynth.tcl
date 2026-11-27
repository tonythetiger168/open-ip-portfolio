# QSPI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/QSPI_top.sv}
elaborate QSPI_top
read_sdc ../syn/QSPI.sdc
synthesize
report_area > rpt/QSPI_area.rpt
report_timing > rpt/QSPI_timing.rpt
write_verilog netlist/QSPI_top.v
exit
