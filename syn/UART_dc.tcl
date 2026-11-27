# UART synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UART_top.sv
elaborate UART_top
link
read_sdc ../syn/UART.sdc
compile -map_effort medium
report_area  > rpt/UART_area.rpt
report_timing > rpt/UART_timing.rpt
write -format ddc -output netlist/UART_top.ddc
write -format verilog -output netlist/UART_top.v
quit
