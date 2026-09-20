# MIPI SPMI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_SPMI_top.sv
elaborate MIPI_SPMI_top
link
read_sdc ../syn/MIPI_SPMI.sdc
compile -map_effort medium
report_area  > rpt/MIPI_SPMI_area.rpt
report_timing > rpt/MIPI_SPMI_timing.rpt
write -format ddc -output netlist/MIPI_SPMI_top.ddc
write -format verilog -output netlist/MIPI_SPMI_top.v
quit
