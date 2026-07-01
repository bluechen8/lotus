/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

`ifndef _SIP_VH_
`define _SIP_VH_

// SIP data type and interface
typedef struct packed {
    logic valid;
    logic [7:0] data;
} SIPFlit;

interface SIPIfc;
    SIPFlit req;
    SIPFlit resp;
    modport master(input req, output resp);
    modport slave(output req, input resp);
endinterface

// Connection helpers for AxiLiteToSIP
`define SIP_CONNECT_AXILITE(prefix) \
    .awaddr(``prefix``awaddr), \
    .awready(``prefix``awready), \
    .awvalid(``prefix``awvalid), \
    .wdata(``prefix``wdata), \
    .wstrb(``prefix``wstrb), \
    .wready(``prefix``wready), \
    .wvalid(``prefix``wvalid), \
    .bresp(``prefix``bresp), \
    .bready(``prefix``bready), \
    .bvalid(``prefix``bvalid), \
    .araddr(``prefix``araddr), \
    .arready(``prefix``arready), \
    .arvalid(``prefix``arvalid), \
    .rdata(``prefix``rdata), \
    .rresp(``prefix``rresp), \
    .rready(``prefix``rready), \
    .rvalid(``prefix``rvalid)
 
`define SIP_TIE_OFF_AP_CTRL \
    .interrupt(), \
    .ap_start(), \
    .ap_done(1'b0), \
    .ap_ready(1'b0), \
    .ap_idle(1'b0)

`endif // _SIP_VH_
