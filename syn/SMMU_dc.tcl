# SMMU synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/SMMU_top.sv }
elaborate SMMU_top
link
read_sdc ../syn/SMMU.sdc
compile -map_effort medium
report_area  > rpt/SMMU_area.rpt
report_timing > rpt/SMMU_timing.rpt
write -format ddc -output netlist/SMMU_top.ddc
write -format verilog -output netlist/SMMU_top.v
quit
