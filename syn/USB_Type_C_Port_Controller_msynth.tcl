# USB Type-C Port Controller synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/USB_Type_C_Port_Controller_top.sv}
elaborate USB_Type_C_Port_Controller_top
read_sdc ../syn/USB_Type_C_Port_Controller.sdc
synthesize
report_area > rpt/USB_Type_C_Port_Controller_area.rpt
report_timing > rpt/USB_Type_C_Port_Controller_timing.rpt
write_verilog netlist/USB_Type_C_Port_Controller_top.v
exit
