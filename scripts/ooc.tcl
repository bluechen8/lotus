set_part xcu55c-fsvh2892-2L-e
set_param general.maxThreads 32

if { $::argc != 2 } {
    puts "ERROR: Program \"$::argv0\" requires 2 arguments!\n"
    puts "Usage: $::argv0 <build_dir> <top_module>\n"
    exit
}
set build_dir [lindex $::argv 0]
set top_module [lindex $::argv 1]

source scripts/read_design.tcl

set_property top $top_module [current_fileset]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

synth_design -verilog_define SYNTHESIS -verilog_define VIVADO -mode out_of_context
report_utilization
report_timing
opt_design -directive ExploreWithRemap
report_utilization
report_timing
report_design_analysis -complexity -hierarchical_depth 5
write_checkpoint -force $build_dir/synth.dcp

create_pblock pblock_1
# this is a 2x2 block
resize_pblock pblock_1 -add {CLOCKREGION_X2Y4:CLOCKREGION_X3Y5}
add_cells_to_pblock pblock_1 -top
set_property CONTAIN_ROUTING 1 [get_pblocks pblock_1]

create_clock -period 2.5 -name CLK [get_ports CLK]
# Same source as in Vitis builds
set_property HD.CLK_SRC BUFGCE_X0Y95 [get_ports CLK]

place_design
phys_opt_design
write_checkpoint -force $build_dir/place.dcp
route_design -ultrathreads
phys_opt_design

report_utilization
report_timing
report_design_analysis -complexity -hierarchical_depth 5

write_checkpoint -force $build_dir/route.dcp
