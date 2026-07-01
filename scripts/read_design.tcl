# Reads design files; use as a prelude to other scripts
# NOTE: This needs to be called with build_dir set, and relies on the layout
# for HDL files produces by scons.

add_files -norecurse [glob $build_dir/hdl/*.{sv,vh,v}]
add_files -norecurse [glob $build_dir/hdl/bsvlib/*.v]

# dsm: Leaving this for posterity. Looked like a good idea, and seemed to work...
#set_property is_global_include true [get_files $build_dir/hdl/global_defines.vh]
# ...but https://docs.xilinx.com/r/en-US/ug1118-vivado-creating-packaging-custom-ip/Packaging-a-Design-with-Global-Include-Files

set_property top xrt_top [current_fileset]
set_property top_file {$build_dir/xrt_top.v} [current_fileset]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

report_compile_order -of_objects [current_fileset]
