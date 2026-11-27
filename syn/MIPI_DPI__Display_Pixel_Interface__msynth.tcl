# MIPI DPI (Display Pixel Interface) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_DPI__Display_Pixel_Interface__top.sv}
elaborate MIPI_DPI__Display_Pixel_Interface__top
read_sdc ../syn/MIPI_DPI__Display_Pixel_Interface_.sdc
synthesize
report_area > rpt/MIPI_DPI__Display_Pixel_Interface__area.rpt
report_timing > rpt/MIPI_DPI__Display_Pixel_Interface__timing.rpt
write_verilog netlist/MIPI_DPI__Display_Pixel_Interface__top.v
exit
