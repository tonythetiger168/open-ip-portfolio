# I3C synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/I3C_top.sv
elaborate I3C_top
link
read_sdc ../syn/I3C.sdc
compile -map_effort medium
report_area  > rpt/I3C_area.rpt
report_timing > rpt/I3C_timing.rpt
write -format ddc -output netlist/I3C_top.ddc
write -format verilog -output netlist/I3C_top.v
quit
