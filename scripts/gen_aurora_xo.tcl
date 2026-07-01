if { $::argc != 4 } {
    puts "ERROR: Program \"$::argv0\" requires 4 arguments!\n"
    puts "Usage: $::argv0 <xoname> <krnl_name> <target> <part>\n"
    exit
}

set xoname    [lindex $::argv 0]
set krnl_name [lindex $::argv 1]
set target    [lindex $::argv 2]
set part    [lindex $::argv 3]

set build_dir [file dirname ${xoname}]
set suffix "${krnl_name}_${target}"

create_project ${krnl_name} ${build_dir}/${suffix} -part ${part} 

add_files aurora/aurora.v
add_files aurora/aurora.sv
add_files aurora/retransmit.sv
add_files aurora/crc.vh
add_files lotus/sip/sip.sv
add_files lotus/sip/sip_cdc.sv
add_files lotus/sip/sip.vh
add_files -norecurse [glob ${build_dir}/aurora_ip/*/*.xci]

add_files -norecurse -fileset constrs_1 {config/aurora.xdc}

update_compile_order -fileset sources_1

# create IP packaging project
ipx::package_project -root_dir ${build_dir}/package_${suffix} -vendor xilinx.com -library user -taxonomy /UserIP -import_files -set_current true

# inference clock and reset signals
ipx::infer_bus_interface ap_clk xilinx.com:signal:clock_rtl:1.0 [ipx::current_core]
# dsm: ap_rst_n gone, reset is now internally generated so we can avoid stray packets
#ipx::infer_bus_interface ap_rst_n xilinx.com:signal:reset_rtl:1.0 [ipx::current_core]
# remove auto inferred clock interface init_clk, just treat it as a normal port
ipx::remove_bus_interface init_clk [ipx::current_core]

# associate AXI/AXIS interface with clock
ipx::associate_bus_interfaces -busif s_axi_control  -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx0_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx1_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx2_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx3_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx4_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx5_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx6_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif tx7_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx0_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx1_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx2_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx3_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx4_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx5_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx6_axis -clock ap_clk [ipx::current_core]
ipx::associate_bus_interfaces -busif rx7_axis -clock ap_clk [ipx::current_core]

# create GT data ports
ipx::add_bus_interface gt0_port [ipx::current_core]
set_property interface_mode master                                    [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:gt_rtl:1.0    [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:interface:gt:1.0                [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]

ipx::add_port_map GRX_P                                               [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]
set_property physical_name gt0_rxp_in [ipx::get_port_maps GRX_P -of_objects [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]]

ipx::add_port_map GTX_N                                               [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]
set_property physical_name gt0_txn_out [ipx::get_port_maps GTX_N -of_objects [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]]

ipx::add_port_map GRX_N                                               [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]
set_property physical_name gt0_rxn_in [ipx::get_port_maps GRX_N -of_objects [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]]

ipx::add_port_map GTX_P                                               [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]
set_property physical_name gt0_txp_out [ipx::get_port_maps GTX_P -of_objects [ipx::get_bus_interfaces gt0_port -of_objects [ipx::current_core]]]

ipx::add_bus_interface gt1_port [ipx::current_core]
set_property interface_mode master                                    [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:gt_rtl:1.0    [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:interface:gt:1.0                [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]

ipx::add_port_map GRX_P                                               [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]
set_property physical_name gt1_rxp_in [ipx::get_port_maps GRX_P -of_objects [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]]

ipx::add_port_map GTX_N                                               [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]
set_property physical_name gt1_txn_out [ipx::get_port_maps GTX_N -of_objects [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]]

ipx::add_port_map GRX_N                                               [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]
set_property physical_name gt1_rxn_in [ipx::get_port_maps GRX_N -of_objects [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]]

ipx::add_port_map GTX_P                                               [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]
set_property physical_name gt1_txp_out [ipx::get_port_maps GTX_P -of_objects [ipx::get_bus_interfaces gt1_port -of_objects [ipx::current_core]]]



# create GT clock port
ipx::add_bus_interface gt0_refclk [ipx::current_core]
set_property interface_mode slave                                            [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:diff_clock_rtl:1.0   [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:interface:diff_clock:1.0               [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]

ipx::add_port_map CLK_P                                                      [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]
set_property physical_name gt0_refclk_p [ipx::get_port_maps CLK_P -of_objects [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]]

ipx::add_port_map CLK_N                                                      [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]
set_property physical_name gt0_refclk_n [ipx::get_port_maps CLK_N -of_objects [ipx::get_bus_interfaces gt0_refclk -of_objects [ipx::current_core]]]

ipx::add_bus_interface gt1_refclk [ipx::current_core]
set_property interface_mode slave                                            [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]
set_property abstraction_type_vlnv xilinx.com:interface:diff_clock_rtl:1.0   [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]
set_property bus_type_vlnv xilinx.com:interface:diff_clock:1.0               [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]

ipx::add_port_map CLK_P                                                      [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]
set_property physical_name gt1_refclk_p [ipx::get_port_maps CLK_P -of_objects [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]]

ipx::add_port_map CLK_N                                                      [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]
set_property physical_name gt1_refclk_n [ipx::get_port_maps CLK_N -of_objects [ipx::get_bus_interfaces gt1_refclk -of_objects [ipx::current_core]]]

# Set required property for Vitis kernel
set_property sdx_kernel true [ipx::current_core]
set_property sdx_kernel_type rtl [ipx::current_core]

# Packaging Vivado IP
ipx::update_source_project_archive -component [ipx::current_core]
ipx::save_core [ipx::current_core]

# Generate Vitis Kernel from Vivado IP
package_xo -force -xo_path ${xoname} -kernel_name ${krnl_name} -ctrl_protocol ap_ctrl_none -ip_directory ${build_dir}/package_${suffix} -output_kernel_xml ${build_dir}/${krnl_name}.xml

