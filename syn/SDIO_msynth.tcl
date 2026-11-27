# SDIO synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SDIO_top.sv}
elaborate SDIO_top
read_sdc ../syn/SDIO.sdc
synthesize
report_area > rpt/SDIO_area.rpt
report_timing > rpt/SDIO_timing.rpt
write_verilog netlist/SDIO_top.v
exit
