/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

/* Xilinx FPGA RAM primitives
 *
 * This file has modules that implement single- and dual-port memories that
 * Vivado maps to FPGA RAM primitives. The modules are designed to be simple
 * to use while exposing most of the feature set of Xilinx RAMs.
 *
 *  The following modules are available:
 * - XRAM1, XRAM2 are single- and dual-port RAMs
 * - XRAM1BE, XRAM2BE are variants with byte (sub-word) write-enables
 * - XRAM2Async, XRAM2BEAsync are asynchronous variants of the dual-port RAMs,
 *   where each port has a different clock
 *
 * All memories are configured with two mandatory parameters, ADDR_WIDTH and
 * DATA_WIDTH, which specify the RAM geometry. Reads are synchronous (clocked)
 * and always take one cycle. For large RAMs, the output may need to be
 * pipelined to achieve high frequency. There is no write-read bypassing.
 *
 * IMPORTANT: In dual-port RAMs, double-writes to the same address from both
 * ports *will* result in undefined data being written, and a read and a write
 * to the same address in both ports *may* result in an undefined read value
 * (this said, Vivado is supposed to emit an INFO when this is possible, and
 * I have not seen it in tests). This can introduce divergence between
 * simulation and synthesis. If collisions are possible, making the port doing
 * the writes READ_FIRST will cause a colliding read in the *other* port to get
 * the old value (see UG573, Address Collision); if you want the new value,
 * use WRITE_FIRST and add logic to, on a collision, grab the output from the
 * writing port's dout.
 *
 * While LUTRAM (aka RAMD or distributed RAM) is supported, the feature set
 * of these modules mainly targets BRAM and URAM. LUTRAM has other features
 * (up to one write port, multiple read ports, asynchronous/same-cycle reads)
 * that are not targeted here.
 *
 * In addition to the mandatory parameters, the following optional parameters
 * are available:
 *
 * - MODE (or MODEA/MODEB in dual-port variants) control write behavior:
 *   + XRAM_MODE_NO_CHANGE (default): Writes don't update dout
 *   + XRAM_MODE_WRITE_FIRST: Writes set dout to the written value
 *     (in BE variants, this is a mix of updated and old values)
 *   + XRAM_MODE_READ_FIRST: Writes read old value into dout
 *   + XRAM_MODE_{READ/WRITE}_ONLY: Only for 2-port variants, restrict the
 *     port to do only writes (not reading when wEn = 0) or only reads (never
 *     writing, even if wEn != 0). This is useful to produce memories in simple
 *     dual-port mode (SDP), which have some advantages over true dual port
 *     (TDP) memories, e.g., allowing 2x wider ports. Note that this does not
 *     change the interface: en/we signals still exist in these modes.
 *
 * - INITIAL_VALUE (default 0): Initial value for each RAM word and output
 *   register.
 *
 * - STYLE controls the type of memory synthesized. This can be any value
 *   passed to the ram_style pragma, including:
 *   + "auto" (default): Infer the memory technology depending on size
 *     (LUTRAM for small memories, BRAM for mid-size, URAM for large)
 *   + "block": Use BRAM (Block RAM)
 *   + "ultra": Use URAM (Ultra RAM)
 *   + "distributed": Use LUTRAM (RAMD)
 *   + "mixed": Mix-and-match different memory types
 *
 * - READ_LATENCY is the number of cycles that reads take. This is 1 by
 *   default, cannot be 0, and values > 1 internally instantiate a read
 *   pipeline that, for URAMs, should reliably infer to a URAM pipe.
 *
 * - NUM_WORDS (default 2 ** ADDR_WIDTH): Number of memory words. This must
 *   always be between (2 ** (ADDR_WIDTH-1) + 1) and (2 ** ADDR_WIDTH), i.e.,
 *   the value must be indexable with ADDR_WIDTH bits. It may be useful if
 *   you want a memory that has slightly more entries than a power of 2, and
 *   use "mixed" style to achieve it cheaply.
 *
 * - In BE variants, CHUNK_SIZE (default 8) determines the size of each
 *   sub-word write enable. This value must divide DATA_WIDTH. To be
 *   efficient, it should be 8, 9, or a multiple of those, but any value will
 *   work.
 *
 * - In XRAM2 and XRAM2Async (but not on the BE variants), ports A and B can
 *   have different geometries. LOG_RATIOB (default 0) controls this: port B
 *   is 2 ** LOG_RATIOB wider than port A. This can be useful to e.g.
 *   implement tag arrays (read a whole set, write one tag), or to implement
 *   serializing/deserializing memories.
 *
 * URAM restrictions: BRAMs will support the whole feature set, but URAMs
 * have restrictions that make the following features unsupported (see UG573,
 * https://docs.xilinx.com/v/u/en-US/ug573-ultrascale-memory-resources):
 * - Async variants (URAM has a single clock)
 * - Write MODE other than NO_CHANGE (though with a single port, using
 *   READ_FIRST or WRITE_FIRST will work by using both ports)
 * - Nonzero INITIAL_VALUE (URAMs are always initialized to 0)
 * - LOG_RATIOB != 0 in dual-port variants (asymmetric ports not supported)
 * If you use any of these features, Vivado will fall back to BRAM even if you
 * specify STYLE = "ultra".
 *
 * TESTING: These modules have been tested to produce the expected RAM
 * primitives on Vivado 2022.2 on a wide range of parameter combinations.
 * See test_xram.py.
 */

`timescale 1ps/1ps

// Access mode definitions (keep in sync with BSV enum definitions)
typedef enum logic [2:0] {
    XRAM_MODE_NO_CHANGE = 0,
    XRAM_MODE_WRITE_FIRST = 1,
    XRAM_MODE_READ_FIRST = 2,
    XRAM_MODE_WRITE_ONLY = 3,
    XRAM_MODE_READ_ONLY = 4
} XRAMMode;

// This is reused across XRAM variants, but you can't make it a module... that
// makes Vivado occasionally not flatten it into the xram and fails to infer
// an URAM pipeline. So a macro it is! Jeeeez.
`define XRAM_PORT_OUTPUT(clk, en, dout_r, dout) \
generate \
if (READ_LATENCY == 1) begin \
    assign dout = dout_r; \
end else if (READ_LATENCY > 1) begin : piped_``dout \
    reg [DATA_WIDTH-1: 0] data_pipe[READ_LATENCY-2:0]; \
    reg en_pipe[READ_LATENCY-2:0]; \
    initial begin \
        for (integer i = 0; i < READ_LATENCY-1; i = i + 1) begin \
            en_pipe[i] = 0; \
        end \
    end \
    always @(posedge clk) begin \
        en_pipe[0] <= en; \
        if (en_pipe[0]) data_pipe[0] <= dout_r; \
    end \
    for (genvar i = 1 ; i < READ_LATENCY-1; i = i+1) begin \
        always @(posedge clk) begin \
            en_pipe[i] <= en_pipe[i-1]; \
            if (en_pipe[i]) data_pipe[i] <= data_pipe[i-1]; \
        end \
    end \
    assign dout = data_pipe[READ_LATENCY-2]; \
end else $error("Invalid READ_LATENCY specified (must be >= 1)"); \
endgenerate

// Single-ported {LUT,B,U}RAM in all possible modes
module XRAM1 #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 1,

    // Optional
    parameter MODE = XRAM_MODE_NO_CHANGE,
    parameter INITIAL_VALUE = 0,
    parameter READ_LATENCY = 1,
    parameter STYLE = "auto",
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clk,
    input en,
    input we,
    input [ADDR_WIDTH-1:0] addr,
    input [DATA_WIDTH-1:0] din,
    output [DATA_WIDTH-1:0] dout
);

(* RAM_STYLE = STYLE *)
reg [DATA_WIDTH-1:0] ram [0:NUM_WORDS-1];
reg [DATA_WIDTH-1:0] dout_r;

initial begin : init_block
    for (integer i = 0; i < NUM_WORDS; i = i + 1) begin
        ram[i] = INITIAL_VALUE;
    end
    dout_r = INITIAL_VALUE;
end

// Writes
always @(posedge clk) begin
    if (en && we) begin
        ram[addr] <= din;
    end
end

// Reads
generate
    if (MODE == XRAM_MODE_NO_CHANGE) begin
        always @(posedge clk) begin
            if (en && !we) begin
                dout_r <= ram[addr];
            end
        end
    end else if (MODE == XRAM_MODE_WRITE_FIRST) begin
        always @(posedge clk) begin
            if (en) begin
                dout_r <= we ? din : ram[addr];
            end
        end
    end else if (MODE == XRAM_MODE_READ_FIRST) begin
        always @(posedge clk) begin
            if (en) begin
                dout_r <= ram[addr];
            end
        end
    end else $error("Invalid MODE specified (1-port memories can't be READ_ONLY or WRITE_ONLY)");
endgenerate

// Output driver
`XRAM_PORT_OUTPUT(clk, en, dout_r, dout)

endmodule // XRAM1

// Single-port RAM with byte-enables
module XRAM1BE #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 16,

    // Optional
    parameter MODE = XRAM_MODE_NO_CHANGE,
    parameter INITIAL_VALUE = 0,
    parameter READ_LATENCY = 1,
    parameter STYLE = "auto",
    parameter CHUNK_SIZE = 8,
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clk,
    input en,
    input [(DATA_WIDTH/CHUNK_SIZE)-1:0] we,
    input [ADDR_WIDTH-1:0] addr,
    input [DATA_WIDTH-1:0] din,
    output [DATA_WIDTH-1:0] dout
);

(* RAM_STYLE = STYLE *)
reg [DATA_WIDTH-1:0] ram [0:NUM_WORDS-1];
reg [DATA_WIDTH-1:0] dout_r;

initial begin : init_block
    for (integer i = 0; i < NUM_WORDS; i = i + 1) begin
        ram[i] = INITIAL_VALUE;
    end
    dout_r = INITIAL_VALUE;
end

localparam WE_WIDTH = DATA_WIDTH / CHUNK_SIZE;

// Follows Xilinx templates: https://docs.xilinx.com/r/en-US/ug901-vivado-synthesis/Byte-Write-Enable-True-Dual-Port-with-Byte-Wide-Write-Enable-Verilog
generate
    genvar i;
    // Writes
    for (i = 0; i < WE_WIDTH; i = i + 1) begin: port_we
        always @(posedge clk) begin
            if (en && we[i]) begin
                ram[addr][((i+1)*CHUNK_SIZE)-1 : i*CHUNK_SIZE] <= din[((i+1)*CHUNK_SIZE)-1 : i*CHUNK_SIZE];
            end
        end
    end

    // Reads
    if (MODE == XRAM_MODE_NO_CHANGE) begin
        always @(posedge clk) begin
            if (en && ~|we) begin
                dout_r <= ram[addr];
            end
        end
    end else if (MODE == XRAM_MODE_WRITE_FIRST) begin
        for(i = 0; i < WE_WIDTH; i = i + 1) begin: port_wf_rd
            always @(posedge clk) begin
                if (en) begin
                    if (we[i]) begin
                        dout_r[((i+1)*CHUNK_SIZE)-1 : i*CHUNK_SIZE] <= din[((i+1)*CHUNK_SIZE)-1 : i*CHUNK_SIZE];
                    end
                    else begin
                        dout_r[((i+1)*CHUNK_SIZE)-1 : i*CHUNK_SIZE] <= ram[addr][((i+1)*CHUNK_SIZE)-1 : i*CHUNK_SIZE];
                    end
                end
            end
        end
    end else if (MODE == XRAM_MODE_READ_FIRST) begin
        always @(posedge clk) begin
            if (en) begin
                dout_r <= ram[addr];
            end
        end
    end else $error("Invalid MODE specified (1-port memories can't be READ_ONLY or WRITE_ONLY)");
endgenerate

// Output driver
`XRAM_PORT_OUTPUT(clk, en, dout_r, dout)

endmodule // XRAM1BE


// Dual-port RAM; note that ports A and B can have different access modes and
// geometries. Port A is the narrowest. Port B can be 2x, 4x, etc. wider,
// determined by the LOG_RATIOB parameter (e.g., 3 means 8x wider).
//
// NOTE(dsm): In principle, each port even allows reads and writes to have
// different widths (see UG573). If you need this, code it manually...
//
// NOTE(dsm): This class uses BLOCKING (=) assignments for all ram and doutA/B
// assignments in always blocks, rather than non-blocking ones (<=). This is
// because with asymmetric read and write ports, Vivado will only infer
// WRITE_FIRST using blocking assignments. This means that assignment order
// matters and all assignments to the same variable should happen in the same
// always block and clock domain.
//
// However, Verilator misbehaves with blocking assignments, so we use
// non-blocking ones for Verilator, and use a different implementation for
// WRITE_FIRST. This is not ideal because it introduces the chance for bugs
// due to diverging implementations (e.g., things working on Verilator but not
// on the FPGA). We should see if there's some combination of blocking and
// non-blocking assignments that would make both Verilator and Vivado happy.
`ifdef VERILATOR
    `define XRAM_ASSIGN(lhs, rhs) lhs <= rhs
`else
    `define XRAM_ASSIGN(lhs, rhs) lhs = rhs
`endif

module XRAM2Async #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 1,

    // Optional
    parameter MODEA = XRAM_MODE_NO_CHANGE,
    parameter MODEB = XRAM_MODE_NO_CHANGE,
    parameter INITIAL_VALUE = 0,
    parameter READ_LATENCY = 1,
    parameter STYLE = "auto",
    parameter LOG_RATIOB = 0,
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clkA,
    input enA,
    input weA,
    input [ADDR_WIDTH-1:0] addrA,
    input [DATA_WIDTH-1:0] dinA,
    output [DATA_WIDTH-1:0] doutA,

    input clkB,
    input enB,
    input weB,
    input [ADDR_WIDTH-LOG_RATIOB-1:0] addrB,
    input [(DATA_WIDTH*(2 ** LOG_RATIOB))-1:0] dinB,
    output [(DATA_WIDTH*(2 ** LOG_RATIOB))-1:0] doutB
);

(* RAM_STYLE = STYLE *)
reg [DATA_WIDTH-1:0] ram [0:NUM_WORDS-1];

reg [DATA_WIDTH-1:0] doutA_r;

localparam RATIOB = 2 ** LOG_RATIOB;
localparam DATA_WIDTHB = DATA_WIDTH*RATIOB;
reg [DATA_WIDTHB-1:0] doutB_r;

initial begin : init_block
    for (integer i = 0; i < NUM_WORDS; i = i + 1) begin
        ram[i] = INITIAL_VALUE;
    end
    doutA_r = INITIAL_VALUE;
    for (integer i = 0; i < RATIOB; i = i + 1) begin
        doutB_r[(i+1)*DATA_WIDTH -1 -: DATA_WIDTH] = INITIAL_VALUE;
    end
end


//// Port A
generate
    if (MODEA == XRAM_MODE_NO_CHANGE) begin
        always @(posedge clkA) begin
            if (enA) begin
                if (weA) `XRAM_ASSIGN(ram[addrA], dinA;)
                else `XRAM_ASSIGN(doutA_r, ram[addrA];)
            end
        end
    end else if (MODEA == XRAM_MODE_WRITE_FIRST) begin
        always @(posedge clkA) begin
            if (enA) begin
`ifdef VERILATOR
                if (weA) begin
                    ram[addrA] <= dinA;
                    doutA_r <= dinA;
                end else begin
                    doutA_r <= ram[addrA];
                end
`else
                if (weA) ram[addrA] = dinA;
                doutA_r = ram[addrA];
`endif
            end
        end
    end else if (MODEA == XRAM_MODE_READ_FIRST) begin
        always @(posedge clkA) begin
            if (enA) begin
                `XRAM_ASSIGN(doutA_r, ram[addrA];)
                if (weA) `XRAM_ASSIGN(ram[addrA], dinA;)
            end
        end
    end else if (MODEA == XRAM_MODE_WRITE_ONLY) begin
        always @(posedge clkA) begin
            if (enA) begin
                if (weA) `XRAM_ASSIGN(ram[addrA], dinA;)
            end
        end
    end else if (MODEA == XRAM_MODE_READ_ONLY) begin
        always @(posedge clkA) begin
            if (enA) begin
                `XRAM_ASSIGN(doutA_r, ram[addrA];)
            end
        end
    end else $error("Invalid MODEA specified");
endgenerate

//// Port B

// To get the LOG_RATIO =0 and >0 cases working in one shot, we need some
// chicanery: Verilog doesn't support 0-bit variables, and Vivado doesn't
// recognize patterns other than concatenation to infer asymmetric BRAM ports
// (e.g., (ADDR_WIDTH'(ADDRB) * RATIOB)  + ADDR_WIDTH'(i) doesn't work;
// neither does "<< LOG_RATIOB" or "| i").
// The trick is that we can repeat a value 0 times, then concatenate it. The
// PLR (positive LOG_RATIOB) and BLR (bounded LOG_RATIOB) params below enable
// this: {PLR{BLR'{i}}} is a 0-bit value when LOG_RATIOB == 0, or
// LOG_RATIOB'(i) when LOG_RATIOB > 0.
localparam PLR = (LOG_RATIOB > 0)? 1 : 0;
localparam BLR = (LOG_RATIOB > 0)? LOG_RATIOB : 1;

generate
    if (MODEB == XRAM_MODE_NO_CHANGE) begin
        // dsm: Given the READ_FIRST and WRITE_FIRST code below, you'd think
        // that "if (weB) ram[...] = ...; else doutB_r[...] = ...;" would work.
        // But nope! The only way I've found to coax Vivado (2022.2) to infer
        // a port here is to use two separate always blocks, for writes and
        // reads. Which is bad design given the blocking assignments, but in
        // practice they use exclusive conditions... Vivado, why so picky?

        always @(posedge clkB) begin
            if (enB && weB) begin
                for (integer i = 0; i < RATIOB; i = i + 1) begin
                    automatic reg [ADDR_WIDTH-1:0] addr = {addrB, {PLR{BLR'(i)}}};
                    `XRAM_ASSIGN(ram[addr], dinB[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH]);
                end
            end
        end
        always @(posedge clkB) begin
            if (enB && !weB) begin
                for (integer i = 0; i < RATIOB; i = i + 1) begin
                    automatic reg [ADDR_WIDTH-1:0] addr = {addrB, {PLR{BLR'(i)}}};
                    `XRAM_ASSIGN(doutB_r[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH], ram[addr]);
                end
            end
        end
    end else if (MODEB == XRAM_MODE_WRITE_FIRST) begin
        always @(posedge clkB) begin
            if (enB) begin
                for (integer i = 0; i < RATIOB; i = i + 1) begin
                    automatic reg [ADDR_WIDTH-1:0] addr = {addrB, {PLR{BLR'(i)}}};
`ifdef VERILATOR
                    if (weB) begin
                        ram[addr] <= dinB[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
                        doutB_r[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] <= dinB[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
                    end else begin
                        doutB_r[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] <= ram[addr];
                    end
`else
                    if (weB) ram[addr] = dinB[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
                    doutB_r[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] = ram[addr];
`endif
                end
            end
        end
    end else if (MODEB == XRAM_MODE_READ_FIRST) begin
        always @(posedge clkB) begin
            if (enB) begin
                for (integer i = 0; i < RATIOB; i = i + 1) begin
                    automatic reg [ADDR_WIDTH-1:0] addr = {addrB, {PLR{BLR'(i)}}};
                    `XRAM_ASSIGN(doutB_r[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH], ram[addr]);
                    if (weB) `XRAM_ASSIGN(ram[addr], dinB[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH]);
                end
            end
        end
    end else if (MODEB == XRAM_MODE_WRITE_ONLY) begin
        always @(posedge clkB) begin
            if (enB) begin
                for (integer i = 0; i < RATIOB; i = i + 1) begin
                    automatic reg [ADDR_WIDTH-1:0] addr = {addrB, {PLR{BLR'(i)}}};
                    if (weB) `XRAM_ASSIGN(ram[addr], dinB[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH]);
                end
            end
        end
    end else if (MODEB == XRAM_MODE_READ_ONLY) begin
        always @(posedge clkB) begin
            if (enB) begin
                for (integer i = 0; i < RATIOB; i = i + 1) begin
                    automatic reg [ADDR_WIDTH-1:0] addr = {addrB, {PLR{BLR'(i)}}};
                    `XRAM_ASSIGN(doutB_r[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH], ram[addr]);
                end
            end
        end
    end else $error("Invalid MODEB specified");
endgenerate

// Output drivers
`XRAM_PORT_OUTPUT(clkA, enA, doutA_r, doutA)
`XRAM_PORT_OUTPUT(clkB, enB, doutB_r, doutB)

endmodule // XRAM2Async


// Synchronous (single-clock) variant
module XRAM2 #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 1,

    // Optional
    parameter MODEA = XRAM_MODE_NO_CHANGE,
    parameter MODEB = XRAM_MODE_NO_CHANGE,
    parameter INITIAL_VALUE = 0,
    parameter READ_LATENCY = 1,
    parameter STYLE = "auto",
    parameter LOG_RATIOB = 0,
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clk,

    input enA,
    input weA,
    input [ADDR_WIDTH-1:0] addrA,
    input [DATA_WIDTH-1:0] dinA,
    output [DATA_WIDTH-1:0] doutA,

    input enB,
    input weB,
    input [ADDR_WIDTH-LOG_RATIOB-1:0] addrB,
    input [(DATA_WIDTH*(2 ** LOG_RATIOB))-1:0] dinB,
    output [(DATA_WIDTH*(2 ** LOG_RATIOB))-1:0] doutB
);

XRAM2Async #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .MODEA(MODEA),
    .MODEB(MODEB),
    .INITIAL_VALUE(INITIAL_VALUE),
    .READ_LATENCY(READ_LATENCY),
    .STYLE(STYLE),
    .LOG_RATIOB(LOG_RATIOB),
    .NUM_WORDS(NUM_WORDS)
) xram2 (
    .clkA(clk),
    .clkB(clk),

    .enA(enA),
    .weA(weA),
    .addrA(addrA),
    .dinA(dinA),
    .doutA(doutA),

    .enB(enB),
    .weB(weB),
    .addrB(addrB),
    .dinB(dinB),
    .doutB(doutB)
);

endmodule // XRAM2


// Dual-port RAM with byte-enables
//
// NOTE(dsm): Unlike XRAM2, this memory is not asymmetric: both ports have the
// same dimensions. This is because, as far as I can see, you can't have two
// asymmetric ports with byte enables; Xilinx does not give out templates for
// this case, and in the Xilinx-provided xpm_memory.sv (at least in 2022.2),
// byte-enables are only allowed in the narrowest port. Similarly, the most
// I can get through trial and error is byte enables on the narrow port, but
// no byte enables on the wide one.
//
// If you ever need this asymmetric + BE corner case, it's possible to create
// a different XRAM variant, but it doesn't seem very useful...
module XRAM2BEAsync #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 16,

    // Optional
    parameter MODEA = XRAM_MODE_NO_CHANGE,
    parameter MODEB = XRAM_MODE_NO_CHANGE,
    parameter INITIAL_VALUE = 0,
    parameter READ_LATENCY = 1,
    parameter STYLE = "auto",
    parameter CHUNK_SIZE = 8,
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clkA,
    input enA,
    input [(DATA_WIDTH/CHUNK_SIZE)-1:0] weA,
    input [ADDR_WIDTH-1:0] addrA,
    input [DATA_WIDTH-1:0] dinA,
    output [DATA_WIDTH-1:0] doutA,

    input clkB,
    input enB,
    input [(DATA_WIDTH/CHUNK_SIZE)-1:0] weB,
    input [ADDR_WIDTH-1:0] addrB,
    input [DATA_WIDTH-1:0] dinB,
    output [DATA_WIDTH-1:0] doutB
);

(* RAM_STYLE = STYLE *)
reg [DATA_WIDTH-1:0] ram [0:NUM_WORDS-1];

reg [DATA_WIDTH-1:0] doutA_r;
reg [DATA_WIDTH-1:0] doutB_r;

initial begin : init_block
    for (integer i = 0; i < NUM_WORDS; i = i + 1) begin
        ram[i] = INITIAL_VALUE;
    end
    doutA_r = INITIAL_VALUE;
    doutB_r = INITIAL_VALUE;
end

localparam WE_WIDTH = DATA_WIDTH / CHUNK_SIZE;

//// Port A
generate
    if (MODEA == XRAM_MODE_NO_CHANGE) begin
        always @(posedge clkA) begin
            if (enA) begin
                if (~|weA) `XRAM_ASSIGN(doutA_r, ram[addrA]);
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portA_nc
                    if (weA[i]) `XRAM_ASSIGN(ram[addrA][i*CHUNK_SIZE +:CHUNK_SIZE], dinA[i*CHUNK_SIZE +: CHUNK_SIZE]);
                end
            end
        end
    end else if (MODEA == XRAM_MODE_WRITE_FIRST) begin
        always @(posedge clkA) begin
            if (enA) begin
`ifdef VERILATOR
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portA_wf
                    if (weA[i]) begin
                        ram[addrA][i*CHUNK_SIZE +: CHUNK_SIZE] <= dinA[i*CHUNK_SIZE +: CHUNK_SIZE];
                        doutA_r[i*CHUNK_SIZE +: CHUNK_SIZE] <= dinA[i*CHUNK_SIZE +: CHUNK_SIZE];
                    end else begin
                        doutA_r[i*CHUNK_SIZE +: CHUNK_SIZE] <= ram[addrA][i*CHUNK_SIZE +: CHUNK_SIZE];
                    end
                end
`else
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portA_wf
                    if (weA[i]) ram[addrA][i*CHUNK_SIZE +: CHUNK_SIZE] = dinA[i*CHUNK_SIZE +: CHUNK_SIZE];
                end
                doutA_r = ram[addrA]; 
`endif
            end
        end
    end else if (MODEA == XRAM_MODE_READ_FIRST) begin
        always @(posedge clkA) begin
            if (enA) begin
                `XRAM_ASSIGN(doutA_r, ram[addrA]);
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portA_rf
                    if (weA[i]) `XRAM_ASSIGN(ram[addrA][i*CHUNK_SIZE +:CHUNK_SIZE], dinA[i*CHUNK_SIZE +: CHUNK_SIZE]);
                end
            end
        end
    end else if (MODEA == XRAM_MODE_WRITE_ONLY) begin
        always @(posedge clkA) begin
            if (enA) begin
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portA_wo
                    if (weA[i]) `XRAM_ASSIGN(ram[addrA][i*CHUNK_SIZE +:CHUNK_SIZE], dinA[i*CHUNK_SIZE +: CHUNK_SIZE]);
                end
            end
        end
    end else if (MODEA == XRAM_MODE_READ_ONLY) begin
        always @(posedge clkA) begin
            if (enA) begin
                `XRAM_ASSIGN(doutA_r, ram[addrA]);
            end
        end
    end else $error("Invalid MODEA specified");
endgenerate

//// Port B
generate
    if (MODEB == XRAM_MODE_NO_CHANGE) begin
        always @(posedge clkB) begin
            if (enB) begin
                if (~|weB) `XRAM_ASSIGN(doutB_r, ram[addrB]);
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portB_nc
                    if (weB[i]) `XRAM_ASSIGN(ram[addrB][i*CHUNK_SIZE +: CHUNK_SIZE], dinB[i*CHUNK_SIZE +: CHUNK_SIZE]);
                end
            end
        end
    end else if (MODEB == XRAM_MODE_WRITE_FIRST) begin
        always @(posedge clkB) begin
            if (enB) begin
`ifdef VERILATOR
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portB_wf
                    if (weB[i]) begin
                        ram[addrB][i*CHUNK_SIZE +: CHUNK_SIZE] <= dinB[i*CHUNK_SIZE +: CHUNK_SIZE];
                        doutB_r[i*CHUNK_SIZE +: CHUNK_SIZE] <= dinB[i*CHUNK_SIZE +: CHUNK_SIZE];
                    end else begin
                        doutB_r[i*CHUNK_SIZE +: CHUNK_SIZE] <= ram[addrB][i*CHUNK_SIZE +: CHUNK_SIZE];
                    end
                end
`else
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portB_wf
                    if (weB[i]) ram[addrB][i*CHUNK_SIZE +: CHUNK_SIZE] = dinB[i*CHUNK_SIZE +: CHUNK_SIZE];
                end
                doutB_r = ram[addrB]; 
`endif
            end
        end
    end else if (MODEB == XRAM_MODE_READ_FIRST) begin
        always @(posedge clkB) begin
            if (enB) begin
                `XRAM_ASSIGN(doutB_r, ram[addrB]);
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portB_rf
                    if (weB[i]) `XRAM_ASSIGN(ram[addrB][i*CHUNK_SIZE +: CHUNK_SIZE], dinB[i*CHUNK_SIZE +: CHUNK_SIZE]);
                end
            end
        end
    end else if (MODEB == XRAM_MODE_WRITE_ONLY) begin
        always @(posedge clkB) begin
            if (enB) begin
                for (integer i = 0; i < WE_WIDTH; i = i + 1) begin: portB_wo
                    if (weB[i]) `XRAM_ASSIGN(ram[addrB][i*CHUNK_SIZE +: CHUNK_SIZE], dinB[i*CHUNK_SIZE +: CHUNK_SIZE]);
                end
            end
        end
    end else if (MODEB == XRAM_MODE_READ_ONLY) begin
        always @(posedge clkB) begin
            if (enB) begin
                `XRAM_ASSIGN(doutB_r, ram[addrB]);
            end
        end
    end else $error("Invalid MODEB specified");
endgenerate

// Output drivers
`XRAM_PORT_OUTPUT(clkA, enA, doutA_r, doutA)
`XRAM_PORT_OUTPUT(clkB, enB, doutB_r, doutB)

endmodule // XRAM2BEAsync

// Synchronous (single-clock) variant
module XRAM2BE #(
    parameter ADDR_WIDTH = 1,
    parameter DATA_WIDTH = 16,

    // Optional
    parameter MODEA = XRAM_MODE_NO_CHANGE,
    parameter MODEB = XRAM_MODE_NO_CHANGE,
    parameter INITIAL_VALUE = 0,
    parameter READ_LATENCY = 1,
    parameter STYLE = "auto",
    parameter CHUNK_SIZE = 8,
    parameter NUM_WORDS = 2 ** ADDR_WIDTH
) (
    input clk,

    input enA,
    input [(DATA_WIDTH/CHUNK_SIZE)-1:0] weA,
    input [ADDR_WIDTH-1:0] addrA,
    input [DATA_WIDTH-1:0] dinA,
    output [DATA_WIDTH-1:0] doutA,

    input enB,
    input [(DATA_WIDTH/CHUNK_SIZE)-1:0] weB,
    input [ADDR_WIDTH-1:0] addrB,
    input [DATA_WIDTH-1:0] dinB,
    output [DATA_WIDTH-1:0] doutB
);

XRAM2BEAsync #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .MODEA(MODEA),
    .MODEB(MODEB),
    .INITIAL_VALUE(INITIAL_VALUE),
    .READ_LATENCY(READ_LATENCY),
    .STYLE(STYLE),
    .CHUNK_SIZE(CHUNK_SIZE),
    .NUM_WORDS(NUM_WORDS)
) xram2be (
    .clkA(clk),
    .clkB(clk),

    .enA(enA),
    .weA(weA),
    .addrA(addrA),
    .dinA(dinA),
    .doutA(doutA),

    .enB(enB),
    .weB(weB),
    .addrB(addrB),
    .dinB(dinB),
    .doutB(doutB)
);

endmodule

`undef XRAM_PORT_OUTPUT
`undef XRAM_ASSIGN
