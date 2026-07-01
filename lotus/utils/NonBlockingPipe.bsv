/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// A rigid pipeline with no stalling mechanism. Each value written appears at
// the output "stages" cycles later.

typedef Reg#(data_t) NonBlockingPipe#(type data_t);

`ifndef WITH_BLUESIM

import "BVI" NonBlockingPipe =
module vNonBlockingPipe#(Integer stages, data_t initVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
   default_clock clk(clk, (*unused*)CLK_GATE);
   default_reset rstn(); // no reset in SV

   parameter WIDTH = valueOf(dataSz);
   parameter STAGES = stages;
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initVal));

   // inhigh is bluespec's weird way to specify always_enabled in BVI Action methods; "en" doesn't actually exist in SV!
   method _write(in) enable((*inhigh*) en) clocked_by(clk) reset_by(rstn);
   method out _read() clocked_by(clk) reset_by(rstn);

   schedule (_write, _read) CF (_read);
   schedule _write C _write;
endmodule

module mkNonBlockingPipe#(Integer stages, data_t initVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
    NonBlockingPipe#(data_t) _i = ?;
    if (valueOf(dataSz) == 0) begin
        (* hide *)
        _i <- mkDWire(initVal);
    end else if (stages == 0) begin
        (* hide *)
        _i <- mkBypassWire;
    end else begin
        (* hide *)
        _i <- vNonBlockingPipe(stages, initVal);
    end
    return _i;
endmodule

import "BVI" NonBlockingAutoPipe =
module vNonBlockingAutoPipe#(Integer maxStages, data_t initVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
   default_clock clk(clk, (*unused*)CLK_GATE);
   default_reset rstn(); // no reset in SV

   parameter WIDTH = valueOf(dataSz);
   parameter MAX_STAGES = maxStages;
   parameter INITIAL_VALUE  = Bit#(dataSz) ' (pack(initVal));

   // inhigh is bluespec's weird way to specify always_enabled in BVI Action methods; "en" doesn't actually exist in SV!
   method _write(in) enable((*inhigh*) en) clocked_by(clk) reset_by(rstn);
   method out _read() clocked_by(clk) reset_by(rstn);

   schedule (_write, _read) CF (_read);
   schedule _write C _write;
endmodule

module mkNonBlockingAutoPipe#(Integer maxStages, data_t initVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
    NonBlockingPipe#(data_t) _i = ?;
    if (valueOf(dataSz) == 0) begin
        (* hide *)
        _i <- mkDWire(initVal);
    end else if (maxStages < 2) begin
        // AutoPipe needs 2 stages at least; use a normal pipe is maxStages is 1 or 0
        (* hide *)
        _i <- mkNonBlockingPipe(maxStages, initVal);
    end else begin
        (* hide *)
        _i <- vNonBlockingAutoPipe(maxStages, initVal);
    end
    return _i;
endmodule

`else

module mkNonBlockingPipe#(Integer stages, data_t initVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
    Reg#(data_t) pipe[stages + 1];
    pipe[0] <- mkBypassWire;
    for (Integer i = 1; i < stages + 1; i = i + 1) begin
        pipe[i] <- mkReg(initVal);
    end
    
    rule advance;
        for (Integer i = 1; i < stages + 1; i = i + 1) begin
            pipe[i] <= pipe[i-1];
        end
    endrule

    // NOTE: This must be called every cycle
    method Action _write(data_t val) = pipe[0]._write(val);
    // NOTE: Should be sequenced after _write is stages == 0, but before advance otherwise
    method data_t _read = pipe[stages];
endmodule

// For AutoPipe, just make it the worst case (to expose edge cases in simulation)
module mkNonBlockingAutoPipe#(Integer maxStages, data_t initVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
    NonBlockingPipe#(data_t) _i <- mkNonBlockingPipe(maxStages, initVal);
    return _i;
endmodule

`endif

// Variant with default input value, used if a value is not written this cycle.
// This is to mkNonBlockingPipe what mkDWire is to mkWire.
module mkDNonBlockingPipe#(Integer stages, data_t initVal, data_t defaultVal)(NonBlockingPipe#(data_t)) provisos(Bits#(data_t, dataSz));
    NonBlockingPipe#(data_t) _p <- mkNonBlockingPipe(stages, initVal);
    Wire#(data_t) _in <- mkDWire(defaultVal);
    rule feedPipe;
        _p <= _in;
    endrule

    method Action _write(data_t val) = _in._write(val);
    method data_t _read = _p;
endmodule
