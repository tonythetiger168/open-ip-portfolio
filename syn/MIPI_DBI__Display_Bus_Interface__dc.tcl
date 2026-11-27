# MIPI DBI (Display Bus Interface) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_DBI__Display_Bus_Interface__top.sv
elaborate MIPI_DBI__Display_Bus_Interface__top
link
read_sdc ../syn/MIPI_DBI__Display_Bus_Interface_.sdc
compile -map_effort medium
report_area  > rpt/MIPI_DBI__Display_Bus_Interface__area.rpt
report_timing > rpt/MIPI_DBI__Display_Bus_Interface__timing.rpt
write -format ddc -output netlist/MIPI_DBI__Display_Bus_Interface__top.ddc
write -format verilog -output netlist/MIPI_DBI__Display_Bus_Interface__top.v
quit
