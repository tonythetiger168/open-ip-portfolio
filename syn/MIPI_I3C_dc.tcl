# MIPI I3C synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_I3C_top.sv
elaborate MIPI_I3C_top
link
read_sdc ../syn/MIPI_I3C.sdc
compile -map_effort medium
report_area  > rpt/MIPI_I3C_area.rpt
report_timing > rpt/MIPI_I3C_timing.rpt
write -format ddc -output netlist/MIPI_I3C_top.ddc
write -format verilog -output netlist/MIPI_I3C_top.v
quit
