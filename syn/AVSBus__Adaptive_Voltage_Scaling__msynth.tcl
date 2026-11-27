# AVSBus (Adaptive Voltage Scaling) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv}
elaborate AVSBus__Adaptive_Voltage_Scaling__top
read_sdc ../syn/AVSBus__Adaptive_Voltage_Scaling_.sdc
synthesize
report_area > rpt/AVSBus__Adaptive_Voltage_Scaling__area.rpt
report_timing > rpt/AVSBus__Adaptive_Voltage_Scaling__timing.rpt
write_verilog netlist/AVSBus__Adaptive_Voltage_Scaling__top.v
exit
