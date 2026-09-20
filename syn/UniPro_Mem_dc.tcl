# UniPro-Mem synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UniPro_Mem_top.sv
elaborate UniPro_Mem_top
link
read_sdc ../syn/UniPro_Mem.sdc
compile -map_effort medium
report_area  > rpt/UniPro_Mem_area.rpt
report_timing > rpt/UniPro_Mem_timing.rpt
write -format ddc -output netlist/UniPro_Mem_top.ddc
write -format verilog -output netlist/UniPro_Mem_top.v
quit
