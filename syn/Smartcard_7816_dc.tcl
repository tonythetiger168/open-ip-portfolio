# Smartcard_7816 synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Smartcard_7816_top.sv ../rtl/soc_ss_axi_engine.sv ../rtl/tv_fifo.sv}
elaborate Smartcard_7816_top
link
read_sdc ../syn/Smartcard_7816.sdc
compile -map_effort medium
report_area  > rpt/Smartcard_7816_area.rpt
report_timing > rpt/Smartcard_7816_timing.rpt
write -format ddc -output netlist/Smartcard_7816_top.ddc
write -format verilog -output netlist/Smartcard_7816_top.v
quit
