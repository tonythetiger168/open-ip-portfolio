# MIPI SoundWire synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/MIPI_SoundWire_top.sv
elaborate MIPI_SoundWire_top
link
read_sdc ../syn/MIPI_SoundWire.sdc
compile -map_effort medium
report_area  > rpt/MIPI_SoundWire_area.rpt
report_timing > rpt/MIPI_SoundWire_timing.rpt
write -format ddc -output netlist/MIPI_SoundWire_top.ddc
write -format verilog -output netlist/MIPI_SoundWire_top.v
quit
