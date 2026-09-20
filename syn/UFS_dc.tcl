# UFS synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UFS_top.sv
elaborate UFS_top
link
read_sdc ../syn/UFS.sdc
compile -map_effort medium
report_area  > rpt/UFS_area.rpt
report_timing > rpt/UFS_timing.rpt
write -format ddc -output netlist/UFS_top.ddc
write -format verilog -output netlist/UFS_top.v
quit
