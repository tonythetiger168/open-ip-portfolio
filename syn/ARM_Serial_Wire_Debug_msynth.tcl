# ARM Serial Wire Debug synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ARM_Serial_Wire_Debug_top.sv}
elaborate ARM_Serial_Wire_Debug_top
read_sdc ../syn/ARM_Serial_Wire_Debug.sdc
synthesize
report_area > rpt/ARM_Serial_Wire_Debug_area.rpt
report_timing > rpt/ARM_Serial_Wire_Debug_timing.rpt
write_verilog netlist/ARM_Serial_Wire_Debug_top.v
exit
