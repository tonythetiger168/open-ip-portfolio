# SAS-4 (Serial Attached SCSI) synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/SAS_4__Serial_Attached_SCSI__top.sv
elaborate SAS_4__Serial_Attached_SCSI__top
link
read_sdc ../syn/SAS_4__Serial_Attached_SCSI_.sdc
compile -map_effort medium
report_area  > rpt/SAS_4__Serial_Attached_SCSI__area.rpt
report_timing > rpt/SAS_4__Serial_Attached_SCSI__timing.rpt
write -format ddc -output netlist/SAS_4__Serial_Attached_SCSI__top.ddc
write -format verilog -output netlist/SAS_4__Serial_Attached_SCSI__top.v
quit
