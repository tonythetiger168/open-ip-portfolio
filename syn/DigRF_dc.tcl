# DigRF synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/DigRF_top.sv
elaborate DigRF_top
link
read_sdc ../syn/DigRF.sdc
compile -map_effort medium
report_area  > rpt/DigRF_area.rpt
report_timing > rpt/DigRF_timing.rpt
write -format ddc -output netlist/DigRF_top.ddc
write -format verilog -output netlist/DigRF_top.v
quit
