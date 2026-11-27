# PCIe synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/PCIe_top.sv}
elaborate PCIe_top
read_sdc ../syn/PCIe.sdc
synthesize
report_area > rpt/PCIe_area.rpt
report_timing > rpt/PCIe_timing.rpt
write_verilog netlist/PCIe_top.v
exit
