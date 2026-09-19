# USB synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB_top.sv
elaborate USB_top
link
read_sdc ../syn/USB.sdc
compile -map_effort medium
report_area  > rpt/USB_area.rpt
report_timing > rpt/USB_timing.rpt
write -format ddc -output netlist/USB_top.ddc
write -format verilog -output netlist/USB_top.v
quit
