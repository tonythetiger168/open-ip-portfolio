# FlexRay constraints -- target 100 MHz (adjust per project)
create_clock -name clk -period 10 [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks clk]
set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.0 -clock clk [all_outputs]
set_driving_cell -lib_cell BUFX2 [all_inputs]
set_load 0.05 [all_outputs]
