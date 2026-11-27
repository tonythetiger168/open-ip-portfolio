# GMII synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/GMII_top.sv
elaborate GMII_top
link
read_sdc ../syn/GMII.sdc
compile -map_effort medium
report_area  > rpt/GMII_area.rpt
report_timing > rpt/GMII_timing.rpt
write -format ddc -output netlist/GMII_top.ddc
write -format verilog -output netlist/GMII_top.v
quit
