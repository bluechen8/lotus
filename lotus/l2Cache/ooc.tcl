set_part xcu250-figd2104-2L-e
set_param general.maxThreads 32

if { $::argc != 1 } {
    puts "ERROR: Program \"$::argv0\" requires 1 arguments!\n"
    puts "Usage: $::argv0 <build_dir>\n"
    exit
}
set build_dir [lindex $::argv 0]

add_files [glob *.v]
add_files [glob ../xram/*.sv]
add_files [glob ../utils/*.sv]
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog/FIFO1.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog/FIFO2.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog/FIFO10.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog/FIFO20.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog.Vivado/SizedFIFO.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog.Vivado/RegFile.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog/Counter.v
add_files /data/sanchez/tools/bluespec/ubuntu1804/bsc-2022.01/lib/Verilog/RevertReg.v

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property top mkL2Cache [current_fileset]
set_property top_file {mkL2Cache.v} [current_fileset]
report_compile_order -of_objects [current_fileset]


synth_design -verilog_define SYNTHESIS -verilog_define VIVADO -mode out_of_context
report_utilization
report_timing
opt_design -directive ExploreWithRemap
report_utilization
report_timing
report_design_analysis -complexity -hierarchical_depth 10
write_checkpoint -force $build_dir/synth.dcp
write_verilog -force $build_dir/synth.v

create_pblock pblock_1
# this is a 4x3 block
resize_pblock pblock_1 -add {CLOCKREGION_X0Y12:CLOCKREGION_X3Y15}
add_cells_to_pblock pblock_1 -top
set_property CONTAIN_ROUTING 1 [get_pblocks pblock_1]
create_clock -period 2.5 -name CLK [get_ports CLK]
set_property HD.CLK_SRC BUFGCTRL_X0Y13 [get_ports CLK]

place_design
phys_opt_design
write_checkpoint -force $build_dir/place.dcp
route_design
phys_opt_design

report_utilization
report_timing
report_design_analysis -complexity -hierarchical_depth 10

write_checkpoint -force $build_dir/route.dcp
