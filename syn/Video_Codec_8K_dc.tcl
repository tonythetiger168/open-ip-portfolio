# Video_Codec_8K synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Video_Codec_8K_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Video_Codec_8K_top
link
read_sdc ../syn/Video_Codec_8K.sdc
compile -map_effort medium
report_area  > rpt/Video_Codec_8K_area.rpt
report_timing > rpt/Video_Codec_8K_timing.rpt
write -format ddc -output netlist/Video_Codec_8K_top.ddc
write -format verilog -output netlist/Video_Codec_8K_top.v
quit
