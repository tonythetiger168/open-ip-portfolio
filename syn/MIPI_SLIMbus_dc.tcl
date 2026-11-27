# MIPI SLIMbus synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_SLIMbus_top.sv
elaborate MIPI_SLIMbus_top
link
read_sdc ../syn/MIPI_SLIMbus.sdc
compile -map_effort medium
report_area  > rpt/MIPI_SLIMbus_area.rpt
report_timing > rpt/MIPI_SLIMbus_timing.rpt
write -format ddc -output netlist/MIPI_SLIMbus_top.ddc
write -format verilog -output netlist/MIPI_SLIMbus_top.v
quit
