# UCIe synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/UCIe_top.sv
elaborate UCIe_top
link
read_sdc ../syn/UCIe.sdc
compile -map_effort medium
report_area  > rpt/UCIe_area.rpt
report_timing > rpt/UCIe_timing.rpt
write -format ddc -output netlist/UCIe_top.ddc
write -format verilog -output netlist/UCIe_top.v
quit
