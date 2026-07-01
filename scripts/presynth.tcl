# Used to synthesize some tile submodules to Verilog before synthesizing the
# full tile or design. Avoid synthesis instability (what you get here is what
# you get in the full design)
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

synth_design -verilog_define SYNTHESIS -verilog_define VIVADO -mode out_of_context -flatten_hierarchy full
report_utilization
report_timing

opt_design -directive ExploreSequentialArea
#opt_design -directive ExploreWithRemap
report_utilization
report_timing

# Rename submodules to prevent name clashes
rename_ref -prefix_all _$top_module

write_verilog $build_dir/synth_hdl/$top_module.v
