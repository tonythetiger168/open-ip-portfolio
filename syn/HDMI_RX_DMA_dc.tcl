# HDMI_RX_DMA synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/HDMI_RX_DMA_top.sv ../rtl/soc_ss_axi_engine.sv ../rtl/tv_fifo.sv}
elaborate HDMI_RX_DMA_top
link
read_sdc ../syn/HDMI_RX_DMA.sdc
compile -map_effort medium
report_area  > rpt/HDMI_RX_DMA_area.rpt
report_timing > rpt/HDMI_RX_DMA_timing.rpt
write -format ddc -output netlist/HDMI_RX_DMA_top.ddc
write -format verilog -output netlist/HDMI_RX_DMA_top.v
quit
