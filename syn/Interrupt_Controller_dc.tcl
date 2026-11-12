# Interrupt_Controller synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/Interrupt_Controller_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate Interrupt_Controller_top
link
read_sdc ../syn/Interrupt_Controller.sdc
compile -map_effort medium
report_area  > rpt/Interrupt_Controller_area.rpt
report_timing > rpt/Interrupt_Controller_timing.rpt
write -format ddc -output netlist/Interrupt_Controller_top.ddc
write -format verilog -output netlist/Interrupt_Controller_top.v
quit
