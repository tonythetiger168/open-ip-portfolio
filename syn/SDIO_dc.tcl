# SDIO synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SDIO_top.sv
elaborate SDIO_top
link
read_sdc ../syn/SDIO.sdc
compile -map_effort medium
report_area  > rpt/SDIO_area.rpt
report_timing > rpt/SDIO_timing.rpt
write -format ddc -output netlist/SDIO_top.ddc
write -format verilog -output netlist/SDIO_top.v
quit
