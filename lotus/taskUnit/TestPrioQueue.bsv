/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import LFSR::*;
import PrioQueue::*;

module mkTestPrioQueue(Empty);
    Bit#(65) feed = 0;
    feed[64] = 1;
    feed[46] = 1;
    feed[0] = 1;
    LFSR#(Bit#(65)) randomMem <- mkFeedLFSR(feed);

    // NOTE: For testing, we use Bit#(n) rather than key-value pairs. This
    // simplifies the checking script, because it's not necessary to handle
    // entries with the same key but different values (otherwise, the reference
    // priority queue may return any one of those, and equivalence checking
    // would be more complex; with just keys, same-key entries are equivalent
    // anyway).
    PrioQueue#(Bit#(2)) bbd <- mkSmallPrioQueue;
    PrioQueue#(Bit#(4)) bd <- mkHierarchicalBitmapPrioQueue(bbd, 1);
    PrioQueue#(Bit#(6)) d <- mkHierarchicalBitmapPrioQueue(bd, 2);


    Reg#(Bit#(32)) cycle <- mkReg(0);

    // Set this to something sensibly larger than the deap size
    Integer logOpsPerTest = 11;  // at full throughput (fewer with skips)
    Integer opsPerTest = 2 ** logOpsPerTest;

    rule tick;
        cycle <= cycle + 1;
        if (cycle > fromInteger(opsPerTest * 4 * 4 * 4 * 4)) $finish;
    endrule

    Wire#(Bool) popMin <- mkBypassWire;
    Wire#(Maybe#(Bit#(6))) pushVal <- mkBypassWire;

    rule decideOps;
        Bit#(65) rnd = 0;
        if (cycle == 0) begin
            randomMem.seed(signExtend(64'hdeadbeefdeadbeef));
        end else begin
            rnd = randomMem.value;
            randomMem.next;
        end
        
        // Randomly choose op, whether we push valid, and whether we skip the
        // cycle, but with biases that change over time (so we explore all
        // combinations)
        Bit#(2) opType = truncate(rnd);
        Bool pop = (opType <= cycle[logOpsPerTest+1:logOpsPerTest]);
        Bit#(2) pushType = truncate(rnd >> 2);
        Bool push = (pushType <= cycle[logOpsPerTest+3:logOpsPerTest+2]);
        Bit#(32) elem = truncate(rnd >> 4);
        Bit#(3) skipType = truncate(rnd >> 36);

        // Limit can be 0, 1, 4, or 5, so tests have prob(skip) = 0, 1/8, 1/2, or 5/8
        // This will lead to a geometric distribution of stall lenghts.
        // Overall, the goal is to have some variation (always loading the
        // pipeline at max throughput is not good, since it always follows a
        // fixed schedule) while at the same time keeping tight runs of ops,
        // since pipelining bugs are more likely to show with tight dependences.
        Bool skip = (skipType < {cycle[logOpsPerTest+5], 1'b0, cycle[logOpsPerTest+4]});

        popMin <= !skip && pop;
        pushVal <= (!skip && push)? Valid(truncate(elem)) : Invalid;
    endrule

    rule min;
        $display("[", cycle, "] min: ", fshow(d.min), " | ", popMin? "popMin" : "noPop");
        if (popMin) d.popMin;
    endrule

    rule push if (pushVal matches tagged Valid .x);
        $display("[", cycle, "] pushing: ", fshow(x));
        d.push(x);
    endrule
endmodule
