# HDCP 2.3 Content Protection synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HDCP_2_3_Content_Protection_top.sv
elaborate HDCP_2_3_Content_Protection_top
link
read_sdc ../syn/HDCP_2_3_Content_Protection.sdc
compile -map_effort medium
report_area  > rpt/HDCP_2_3_Content_Protection_area.rpt
report_timing > rpt/HDCP_2_3_Content_Protection_timing.rpt
write -format ddc -output netlist/HDCP_2_3_Content_Protection_top.ddc
write -format verilog -output netlist/HDCP_2_3_Content_Protection_top.v
quit
