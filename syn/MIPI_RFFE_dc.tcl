# MIPI RFFE synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_RFFE_top.sv
elaborate MIPI_RFFE_top
link
read_sdc ../syn/MIPI_RFFE.sdc
compile -map_effort medium
report_area  > rpt/MIPI_RFFE_area.rpt
report_timing > rpt/MIPI_RFFE_timing.rpt
write -format ddc -output netlist/MIPI_RFFE_top.ddc
write -format verilog -output netlist/MIPI_RFFE_top.v
quit
