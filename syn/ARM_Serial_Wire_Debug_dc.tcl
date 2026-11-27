# ARM Serial Wire Debug synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/ARM_Serial_Wire_Debug_top.sv
elaborate ARM_Serial_Wire_Debug_top
link
read_sdc ../syn/ARM_Serial_Wire_Debug.sdc
compile -map_effort medium
report_area  > rpt/ARM_Serial_Wire_Debug_area.rpt
report_timing > rpt/ARM_Serial_Wire_Debug_timing.rpt
write -format ddc -output netlist/ARM_Serial_Wire_Debug_top.ddc
write -format verilog -output netlist/ARM_Serial_Wire_Debug_top.v
quit
