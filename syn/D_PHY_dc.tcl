# D-PHY synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/D_PHY_top.sv
elaborate D_PHY_top
link
read_sdc ../syn/D_PHY.sdc
compile -map_effort medium
report_area  > rpt/D_PHY_area.rpt
report_timing > rpt/D_PHY_timing.rpt
write -format ddc -output netlist/D_PHY_top.ddc
write -format verilog -output netlist/D_PHY_top.v
quit
