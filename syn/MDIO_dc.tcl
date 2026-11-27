# MDIO synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MDIO_top.sv
elaborate MDIO_top
link
read_sdc ../syn/MDIO.sdc
compile -map_effort medium
report_area  > rpt/MDIO_area.rpt
report_timing > rpt/MDIO_timing.rpt
write -format ddc -output netlist/MDIO_top.ddc
write -format verilog -output netlist/MDIO_top.v
quit
