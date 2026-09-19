# AVSBus (Adaptive Voltage Scaling) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv
elaborate AVSBus__Adaptive_Voltage_Scaling__top
link
read_sdc ../syn/AVSBus__Adaptive_Voltage_Scaling_.sdc
compile -map_effort medium
report_area  > rpt/AVSBus__Adaptive_Voltage_Scaling__area.rpt
report_timing > rpt/AVSBus__Adaptive_Voltage_Scaling__timing.rpt
write -format ddc -output netlist/AVSBus__Adaptive_Voltage_Scaling__top.ddc
write -format verilog -output netlist/AVSBus__Adaptive_Voltage_Scaling__top.v
quit
