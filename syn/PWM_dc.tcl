# PWM synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/PWM_top.sv
elaborate PWM_top
link
read_sdc ../syn/PWM.sdc
compile -map_effort medium
report_area  > rpt/PWM_area.rpt
report_timing > rpt/PWM_timing.rpt
write -format ddc -output netlist/PWM_top.ddc
write -format verilog -output netlist/PWM_top.v
quit
