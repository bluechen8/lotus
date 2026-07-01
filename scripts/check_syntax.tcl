# "Quick" syntax / RTL synthesis check
# Faster than using vitis/vpl, but still pretty slow; use verilator linting instead... 

if { $::argc != 1 } {
    puts "ERROR: Program \"$::argv0\" requires 1 argument!\n"
    puts "Usage: $::argv0 <build_dir>\n"
    exit
}
set build_dir [lindex $::argv 0]

source scripts/read_design.tcl
check_syntax
synth_design -flatten_hierarchy full -part xcu250-figd2104-2L-e
