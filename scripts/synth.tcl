# Used to synthesize a module for informational purposes (see synth.py)
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
opt_design -directive ExploreWithRemap
report_utilization
report_timing
