# QSPI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/QSPI_top.sv
elaborate QSPI_top
link
read_sdc ../syn/QSPI.sdc
compile -map_effort medium
report_area  > rpt/QSPI_area.rpt
report_timing > rpt/QSPI_timing.rpt
write -format ddc -output netlist/QSPI_top.ddc
write -format verilog -output netlist/QSPI_top.v
quit
