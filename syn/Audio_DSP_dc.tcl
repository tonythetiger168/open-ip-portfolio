# Audio_DSP synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Audio_DSP_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Audio_DSP_top
link
read_sdc ../syn/Audio_DSP.sdc
compile -map_effort medium
report_area  > rpt/Audio_DSP_area.rpt
report_timing > rpt/Audio_DSP_timing.rpt
write -format ddc -output netlist/Audio_DSP_top.ddc
write -format verilog -output netlist/Audio_DSP_top.v
quit
