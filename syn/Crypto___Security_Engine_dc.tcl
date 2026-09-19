# Crypto / Security Engine synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Crypto___Security_Engine_top.sv
elaborate Crypto___Security_Engine_top
link
read_sdc ../syn/Crypto___Security_Engine.sdc
compile -map_effort medium
report_area  > rpt/Crypto___Security_Engine_area.rpt
report_timing > rpt/Crypto___Security_Engine_timing.rpt
write -format ddc -output netlist/Crypto___Security_Engine_top.ddc
write -format verilog -output netlist/Crypto___Security_Engine_top.v
quit
