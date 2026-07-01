# Produces a synthesized DCP with the clock set up to build a pre-implemented
# module. Fastflow uses this for the tile, but could be use for other
# components (e.g., the task switch).
set_part xcu55c-fsvh2892-2L-e
set_param general.maxThreads 32

if { $::argc != 4 } {
    puts "ERROR: Program \"$::argv0\" requires 3 arguments!\n"
    puts "Usage: $::argv0 <build_dir> <top_module> <out_dcp> <clock_period>\n"
    exit
}
set build_dir [lindex $::argv 0]
set top_module [lindex $::argv 1]
set out_dcp [lindex $::argv 2]
set clock_period [lindex $::argv 3]

add_files -norecurse [glob $build_dir/synth_hdl/*.{sv,vh,v}]

set_property top $top_module [current_fileset]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
report_compile_order -of_objects [current_fileset]

synth_design -verilog_define SYNTHESIS -verilog_define VIVADO -mode out_of_context
report_utilization
report_timing
opt_design -directive ExploreWithRemap
report_utilization
report_timing
report_design_analysis -complexity -hierarchical_depth 5

create_clock -period $clock_period -name CLK [get_ports CLK]
# Same source as in Vitis builds
set_property HD.CLK_SRC BUFGCE_X0Y95 [get_ports CLK]

write_checkpoint -force $out_dcp
