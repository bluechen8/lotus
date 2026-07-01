/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Top-level module for instantiation with XRT (must be Verilog, rather than
// SystemVerilog)

// default_nettype of none prevents implicit wire declaration.
// `default_nettype none
`timescale 1 ns / 1 ps
module xrt_top #(
  parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 16 ,
  parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32
) (
  // System Signals
  input  wire                                    ap_clk               ,
  input  wire                                    ap_rst_n             ,

  // AXI4 master interfaces for main memory (one per tile)
  `MEM_AXI_DEFS

  // AXI4-Lite slave XRT control interface
  input  wire                                    s_axi_control_awvalid,
  output wire                                    s_axi_control_awready,
  input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_awaddr ,
  input  wire                                    s_axi_control_wvalid ,
  output wire                                    s_axi_control_wready ,
  input  wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_wdata  ,
  input  wire [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0] s_axi_control_wstrb  ,
  input  wire                                    s_axi_control_arvalid,
  output wire                                    s_axi_control_arready,
  input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_araddr ,
  output wire                                    s_axi_control_rvalid ,
  input  wire                                    s_axi_control_rready ,
  output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_rdata  ,
  output wire [2-1:0]                            s_axi_control_rresp  ,
  output wire                                    s_axi_control_bvalid ,
  input  wire                                    s_axi_control_bready ,
  output wire [2-1:0]                            s_axi_control_bresp  ,
 
  `CROSS_DEVICE_AXIS_DEFS

  output wire                                    interrupt
);

lotus #(
  .C_S_AXI_CONTROL_ADDR_WIDTH (C_S_AXI_CONTROL_ADDR_WIDTH),
  .C_S_AXI_CONTROL_DATA_WIDTH (C_S_AXI_CONTROL_DATA_WIDTH)
) lotus_inst (
  .clk          ( ap_clk          ),

  `MEM_AXI_CONNECTS
  
  .s_axi_control_awvalid  ( s_axi_control_awvalid ),
  .s_axi_control_awready  ( s_axi_control_awready ),
  .s_axi_control_awaddr   ( s_axi_control_awaddr  ),
  .s_axi_control_wvalid   ( s_axi_control_wvalid  ),
  .s_axi_control_wready   ( s_axi_control_wready  ),
  .s_axi_control_wdata    ( s_axi_control_wdata   ),
  .s_axi_control_wstrb    ( s_axi_control_wstrb   ),
  .s_axi_control_arvalid  ( s_axi_control_arvalid ),
  .s_axi_control_arready  ( s_axi_control_arready ),
  .s_axi_control_araddr   ( s_axi_control_araddr  ),
  .s_axi_control_rvalid   ( s_axi_control_rvalid  ),
  .s_axi_control_rready   ( s_axi_control_rready  ),
  .s_axi_control_rdata    ( s_axi_control_rdata   ),
  .s_axi_control_rresp    ( s_axi_control_rresp   ),
  .s_axi_control_bvalid   ( s_axi_control_bvalid  ),
  .s_axi_control_bready   ( s_axi_control_bready  ),
  .s_axi_control_bresp    ( s_axi_control_bresp   ),

  `CROSS_DEVICE_AXIS_CONNECTS

  .interrupt       ( interrupt             )
);

endmodule
