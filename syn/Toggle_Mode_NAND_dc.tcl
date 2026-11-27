# Toggle Mode NAND synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/Toggle_Mode_NAND_top.sv
elaborate Toggle_Mode_NAND_top
link
read_sdc ../syn/Toggle_Mode_NAND.sdc
compile -map_effort medium
report_area  > rpt/Toggle_Mode_NAND_area.rpt
report_timing > rpt/Toggle_Mode_NAND_timing.rpt
write -format ddc -output netlist/Toggle_Mode_NAND_top.ddc
write -format verilog -output netlist/Toggle_Mode_NAND_top.v
quit
