# MIPI SoundWire synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/MIPI_SoundWire_top.sv}
elaborate MIPI_SoundWire_top
read_sdc ../syn/MIPI_SoundWire.sdc
synthesize
report_area > rpt/MIPI_SoundWire_area.rpt
report_timing > rpt/MIPI_SoundWire_timing.rpt
write_verilog netlist/MIPI_SoundWire_top.v
exit
