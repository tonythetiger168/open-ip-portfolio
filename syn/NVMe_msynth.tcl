# NVMe synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/NVMe_top.sv}
elaborate NVMe_top
read_sdc ../syn/NVMe.sdc
synthesize
report_area > rpt/NVMe_area.rpt
report_timing > rpt/NVMe_timing.rpt
write_verilog netlist/NVMe_top.v
exit
