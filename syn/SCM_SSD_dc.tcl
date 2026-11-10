# SCM_SSD synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SCM_SSD_top.sv
elaborate SCM_SSD_top
link
read_sdc ../syn/SCM_SSD.sdc
compile -map_effort medium
report_area  > rpt/SCM_SSD_area.rpt
report_timing > rpt/SCM_SSD_timing.rpt
write -format ddc -output netlist/SCM_SSD_top.ddc
write -format verilog -output netlist/SCM_SSD_top.v
quit
