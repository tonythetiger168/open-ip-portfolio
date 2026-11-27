# I2C synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/I2C_top.sv
elaborate I2C_top
link
read_sdc ../syn/I2C.sdc
compile -map_effort medium
report_area  > rpt/I2C_area.rpt
report_timing > rpt/I2C_timing.rpt
write -format ddc -output netlist/I2C_top.ddc
write -format verilog -output netlist/I2C_top.v
quit
