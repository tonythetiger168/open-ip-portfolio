# SPI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SPI_top.sv}
elaborate SPI_top
read_sdc ../syn/SPI.sdc
synthesize
report_area > rpt/SPI_area.rpt
report_timing > rpt/SPI_timing.rpt
write_verilog netlist/SPI_top.v
exit
