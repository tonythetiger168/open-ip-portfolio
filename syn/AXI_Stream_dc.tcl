# AXI-Stream synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/AXI_Stream_top.sv
elaborate AXI_Stream_top
link
read_sdc ../syn/AXI_Stream.sdc
compile -map_effort medium
report_area  > rpt/AXI_Stream_area.rpt
report_timing > rpt/AXI_Stream_timing.rpt
write -format ddc -output netlist/AXI_Stream_top.ddc
write -format verilog -output netlist/AXI_Stream_top.v
quit
