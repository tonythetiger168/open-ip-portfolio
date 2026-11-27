# SATA synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SATA_top.sv
elaborate SATA_top
link
read_sdc ../syn/SATA.sdc
compile -map_effort medium
report_area  > rpt/SATA_area.rpt
report_timing > rpt/SATA_timing.rpt
write -format ddc -output netlist/SATA_top.ddc
write -format verilog -output netlist/SATA_top.v
quit
