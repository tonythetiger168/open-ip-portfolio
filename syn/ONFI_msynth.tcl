# ONFI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ONFI_top.sv}
elaborate ONFI_top
read_sdc ../syn/ONFI.sdc
synthesize
report_area > rpt/ONFI_area.rpt
report_timing > rpt/ONFI_timing.rpt
write_verilog netlist/ONFI_top.v
exit
