# LIN synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/LIN_top.sv
elaborate LIN_top
link
read_sdc ../syn/LIN.sdc
compile -map_effort medium
report_area  > rpt/LIN_area.rpt
report_timing > rpt/LIN_timing.rpt
write -format ddc -output netlist/LIN_top.ddc
write -format verilog -output netlist/LIN_top.v
quit
