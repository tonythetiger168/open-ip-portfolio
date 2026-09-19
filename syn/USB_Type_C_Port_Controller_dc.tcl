# USB Type-C Port Controller synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB_Type_C_Port_Controller_top.sv
elaborate USB_Type_C_Port_Controller_top
link
read_sdc ../syn/USB_Type_C_Port_Controller.sdc
compile -map_effort medium
report_area  > rpt/USB_Type_C_Port_Controller_area.rpt
report_timing > rpt/USB_Type_C_Port_Controller_timing.rpt
write -format ddc -output netlist/USB_Type_C_Port_Controller_top.ddc
write -format verilog -output netlist/USB_Type_C_Port_Controller_top.v
quit
