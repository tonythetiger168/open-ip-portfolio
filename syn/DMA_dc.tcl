# DMA synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/DMA_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate DMA_top
link
read_sdc ../syn/DMA.sdc
compile -map_effort medium
report_area  > rpt/DMA_area.rpt
report_timing > rpt/DMA_timing.rpt
write -format ddc -output netlist/DMA_top.ddc
write -format verilog -output netlist/DMA_top.v
quit
