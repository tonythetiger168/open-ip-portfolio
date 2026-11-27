# RGMII synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/RGMII_top.sv
elaborate RGMII_top
link
read_sdc ../syn/RGMII.sdc
compile -map_effort medium
report_area  > rpt/RGMII_area.rpt
report_timing > rpt/RGMII_timing.rpt
write -format ddc -output netlist/RGMII_top.ddc
write -format verilog -output netlist/RGMII_top.v
quit
