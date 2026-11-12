# TCON_VbyOne synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/TCON_VbyOne_top.sv ../rtl/soc_ss_axi_engine.sv ../rtl/tv_fifo.sv}
elaborate TCON_VbyOne_top
link
read_sdc ../syn/TCON_VbyOne.sdc
compile -map_effort medium
report_area  > rpt/TCON_VbyOne_area.rpt
report_timing > rpt/TCON_VbyOne_timing.rpt
write -format ddc -output netlist/TCON_VbyOne_top.ddc
write -format verilog -output netlist/TCON_VbyOne_top.v
quit
