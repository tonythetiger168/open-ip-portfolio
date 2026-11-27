# UniPro synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UniPro_top.sv
elaborate UniPro_top
link
read_sdc ../syn/UniPro.sdc
compile -map_effort medium
report_area  > rpt/UniPro_area.rpt
report_timing > rpt/UniPro_timing.rpt
write -format ddc -output netlist/UniPro_top.ddc
write -format verilog -output netlist/UniPro_top.v
quit
