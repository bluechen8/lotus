/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Verilog-only top-level module. This exists only because vivado can't do
// SystemVerilog top-level modules properly, and adding features like structs
// or interfaces *anywhere* in the project will cause it to blow up if the
// top-level module is in SV (as of 2022.2).
//
// Keep this interface EXACTLY like aurora_impl (the actual implementation,
// in aurora.sv). This does not use .* for connections only because vivado
// won't take it either.
//
// NOTE(dsm): I initially tried to port the top-level module to Verilog, since
// it's simple, and leave the quads in SV. But this didn't work because (1)
// Verilog doesn't support multidimensional packed arrays or structs, and (2)
// vivado wails when you try to pass an unpacked array (==memory) in Verilog
// mode (SV works fine).

`define AURORA_TOP_AXIS_DEF(id) \
    input  tx``id``_axis_tvalid, \
    input  [96-1:0]  tx``id``_axis_tdata, \
    output tx``id``_axis_tready, \
    output rx``id``_axis_tvalid, \
    output [96-1:0]  rx``id``_axis_tdata, \
    input  rx``id``_axis_tready, \

`define CONNECT(x) .``x``(``x``)

`define AURORA_TOP_AXIS_CONNECT(id) \
    `CONNECT(tx``id``_axis_tvalid), \
    `CONNECT(tx``id``_axis_tdata), \
    `CONNECT(tx``id``_axis_tready), \
    `CONNECT(rx``id``_axis_tvalid), \
    `CONNECT(rx``id``_axis_tdata), \
    `CONNECT(rx``id``_axis_tready) \

module aurora (
    input           ap_clk,
    // Note no reset; reset is internally controlled by the control core
    
    // AXI-Stream ports
    `AURORA_TOP_AXIS_DEF(0)
    `AURORA_TOP_AXIS_DEF(1)
    `AURORA_TOP_AXIS_DEF(2)
    `AURORA_TOP_AXIS_DEF(3)
    `AURORA_TOP_AXIS_DEF(4)
    `AURORA_TOP_AXIS_DEF(5)
    `AURORA_TOP_AXIS_DEF(6)
    `AURORA_TOP_AXIS_DEF(7)

    // AXI4-Lite slave interface
    input           s_axi_control_awvalid,
    output          s_axi_control_awready,
    input  [15:0]   s_axi_control_awaddr ,
    input           s_axi_control_wvalid ,
    output          s_axi_control_wready ,
    input  [31:0]   s_axi_control_wdata  ,
    input  [3:0]    s_axi_control_wstrb  ,
    input           s_axi_control_arvalid,
    output          s_axi_control_arready,
    input  [15:0]   s_axi_control_araddr ,
    output          s_axi_control_rvalid ,
    input           s_axi_control_rready ,
    output [31:0]   s_axi_control_rdata  ,
    output [1:0]    s_axi_control_rresp  ,
    output          s_axi_control_bvalid ,
    input           s_axi_control_bready ,
    output [1:0]    s_axi_control_bresp  , 

    // Transceiver signals -- quad 0
    input           gt0_refclk_p,
    input           gt0_refclk_n,
    input  [3:0]    gt0_rxp_in,
    input  [3:0]    gt0_rxn_in,
    output [3:0]    gt0_txp_out,
    output [3:0]    gt0_txn_out,
    
    // Transceiver signals -- quad 1
    input           gt1_refclk_p,
    input           gt1_refclk_n,
    input  [3:0]    gt1_rxp_in,
    input  [3:0]    gt1_rxn_in,
    output [3:0]    gt1_txp_out,
    output [3:0]    gt1_txn_out,

    // Init clock, used for the reset sequence; 
    input           init_clk
);

aurora_impl impl (
    `CONNECT(ap_clk),
    `AURORA_TOP_AXIS_CONNECT(0),
    `AURORA_TOP_AXIS_CONNECT(1),
    `AURORA_TOP_AXIS_CONNECT(2),
    `AURORA_TOP_AXIS_CONNECT(3),
    `AURORA_TOP_AXIS_CONNECT(4),
    `AURORA_TOP_AXIS_CONNECT(5),
    `AURORA_TOP_AXIS_CONNECT(6),
    `AURORA_TOP_AXIS_CONNECT(7),
    `CONNECT(s_axi_control_awvalid),
    `CONNECT(s_axi_control_awready),
    `CONNECT(s_axi_control_awaddr ),
    `CONNECT(s_axi_control_wvalid ),
    `CONNECT(s_axi_control_wready ),
    `CONNECT(s_axi_control_wdata  ),
    `CONNECT(s_axi_control_wstrb  ),
    `CONNECT(s_axi_control_arvalid),
    `CONNECT(s_axi_control_arready),
    `CONNECT(s_axi_control_araddr ),
    `CONNECT(s_axi_control_rvalid ),
    `CONNECT(s_axi_control_rready ),
    `CONNECT(s_axi_control_rdata  ),
    `CONNECT(s_axi_control_rresp  ),
    `CONNECT(s_axi_control_bvalid ),
    `CONNECT(s_axi_control_bready ),
    `CONNECT(s_axi_control_bresp  ), 
    `CONNECT(gt0_refclk_p),
    `CONNECT(gt0_refclk_n),
    `CONNECT(gt0_rxp_in),
    `CONNECT(gt0_rxn_in),
    `CONNECT(gt0_txp_out),
    `CONNECT(gt0_txn_out),
    `CONNECT(gt1_refclk_p),
    `CONNECT(gt1_refclk_n),
    `CONNECT(gt1_rxp_in),
    `CONNECT(gt1_rxn_in),
    `CONNECT(gt1_txp_out),
    `CONNECT(gt1_txn_out),
    `CONNECT(init_clk)
); 

endmodule
