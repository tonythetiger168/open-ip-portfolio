# I2S synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/I2S_top.sv
elaborate I2S_top
link
read_sdc ../syn/I2S.sdc
compile -map_effort medium
report_area  > rpt/I2S_area.rpt
report_timing > rpt/I2S_timing.rpt
write -format ddc -output netlist/I2S_top.ddc
write -format verilog -output netlist/I2S_top.v
quit
