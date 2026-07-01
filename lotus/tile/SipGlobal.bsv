/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import Vector::*;
import Connectable::*;

import Sip::*;
import LotusGlobalConfig::*;
import NonBlockingPipe::*;

interface SIPGlobalIfc;
    interface SIP sip;
    method Action enablePerfCounters(Bool epc);
endinterface

module mkSIPGlobal(SIPGlobalIfc);
    Fmt name = $format("SipGlobal");

    Wire#(Bool) enablePerfCountersW <- mkDWire(True);

    SIPMux#(2) sipMux <- mkSIPMux(name);

    // Global status registers
    Bit#(16) nTiles = fromInteger(valueOf(NumTiles));
    Bit#(16) nCores = fromInteger(valueOf(NumCoresPerTile));
    Bit#(16) nArgs = fromInteger(valueOf(MaxArgs));
    Bit#(16) nL2Banks = fromInteger(valueOf(L2NumBanks));
    Bit#(16) nTasksPerTile = fromInteger(valueOf(TasksPerTile));
    Bit#(32) lotusApiVersion = `LOTUS_API_VERSION_DEFINE;
    SIP sipGlobal  <- mkSIPStatusRegs(name + $format("-main"), cons(nTiles, cons(nCores, cons(nArgs, cons(nL2Banks, cons(nTasksPerTile, cons(lotusApiVersion[31:16], cons (lotusApiVersion[15:0], nil))))))));

    Wire#(Bool) sipCycleInc <- mkDWire(False);
    Wire#(Bool) dummy__     <- mkDWire(False);
    SIPCounters#(40) sipCycle <- mkSIPCounters(name + $format("-cycle"), cons(sipCycleInc, cons(dummy__, nil)), enablePerfCountersW);

    Vector#(2, SIP) sipTargets = cons(sipCycle, cons(sipGlobal, nil));
    zipWithM_(mkConnection, sipMux.sipToTargets, sipTargets);

    rule tick;
        sipCycleInc <= True;
    endrule

    interface SIP sip = sipMux.sipFromSource;

    method Action enablePerfCounters(Bool epc);
        enablePerfCountersW <= epc;
    endmethod


endmodule
