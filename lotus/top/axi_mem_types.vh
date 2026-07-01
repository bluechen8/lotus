/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

`ifndef AXI_MEM_TYPES_VH
`define AXI_MEM_TYPES_VH

typedef logic [`MEM_AXI_ID_WIDTH-1:0]       AxiMemBus_id_t;
   typedef logic [`MEM_AXI_ADDR_WIDTH-1:0]     AxiMemBus_addr_t;
   typedef logic [(`MEM_AXI_DATA_WIDTH/8)-1:0] AxiMemBus_strb_t;
   typedef logic [`MEM_AXI_DATA_WIDTH-1:0]     AxiMemBus_data_t;
   typedef logic [7:0]                       AxiMemBus_len_t;
   typedef logic [2:0]                       AxiMemBus_size_t;
   typedef logic [1:0]                       AxiMemBus_resp_t;

    // Mem structs
    typedef struct packed {
        AxiMemBus_addr_t addr;
        AxiMemBus_id_t   id;
        AxiMemBus_len_t  len;
    } AxiMemAW_t;
    typedef struct packed {
        AxiMemBus_data_t data;
        AxiMemBus_strb_t strb; 
        logic            last;
        AxiMemBus_id_t   id;
    } AxiMemW_t;
    typedef struct packed {
        AxiMemBus_id_t       id;
        AxiMemBus_resp_t     resp;
    } AxiMemB_t;
    typedef struct packed {
        AxiMemBus_addr_t addr;
        AxiMemBus_id_t   id;
        AxiMemBus_len_t  len;
    } AxiMemAR_t;
    typedef struct packed {
        AxiMemBus_data_t data;
        logic            last;
        AxiMemBus_id_t   id;
        AxiMemBus_resp_t resp;

    } AxiMemR_t;

    `define AxiMemAWDbgPrint(aw) $write("reqType=AW id=0x%0h addr=0x%0h len=%0d" , aw.id, aw.addr, aw.len)
    `define AxiMemARDbgPrint(ar) $write("reqType=AR id=0x%0h addr=0x%0h len=%0d" , ar.id, ar.addr, ar.len)
    `define AxiMemRDbgPrint(r)    $write("reqType=R id=0x%0h data=0x%0h last=%0d",  r.id,  r.data,  r.last)
    `define AxiMemWDbgPrint(w)    $write("reqType=W id=0x%0h data=0x%0h strb=0x%0h last=%0d",  w.id,  w.data,  w.strb,  w.last)
    `define AxiMemBDbgPrint(b)    $write("reqType=B id=0x%0h resp=%0d"                    ,  b.id,  b.resp)

    `define AxiMemDbgPrint_(clk, axiMemBus, axiMemBusp, initArgs) \
        wire AxiMemAW_t ___aw_``axiMemBusp = axiMemBus.aw; \
        wire AxiMemAR_t ___ar_``axiMemBusp = axiMemBus.ar; \
        wire AxiMemR_t  ___r_``axiMemBusp = axiMemBus.r; \
        wire AxiMemW_t  ___w_``axiMemBusp = axiMemBus.w; \
        wire AxiMemB_t  ___b_``axiMemBusp = axiMemBus.b; \
        always @(posedge clk) begin \
            if (axiMemBus.awvalid && axiMemBus.awready) begin \
                $write initArgs; \
                `AxiMemAWDbgPrint(___aw_``axiMemBusp); \
                $write("\n"); \
            end \
            if (axiMemBus.arvalid && axiMemBus.arready) begin \
                $write initArgs; \
                `AxiMemARDbgPrint(___ar_``axiMemBusp); \
                $write("\n"); \
            end \
            if (axiMemBus.rvalid && axiMemBus.rready) begin \
                $write initArgs; \
                `AxiMemRDbgPrint(___r_``axiMemBusp); \
                $write("\n"); \
            end \
            if (axiMemBus.wvalid && axiMemBus.wready) begin \
                $write initArgs; \
                `AxiMemWDbgPrint(___w_``axiMemBusp); \
                $write("\n"); \
            end \
            if (axiMemBus.bvalid && axiMemBus.bready) begin \
                $write initArgs; \
                `AxiMemBDbgPrint(___b_``axiMemBusp); \
                $write("\n"); \
            end \
        end

    `define AxiMemDbgPrint(clk, axiMemBus, initArgs) `AxiMemDbgPrint_(clk, axiMemBus, axiMemBus, initArgs)

    `define AxiMemBus_t_sized(NVAL) AxiBus_t #(.AW(AxiMemAW_t), .W(AxiMemW_t), .B(AxiMemB_t), .AR(AxiMemAR_t), .R(AxiMemR_t), .N(NVAL))

    `define AxiMemBus_t `AxiMemBus_t_sized(1)

    `define PrintIfDbgPrint(clk, print_if, initArgs)    \
        always @(posedge clk) begin                     \
            if (print_if.valid && print_if.ready) begin \
                $write initArgs;                     \
                $write("char=%c decimal=%0d\n", print_if.data, print_if.data);  \
            end                                         \
        end


`endif // AXI_MEM_TYPES_VH
