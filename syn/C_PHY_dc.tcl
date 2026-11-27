# C-PHY synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/C_PHY_top.sv
elaborate C_PHY_top
link
read_sdc ../syn/C_PHY.sdc
compile -map_effort medium
report_area  > rpt/C_PHY_area.rpt
report_timing > rpt/C_PHY_timing.rpt
write -format ddc -output netlist/C_PHY_top.ddc
write -format verilog -output netlist/C_PHY_top.v
quit
