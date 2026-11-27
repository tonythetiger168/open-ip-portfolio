# SAS-4 (Serial Attached SCSI) synthesis script -- msynth (minisim); run from a work directory
read_verilog {../rtl/SAS_4__Serial_Attached_SCSI__top.sv}
elaborate SAS_4__Serial_Attached_SCSI__top
read_sdc ../syn/SAS_4__Serial_Attached_SCSI_.sdc
synthesize
report_area > rpt/SAS_4__Serial_Attached_SCSI__area.rpt
report_timing > rpt/SAS_4__Serial_Attached_SCSI__timing.rpt
write_verilog netlist/SAS_4__Serial_Attached_SCSI__top.v
exit
