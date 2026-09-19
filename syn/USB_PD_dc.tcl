# USB-PD synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/USB_PD_top.sv
elaborate USB_PD_top
link
read_sdc ../syn/USB_PD.sdc
compile -map_effort medium
report_area  > rpt/USB_PD_area.rpt
report_timing > rpt/USB_PD_timing.rpt
write -format ddc -output netlist/USB_PD_top.ddc
write -format verilog -output netlist/USB_PD_top.v
quit
