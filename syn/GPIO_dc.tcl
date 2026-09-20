# GPIO synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/GPIO_top.sv
elaborate GPIO_top
link
read_sdc ../syn/GPIO.sdc
compile -map_effort medium
report_area  > rpt/GPIO_area.rpt
report_timing > rpt/GPIO_timing.rpt
write -format ddc -output netlist/GPIO_top.ddc
write -format verilog -output netlist/GPIO_top.v
quit
