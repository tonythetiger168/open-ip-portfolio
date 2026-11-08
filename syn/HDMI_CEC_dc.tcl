# HDMI_CEC synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/HDMI_CEC_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate HDMI_CEC_top
link
read_sdc ../syn/HDMI_CEC.sdc
compile -map_effort medium
report_area  > rpt/HDMI_CEC_area.rpt
report_timing > rpt/HDMI_CEC_timing.rpt
write -format ddc -output netlist/HDMI_CEC_top.ddc
write -format verilog -output netlist/HDMI_CEC_top.v
quit
