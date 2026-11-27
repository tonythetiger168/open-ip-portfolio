# ARM Q-Channel Low Power Interface synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/ARM_Q_Channel_Low_Power_Interface_top.sv}
elaborate ARM_Q_Channel_Low_Power_Interface_top
read_sdc ../syn/ARM_Q_Channel_Low_Power_Interface.sdc
synthesize
report_area > rpt/ARM_Q_Channel_Low_Power_Interface_area.rpt
report_timing > rpt/ARM_Q_Channel_Low_Power_Interface_timing.rpt
write_verilog netlist/ARM_Q_Channel_Low_Power_Interface_top.v
exit
