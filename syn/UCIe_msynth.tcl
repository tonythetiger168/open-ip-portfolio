# UCIe synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UCIe_top.sv}
elaborate UCIe_top
read_sdc ../syn/UCIe.sdc
synthesize
report_area > rpt/UCIe_area.rpt
report_timing > rpt/UCIe_timing.rpt
write_verilog netlist/UCIe_top.v
exit
