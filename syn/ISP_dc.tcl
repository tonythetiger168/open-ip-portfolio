# ISP synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/ISP_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate ISP_top
link
read_sdc ../syn/ISP.sdc
compile -map_effort medium
report_area  > rpt/ISP_area.rpt
report_timing > rpt/ISP_timing.rpt
write -format ddc -output netlist/ISP_top.ddc
write -format verilog -output netlist/ISP_top.v
quit
