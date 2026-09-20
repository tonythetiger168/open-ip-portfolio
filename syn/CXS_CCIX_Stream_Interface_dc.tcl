# CXS CCIX Stream Interface synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/CXS_CCIX_Stream_Interface_top.sv
elaborate CXS_CCIX_Stream_Interface_top
link
read_sdc ../syn/CXS_CCIX_Stream_Interface.sdc
compile -map_effort medium
report_area  > rpt/CXS_CCIX_Stream_Interface_area.rpt
report_timing > rpt/CXS_CCIX_Stream_Interface_timing.rpt
write -format ddc -output netlist/CXS_CCIX_Stream_Interface_top.ddc
write -format verilog -output netlist/CXS_CCIX_Stream_Interface_top.v
quit
