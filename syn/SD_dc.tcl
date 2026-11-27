# SD synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SD_top.sv
elaborate SD_top
link
read_sdc ../syn/SD.sdc
compile -map_effort medium
report_area  > rpt/SD_area.rpt
report_timing > rpt/SD_timing.rpt
write -format ddc -output netlist/SD_top.ddc
write -format verilog -output netlist/SD_top.v
quit
