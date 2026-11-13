# SPDIF_eARC synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/SPDIF_eARC_top.sv ../rtl/soc_ss_axi_engine.sv ../rtl/tv_fifo.sv}
elaborate SPDIF_eARC_top
link
read_sdc ../syn/SPDIF_eARC.sdc
compile -map_effort medium
report_area  > rpt/SPDIF_eARC_area.rpt
report_timing > rpt/SPDIF_eARC_timing.rpt
write -format ddc -output netlist/SPDIF_eARC_top.ddc
write -format verilog -output netlist/SPDIF_eARC_top.v
quit
