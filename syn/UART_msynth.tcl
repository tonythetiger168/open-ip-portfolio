# UART synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/UART_top.sv}
elaborate UART_top
read_sdc ../syn/UART.sdc
synthesize
report_area > rpt/UART_area.rpt
report_timing > rpt/UART_timing.rpt
write_verilog netlist/UART_top.v
exit
