# NPU synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/NPU_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate NPU_top
link
read_sdc ../syn/NPU.sdc
compile -map_effort medium
report_area  > rpt/NPU_area.rpt
report_timing > rpt/NPU_timing.rpt
write -format ddc -output netlist/NPU_top.ddc
write -format verilog -output netlist/NPU_top.v
quit
