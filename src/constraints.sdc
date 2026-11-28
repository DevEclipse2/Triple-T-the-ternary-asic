# Base 50 MHz clock (keep TT's existing input/output delays above this)
create_clock [get_ports clk] -name clk -period 20.0

# 4-cycle (80 ns) budget for paths strictly inside u_core
set_multicycle_path 4 -setup -from [get_cells u_core/*] -to [get_cells u_core/*]
set_multicycle_path 3 -hold  -from [get_cells u_core/*] -to [get_cells u_core/*]