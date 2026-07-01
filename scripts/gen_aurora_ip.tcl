set_part [lindex $argv 0]
set build_dir [lindex $argv 1]


create_ip -name axis_dwidth_converter -vendor xilinx.com -library ip -version 1.1 -dir ${build_dir} \
          -module_name axis_dwidth_widener
#report_property -all [get_ips axis_dwidth_widener]
set_property -dict [list CONFIG.M_TDATA_NUM_BYTES {16} \
                         CONFIG.S_TDATA_NUM_BYTES {8}] \
             [get_ips axis_dwidth_widener]
generate_target all [get_files ${build_dir}/axis_dwidth_widener/axis_dwidth_widener.xci]

create_ip -name axis_dwidth_converter -vendor xilinx.com -library ip -version 1.1 -dir ${build_dir} \
          -module_name axis_dwidth_narrower
set_property -dict [list CONFIG.M_TDATA_NUM_BYTES {8} \
                         CONFIG.S_TDATA_NUM_BYTES {16}] \
             [get_ips axis_dwidth_narrower]
generate_target all [get_files ${build_dir}/axis_dwidth_narrower/axis_dwidth_narrower.xci]


# Aurora lane IPs

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_0
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y6} \
                         CONFIG.C_START_LANE {X0Y24} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {1}] \
             [get_ips aurora_64b66b_0]
#report_property -all [get_ips aurora_64b66b_0]
generate_target all [get_files ${build_dir}/aurora_64b66b_0/aurora_64b66b_0.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_1
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y6} \
                         CONFIG.C_START_LANE {X0Y25} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {0}] \
             [get_ips aurora_64b66b_1]
generate_target all [get_files ${build_dir}/aurora_64b66b_1/aurora_64b66b_1.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_2
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y6} \
                         CONFIG.C_START_LANE {X0Y26} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {0}] \
             [get_ips aurora_64b66b_2]
generate_target all [get_files ${build_dir}/aurora_64b66b_2/aurora_64b66b_2.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_3
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y6} \
                         CONFIG.C_START_LANE {X0Y27} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {0}] \
             [get_ips aurora_64b66b_3]
generate_target all [get_files ${build_dir}/aurora_64b66b_3/aurora_64b66b_3.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_4
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y7} \
                         CONFIG.C_START_LANE {X0Y28} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {1}] \
             [get_ips aurora_64b66b_4]
#report_property -all [get_ips aurora_64b66b_4]
generate_target all [get_files ${build_dir}/aurora_64b66b_4/aurora_64b66b_4.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_5
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y7} \
                         CONFIG.C_START_LANE {X0Y29} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {0}] \
             [get_ips aurora_64b66b_5]
generate_target all [get_files ${build_dir}/aurora_64b66b_5/aurora_64b66b_5.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_6
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y7} \
                         CONFIG.C_START_LANE {X0Y30} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {0}] \
             [get_ips aurora_64b66b_6]
generate_target all [get_files ${build_dir}/aurora_64b66b_6/aurora_64b66b_6.xci]

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -dir ${build_dir} \
          -module_name aurora_64b66b_7
set_property -dict [list CONFIG.C_AURORA_LANES {1} \
                         CONFIG.C_COLUMN_USED {left} \
                         CONFIG.C_UCOLUMN_USED {left} \
                         CONFIG.C_START_QUAD {Quad_X0Y7} \
                         CONFIG.C_START_LANE {X0Y31} \
			 CONFIG.INS_LOSS_NYQ {17} \
			 CONFIG.C_LINE_RATE {25.78125} \
                         CONFIG.C_REFCLK_FREQUENCY {161.1328125} \
                         CONFIG.C_INIT_CLK {100} \
			 CONFIG.interface_mode {Framing} \
                         CONFIG.drp_mode {Native} \
                         CONFIG.SupportLevel {0}] \
             [get_ips aurora_64b66b_7]
generate_target all [get_files ${build_dir}/aurora_64b66b_7/aurora_64b66b_7.xci]


# AXI-Stream FIFOs
# dsm: Small but wide output FIFO whose sole goal is to convert clocks
create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -dir ${build_dir} \
          -module_name axis_data_fifo_s

set_property -dict [list CONFIG.TDATA_NUM_BYTES {12} \
                         CONFIG.IS_ACLK_ASYNC {1} \
			 CONFIG.FIFO_DEPTH {16} \
			 CONFIG.FIFO_MEMORY_TYPE {distributed}] \
             [get_ips axis_data_fifo_s]
generate_target all [get_files ${build_dir}/axis_data_fifo_s/axis_data_fifo_s.xci]

