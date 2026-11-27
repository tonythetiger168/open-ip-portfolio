# DSI synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/DSI_top.sv}
elaborate DSI_top
read_sdc ../syn/DSI.sdc
synthesize
report_area > rpt/DSI_area.rpt
report_timing > rpt/DSI_timing.rpt
write_verilog netlist/DSI_top.v
exit
