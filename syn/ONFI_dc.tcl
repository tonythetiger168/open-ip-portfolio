# ONFI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ONFI_top.sv
elaborate ONFI_top
link
read_sdc ../syn/ONFI.sdc
compile -map_effort medium
report_area  > rpt/ONFI_area.rpt
report_timing > rpt/ONFI_timing.rpt
write -format ddc -output netlist/ONFI_top.ddc
write -format verilog -output netlist/ONFI_top.v
quit
