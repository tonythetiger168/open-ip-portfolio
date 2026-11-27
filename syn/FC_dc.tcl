# FC synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/FC_top.sv
elaborate FC_top
link
read_sdc ../syn/FC.sdc
compile -map_effort medium
report_area  > rpt/FC_area.rpt
report_timing > rpt/FC_timing.rpt
write -format ddc -output netlist/FC_top.ddc
write -format verilog -output netlist/FC_top.v
quit
