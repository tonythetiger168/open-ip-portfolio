# IR_Receiver synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/IR_Receiver_top.sv ../rtl/soc_ss_axi_engine.sv ../rtl/tv_fifo.sv}
elaborate IR_Receiver_top
link
read_sdc ../syn/IR_Receiver.sdc
compile -map_effort medium
report_area  > rpt/IR_Receiver_area.rpt
report_timing > rpt/IR_Receiver_timing.rpt
write -format ddc -output netlist/IR_Receiver_top.ddc
write -format verilog -output netlist/IR_Receiver_top.v
quit
