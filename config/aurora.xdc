# Reference clock constraints for GTY
create_clock  -name gt0_refclk_in -period 6.206	 [get_ports gt0_refclk_p]
set_clock_groups -asynchronous -group [get_clocks gt0_refclk_in -include_generated_clocks]

create_clock  -name gt1_refclk_in -period 6.206	 [get_ports gt1_refclk_p]
set_clock_groups -asynchronous -group [get_clocks gt1_refclk_in -include_generated_clocks]
