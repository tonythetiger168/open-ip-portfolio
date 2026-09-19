# ARM Q-Channel Low Power Interface synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ARM_Q_Channel_Low_Power_Interface_top.sv
elaborate ARM_Q_Channel_Low_Power_Interface_top
link
read_sdc ../syn/ARM_Q_Channel_Low_Power_Interface.sdc
compile -map_effort medium
report_area  > rpt/ARM_Q_Channel_Low_Power_Interface_area.rpt
report_timing > rpt/ARM_Q_Channel_Low_Power_Interface_timing.rpt
write -format ddc -output netlist/ARM_Q_Channel_Low_Power_Interface_top.ddc
write -format verilog -output netlist/ARM_Q_Channel_Low_Power_Interface_top.v
quit
