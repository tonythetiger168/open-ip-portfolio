# JTAG synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/JTAG_top.sv
elaborate JTAG_top
link
read_sdc ../syn/JTAG.sdc
compile -map_effort medium
report_area  > rpt/JTAG_area.rpt
report_timing > rpt/JTAG_timing.rpt
write -format ddc -output netlist/JTAG_top.ddc
write -format verilog -output netlist/JTAG_top.v
quit
