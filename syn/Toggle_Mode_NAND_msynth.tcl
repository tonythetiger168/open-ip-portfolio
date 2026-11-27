# Toggle Mode NAND synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/Toggle_Mode_NAND_top.sv}
elaborate Toggle_Mode_NAND_top
read_sdc ../syn/Toggle_Mode_NAND.sdc
synthesize
report_area > rpt/Toggle_Mode_NAND_area.rpt
report_timing > rpt/Toggle_Mode_NAND_timing.rpt
write_verilog netlist/Toggle_Mode_NAND_top.v
exit
