# DFI 5.0 (MC-PHY Interface) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DFI_5_0__MC_PHY_Interface__top.sv
elaborate DFI_5_0__MC_PHY_Interface__top
link
read_sdc ../syn/DFI_5_0__MC_PHY_Interface_.sdc
compile -map_effort medium
report_area  > rpt/DFI_5_0__MC_PHY_Interface__area.rpt
report_timing > rpt/DFI_5_0__MC_PHY_Interface__timing.rpt
write -format ddc -output netlist/DFI_5_0__MC_PHY_Interface__top.ddc
write -format verilog -output netlist/DFI_5_0__MC_PHY_Interface__top.v
quit
