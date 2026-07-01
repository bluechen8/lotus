/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import TaskUnit::*;
import Include::*;
import Sip::*;
import TokenSenderTypes::*;

import Vector::*;
import FIFO::*;
import Connectable::*;


interface TaskUnitConfig;
    interface SIP sip;
    method ActionValue#(TaskConfig) getConfigTask;

    // FIXME: These are non-blocking, and the above one should be too
    // FIXME: We should settle on annotations for non-blocking methods, e.g., making them always_enabled with explicit maybe values.
    method Word getStackBase;
    method Word getInitialArg;
endinterface

typedef struct {
    Word initialArg;
    Word stackBase; // stack base pointer. TODO: consider migrating this control reg to the tile; this is passed as an arg, but doesn't go through task unit
    // Per-task metadata
    Word numInEdgesReceivedFirstCycle;
    Word flags;
    Word numOutArgs       ;
    Word firstEdgeIdxStart;
    Word numOutEdges    ;
    Word numInEdges       ;
    Word numArgs          ;
    Word firstArgIdx      ;
    Word taskSize         ;
    Word taskFn           ;
    Word taskId           ;
} TaskConfigReg deriving (Bits, FShow);

module mkTaskUnitConfig(TaskUnitConfig);
    Fmt name = $format("TaskUnitConfig");
    // FIXME(dsm): This was using ControlRegsTyped. I'd make this a single reg
    // with a TaskConfig, and in any case, get rid of dispatchReg, whose sole
    // purpose is to mark when a bunch of non-atomic writes are done. Just set
    // a max of 64 or 128 bytes for SIP requests, sip_write an entire task
    // config struct in C in one shot to one address, and call it a day!
    // Alternatively, if you're not writing the whole struct each time,
    // similar deal: expose the words, and use a write to the last word as
    // the trigger.
    SIPControlRegs#(1, Bool) dispatchReg <- mkSIPControlRegs(name + $format("-DispatchReg"));
    SIPControlRegs#(TDiv#(SizeOf#(TaskConfigReg), SizeOf#(Word)), Word) configReg <- mkSIPControlRegs(name + $format("-ConfigReg"));
    Integer numControlRegs = valueOf(TDiv#(SizeOf#(TaskConfigReg), SizeOf#(Word)));

    SIPMux#(2) sipMux <- mkSIPMux(name);
    Vector#(2, SIP) sipTargets = cons(configReg.sip, cons(dispatchReg.sip, nil));
    zipWithM_(mkConnection, sipMux.sipToTargets, sipTargets);

    FIFO#(TaskConfig) outConfigFIFO <- mkFIFO1;

    rule sendConfig if (dispatchReg.regsUpdated[0]);
        TaskConfigReg c = unpack(pack(configReg.regs));
        outConfigFIFO.enq(TaskConfig {
            taskId     : truncate(c.taskId),
            taskFn     : c.taskFn,
            taskSize   : truncate(c.taskSize),
            firstArgIdx : truncate(c.firstArgIdx),
            numArgs    : truncate(c.numArgs),
            numInEdges : truncate(c.numInEdges),
            numOutEdges: truncate(c.numOutEdges),
            numOutArgs : truncate(c.numOutArgs),
            firstEdgeIdxStart: truncate(c.firstEdgeIdxStart),
            numInEdgesReceivedFirstCycle : truncate(c.numInEdgesReceivedFirstCycle),
            firstCycleForce : unpack(c.flags[0]),
            canSkip : unpack(c.flags[1])
        });
    endrule: sendConfig

    interface SIP sip = sipMux.sipFromSource;

    method ActionValue#(TaskConfig) getConfigTask;
        outConfigFIFO.deq;
        return outConfigFIFO.first;
    endmethod

    method Word getStackBase if (configReg.regsUpdated[numControlRegs-2]) = configReg.regs[numControlRegs-2];
    method Word getInitialArg if (configReg.regsUpdated[numControlRegs-1]) = configReg.regs[numControlRegs-1];
endmodule: mkTaskUnitConfig

