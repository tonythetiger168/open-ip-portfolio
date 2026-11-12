# Video_Codec synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Video_Codec_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Video_Codec_top
link
read_sdc ../syn/Video_Codec.sdc
compile -map_effort medium
report_area  > rpt/Video_Codec_area.rpt
report_timing > rpt/Video_Codec_timing.rpt
write -format ddc -output netlist/Video_Codec_top.ddc
write -format verilog -output netlist/Video_Codec_top.v
quit
