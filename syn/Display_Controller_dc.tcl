# Display_Controller synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Display_Controller_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Display_Controller_top
link
read_sdc ../syn/Display_Controller.sdc
compile -map_effort medium
report_area  > rpt/Display_Controller_area.rpt
report_timing > rpt/Display_Controller_timing.rpt
write -format ddc -output netlist/Display_Controller_top.ddc
write -format verilog -output netlist/Display_Controller_top.v
quit
