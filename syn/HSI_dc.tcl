# HSI synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HSI_top.sv
elaborate HSI_top
link
read_sdc ../syn/HSI.sdc
compile -map_effort medium
report_area  > rpt/HSI_area.rpt
report_timing > rpt/HSI_timing.rpt
write -format ddc -output netlist/HSI_top.ddc
write -format verilog -output netlist/HSI_top.v
quit
