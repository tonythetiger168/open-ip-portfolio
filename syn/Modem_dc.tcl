# Modem synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Modem_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Modem_top
link
read_sdc ../syn/Modem.sdc
compile -map_effort medium
report_area  > rpt/Modem_area.rpt
report_timing > rpt/Modem_timing.rpt
write -format ddc -output netlist/Modem_top.ddc
write -format verilog -output netlist/Modem_top.v
quit
