# DigRF synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DigRF_top.sv}
elaborate DigRF_top
read_sdc ../syn/DigRF.sdc
synthesize
report_area > rpt/DigRF_area.rpt
report_timing > rpt/DigRF_timing.rpt
write_verilog netlist/DigRF_top.v
exit
