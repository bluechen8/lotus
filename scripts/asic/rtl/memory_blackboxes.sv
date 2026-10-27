// Opaque logical SRAM boundaries for area-only synthesis.
// No storage, timing model, initialization, or physical macro allocation.
(* blackbox *)
module XRAM1 #(parameter ADDR_WIDTH=1, DATA_WIDTH=1, MODE=0,
 INITIAL_VALUE=0, READ_LATENCY=1, STYLE="auto", NUM_WORDS=2**ADDR_WIDTH)(
 input clk, en, we, input [ADDR_WIDTH-1:0] addr,
 input [DATA_WIDTH-1:0] din, output [DATA_WIDTH-1:0] dout);
endmodule

(* blackbox *)
module XRAM2 #(parameter ADDR_WIDTH=1, DATA_WIDTH=1, MODEA=0, MODEB=0,
 INITIAL_VALUE=0, READ_LATENCY=1, STYLE="auto", LOG_RATIOB=0,
 NUM_WORDS=2**ADDR_WIDTH)(
 input clk, enA, weA, input [ADDR_WIDTH-1:0] addrA,
 input [DATA_WIDTH-1:0] dinA, output [DATA_WIDTH-1:0] doutA,
 input enB,weB, input [ADDR_WIDTH-LOG_RATIOB-1:0] addrB,
 input [DATA_WIDTH*(2**LOG_RATIOB)-1:0] dinB,
 output [DATA_WIDTH*(2**LOG_RATIOB)-1:0] doutB);
endmodule

(* blackbox *)
module XRAM2BE #(parameter ADDR_WIDTH=1, DATA_WIDTH=16, MODEA=0, MODEB=0,
 INITIAL_VALUE=0, READ_LATENCY=1, STYLE="auto", CHUNK_SIZE=8,
 NUM_WORDS=2**ADDR_WIDTH)(
 input clk, enA, input [DATA_WIDTH/CHUNK_SIZE-1:0] weA,
 input [ADDR_WIDTH-1:0] addrA, input [DATA_WIDTH-1:0] dinA,
 output [DATA_WIDTH-1:0] doutA,
 input enB, input [DATA_WIDTH/CHUNK_SIZE-1:0] weB,
 input [ADDR_WIDTH-1:0] addrB, input [DATA_WIDTH-1:0] dinB,
 output [DATA_WIDTH-1:0] doutB);
endmodule
