# GPU synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/GPU_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate GPU_top
link
read_sdc ../syn/GPU.sdc
compile -map_effort medium
report_area  > rpt/GPU_area.rpt
report_timing > rpt/GPU_timing.rpt
write -format ddc -output netlist/GPU_top.ddc
write -format verilog -output netlist/GPU_top.v
quit
