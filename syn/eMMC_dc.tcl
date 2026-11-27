# eMMC synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/eMMC_top.sv
elaborate eMMC_top
link
read_sdc ../syn/eMMC.sdc
compile -map_effort medium
report_area  > rpt/eMMC_area.rpt
report_timing > rpt/eMMC_timing.rpt
write -format ddc -output netlist/eMMC_top.ddc
write -format verilog -output netlist/eMMC_top.v
quit
