# Sensor_Hub synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Sensor_Hub_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Sensor_Hub_top
link
read_sdc ../syn/Sensor_Hub.sdc
compile -map_effort medium
report_area  > rpt/Sensor_Hub_area.rpt
report_timing > rpt/Sensor_Hub_timing.rpt
write -format ddc -output netlist/Sensor_Hub_top.ddc
write -format verilog -output netlist/Sensor_Hub_top.v
quit
