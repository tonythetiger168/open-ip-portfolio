# NVMe synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/NVMe_top.sv
elaborate NVMe_top
link
read_sdc ../syn/NVMe.sdc
compile -map_effort medium
report_area  > rpt/NVMe_area.rpt
report_timing > rpt/NVMe_timing.rpt
write -format ddc -output netlist/NVMe_top.ddc
write -format verilog -output netlist/NVMe_top.v
quit
