# PQ_MEMC synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog {../rtl/pq/pq_pkg.sv ../rtl/pq/l0_metadata_unit.sv ../rtl/pq/l1_tone_map_eetf.sv ../rtl/pq/l2d_memc_blend.sv ../rtl/PQ_MEMC_top.sv ../rtl/soc_ss_axi_engine.sv ../rtl/tv_fifo.sv}
elaborate PQ_MEMC_top
link
read_sdc ../syn/PQ_MEMC.sdc
compile -map_effort medium
report_area  > rpt/PQ_MEMC_area.rpt
report_timing > rpt/PQ_MEMC_timing.rpt
write -format ddc -output netlist/PQ_MEMC_top.ddc
write -format verilog -output netlist/PQ_MEMC_top.v
quit
