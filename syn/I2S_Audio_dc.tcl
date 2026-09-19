# I2S Audio synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/I2S_Audio_top.sv
elaborate I2S_Audio_top
link
read_sdc ../syn/I2S_Audio.sdc
compile -map_effort medium
report_area  > rpt/I2S_Audio_area.rpt
report_timing > rpt/I2S_Audio_timing.rpt
write -format ddc -output netlist/I2S_Audio_top.ddc
write -format verilog -output netlist/I2S_Audio_top.v
quit
