# ARM Local Translation Interface synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ARM_Local_Translation_Interface_top.sv
elaborate ARM_Local_Translation_Interface_top
link
read_sdc ../syn/ARM_Local_Translation_Interface.sdc
compile -map_effort medium
report_area  > rpt/ARM_Local_Translation_Interface_area.rpt
report_timing > rpt/ARM_Local_Translation_Interface_timing.rpt
write -format ddc -output netlist/ARM_Local_Translation_Interface_top.ddc
write -format verilog -output netlist/ARM_Local_Translation_Interface_top.v
quit
