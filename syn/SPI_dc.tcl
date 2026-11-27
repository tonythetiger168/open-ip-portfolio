# SPI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SPI_top.sv
elaborate SPI_top
link
read_sdc ../syn/SPI.sdc
compile -map_effort medium
report_area  > rpt/SPI_area.rpt
report_timing > rpt/SPI_timing.rpt
write -format ddc -output netlist/SPI_top.ddc
write -format verilog -output netlist/SPI_top.v
quit
