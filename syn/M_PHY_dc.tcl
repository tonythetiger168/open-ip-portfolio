# M-PHY synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/M_PHY_top.sv
elaborate M_PHY_top
link
read_sdc ../syn/M_PHY.sdc
compile -map_effort medium
report_area  > rpt/M_PHY_area.rpt
report_timing > rpt/M_PHY_timing.rpt
write -format ddc -output netlist/M_PHY_top.ddc
write -format verilog -output netlist/M_PHY_top.v
quit
