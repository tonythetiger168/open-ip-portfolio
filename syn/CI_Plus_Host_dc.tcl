# CI_Plus_Host synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/CI_Plus_Host_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate CI_Plus_Host_top
link
read_sdc ../syn/CI_Plus_Host.sdc
compile -map_effort medium
report_area  > rpt/CI_Plus_Host_area.rpt
report_timing > rpt/CI_Plus_Host_timing.rpt
write -format ddc -output netlist/CI_Plus_Host_top.ddc
write -format verilog -output netlist/CI_Plus_Host_top.v
quit
