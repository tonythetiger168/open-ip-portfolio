# TSP synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/TSP_top.sv ../rtl/tsp_aes128_dec.sv ../rtl/soc_ss_axi_engine.sv}
elaborate TSP_top
link
read_sdc ../syn/TSP.sdc
compile -map_effort medium
report_area  > rpt/TSP_area.rpt
report_timing > rpt/TSP_timing.rpt
write -format ddc -output netlist/TSP_top.ddc
write -format verilog -output netlist/TSP_top.v
quit
