# TS_Demux synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/TS_Demux_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate TS_Demux_top
link
read_sdc ../syn/TS_Demux.sdc
compile -map_effort medium
report_area  > rpt/TS_Demux_area.rpt
report_timing > rpt/TS_Demux_timing.rpt
write -format ddc -output netlist/TS_Demux_top.ddc
write -format verilog -output netlist/TS_Demux_top.v
quit
