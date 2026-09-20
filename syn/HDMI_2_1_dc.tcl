# HDMI 2.1 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/HDMI_2_1_top.sv
elaborate HDMI_2_1_top
link
read_sdc ../syn/HDMI_2_1.sdc
compile -map_effort medium
report_area  > rpt/HDMI_2_1_area.rpt
report_timing > rpt/HDMI_2_1_timing.rpt
write -format ddc -output netlist/HDMI_2_1_top.ddc
write -format verilog -output netlist/HDMI_2_1_top.v
quit
