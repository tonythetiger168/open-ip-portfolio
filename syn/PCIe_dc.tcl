# PCIe synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/PCIe_top.sv
elaborate PCIe_top
link
read_sdc ../syn/PCIe.sdc
compile -map_effort medium
report_area  > rpt/PCIe_area.rpt
report_timing > rpt/PCIe_timing.rpt
write -format ddc -output netlist/PCIe_top.ddc
write -format verilog -output netlist/PCIe_top.v
quit
