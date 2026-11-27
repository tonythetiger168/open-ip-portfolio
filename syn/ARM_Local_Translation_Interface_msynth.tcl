# ARM Local Translation Interface synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ARM_Local_Translation_Interface_top.sv}
elaborate ARM_Local_Translation_Interface_top
read_sdc ../syn/ARM_Local_Translation_Interface.sdc
synthesize
report_area > rpt/ARM_Local_Translation_Interface_area.rpt
report_timing > rpt/ARM_Local_Translation_Interface_timing.rpt
write_verilog netlist/ARM_Local_Translation_Interface_top.v
exit
