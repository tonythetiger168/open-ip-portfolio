# Timer_WDT synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Timer_WDT_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Timer_WDT_top
link
read_sdc ../syn/Timer_WDT.sdc
compile -map_effort medium
report_area  > rpt/Timer_WDT_area.rpt
report_timing > rpt/Timer_WDT_timing.rpt
write -format ddc -output netlist/Timer_WDT_top.ddc
write -format verilog -output netlist/Timer_WDT_top.v
quit
