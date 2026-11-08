# CPU_Cluster synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/CPU_Cluster_top.sv ../rtl/soc_ss_axi_engine.sv}
elaborate CPU_Cluster_top
link
read_sdc ../syn/CPU_Cluster.sdc
compile -map_effort medium
report_area  > rpt/CPU_Cluster_area.rpt
report_timing > rpt/CPU_Cluster_timing.rpt
write -format ddc -output netlist/CPU_Cluster_top.ddc
write -format verilog -output netlist/CPU_Cluster_top.v
quit
