# XGMII synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/XGMII_top.sv
elaborate XGMII_top
link
read_sdc ../syn/XGMII.sdc
compile -map_effort medium
report_area  > rpt/XGMII_area.rpt
report_timing > rpt/XGMII_timing.rpt
write -format ddc -output netlist/XGMII_top.ddc
write -format verilog -output netlist/XGMII_top.v
quit
