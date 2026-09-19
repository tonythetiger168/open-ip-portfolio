# MIPI DPI (Display Pixel Interface) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_DPI__Display_Pixel_Interface__top.sv
elaborate MIPI_DPI__Display_Pixel_Interface__top
link
read_sdc ../syn/MIPI_DPI__Display_Pixel_Interface_.sdc
compile -map_effort medium
report_area  > rpt/MIPI_DPI__Display_Pixel_Interface__area.rpt
report_timing > rpt/MIPI_DPI__Display_Pixel_Interface__timing.rpt
write -format ddc -output netlist/MIPI_DPI__Display_Pixel_Interface__top.ddc
write -format verilog -output netlist/MIPI_DPI__Display_Pixel_Interface__top.v
quit
