# Takes an OOC-implemented DCP as input (e.g., as produced by ooc.tcl or
# rapidwright PerformanceExplorer) and produces a relocatable DCP as output.
set_param general.maxThreads 32

if { $::argc != 2 } {
    puts "ERROR: Program \"$::argv0\" requires 2 arguments!\n"
    puts "Usage: $::argv0 <input_dcp> <output_dcp>\n"
    exit
}
set input_dcp [lindex $::argv 0]
set output_dcp [lindex $::argv 1]

open_checkpoint $input_dcp

reset_timing -invalid -clock_reservation
route_design -unroute -nets [get_nets { CLK }]
reset_property HD.CLK_SRC [get_ports CLK]

unplace_cell [get_cells -leaf -filter {(is_primitive==true && primitive_level!="INTERNAL" && primitive_subgroup=="URAM" && loc!="")}]

delete_pblocks [get_pblocks]

write_checkpoint $output_dcp 
