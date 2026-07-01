/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

`include "axi_mem_types.vh"
`include "sip.vh"

module lotus #(
  parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 16 ,
  parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32
) (
  input clk, // Main clock

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

  output interrupt
);
    // SIP
    SIPFlit sReq;
    SIPFlit sResp;

    AxiLiteToSIP #(
        .S_AXI_ADDR_WIDTH(C_S_AXI_CONTROL_ADDR_WIDTH),
        .S_AXI_DATA_WIDTH(C_S_AXI_CONTROL_DATA_WIDTH),
        .AP_CTRL_HS      (0)
    ) sipInst (
        .clk(clk),

        `SIP_CONNECT_AXILITE(s_axi_control_),
        `SIP_TIE_OFF_AP_CTRL,
    
        // SIP interface (to slaves)
        .sReq(sReq),
        .sResp(sResp)
    );

    assign interrupt = 0; // FIXME: Do we need this?

    // Mem AXI Fire
    // This is because the inputs to bsv modules 
    // require that the EN be dependant on the RDY
    `MEM_AXI_FIRES

    // Mem AXI Destruct
    // Take output structures from bsv world and convert to wires
    // TODO: It would be better if we don't have to output a structure from bsv,
    //       but it would require some changes to the interface that isn't a priority right now
    `MEM_AXI_DESTRUCTS

    mkMultiTile multiTile (
        .CLK  (clk),

        `MEM_AXI_TILES

        `CROSS_DEVICE_AXIS_TILES

        .sip_req(sReq),
        .sip_resp(sResp)
    );

endmodule
