/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// An n-in n-out butterfly switch for messages of type T with combinational
// arbitration. Achieves single-cycle traversals at high frequency for small n
// (~500MHz for n=4, ~400MHz for n=8). If larger n is desired, this switch
// could be used as a building block of a larger network.

/* Combinational switch --- composed recursively from radix-2 switches */

typedef struct {
    Bit#(log2(n)) dest;
    T data;
} SwitchReq#(Integer n, type T);

module Switch#(Integer n, type T);
    Integer k = log2(n);

    input Vector#(n, Maybe#(SwitchReq#(n, T))) reqs;

    // Specifies a changing priority, typically from a counter to ensure fairness
    input Bit#(k) prio;

    Vector#(n/2, Switch#(2, Tuple2#(Bit#(k-1), T))) firstStage;
    Switch#(n/2, T) lower;
    Switch#(n/2, T) upper;

    rule firstStageReqs;
        for (Integer i = 0; i < n/2; i = i + 1) begin
            Vector#(2, Maybe#(SwitchReq#(2, Tuple2#(Bit#(k-1), T)))) fReqs;
            for (Integer j = 0; j < 2; j = j + 1) begin
                if (isValid(reqs[2*i+j])) begin
                    let r = fromMaybe(?, reqs[2*i+j]);
                    fReqs[j] = Valid(SwitchReq#(2, Tuple2#(Bit#(k-1), T)){dest: r.dest[k-1], data: tuple2(r.dest[k-2:0], r.data)});
                end else fReqs[j] = Invalid;
            end
            firstStage[i].reqs = fReqs;
            firstStage[i].prio = prio[k-1];
        end
    endrule

    rule propagateFirstStageOuts;
        Vector#(n, Maybe#(SwitchReq#(n/2, T))) nextReqs;
        for (Integer i = 0; i < n/2; i = i + 1) begin
            for (Integer j = 0; j < 2; j = j + 1) begin
                if (isValid(firstStage[i].getOuts[j])) begin
                    let r = fromMaybe(?, firstStage[i].getOuts[j]);
                    nextReqs[i+j*(n/2)] = Valid(SwitchReq#(n/2, T){dest: tpl_1(r), data: tpl_2(r)});
                end else nextReqs[i+j*(n/2)] = Invalid;
            end
        end
        lower.reqs = take(nextReqs);
        upper.reqs = takeTail(nextReqs);
        lower.prio = prio[k-2:0];
        upper.prio = prio[k-2:0];
    endrule

    method Vector#(n, Maybe#(T)) getOuts = append(lower.getOuts, upper.getOuts);
    
    method Vector#(n, Bool) getGrants;
       let ng = append(lower.getGrants, upper.getGrants);
       Vector#(n, Bool) res;
       for (Integer i = 0; i < n/2; i = i + 1) begin
           for (Integer j = 0; j < 2; j = j + 1) begin
               res[2*i+j] = firstStage[i].getGrants[j] 
                            && ((fromMaybe(?, reqs[2*i+j]).dest[k-1] == 0)? ng[i] : ng[i+n/2]);
           end
       end
       return res;
   endmethod

endmodule

// Base case
module Switch#(2, type T);
    input Vector#(2, Maybe#(SwitchReq#(2, T))) reqs;
    input Bit#(1) prio;

    BypassWire#(Vector#(2, Maybe#(T))) outs;
    BypassWire#(Vector#(2, Bool)) grants;

    rule tick;
        Vector#(2, Bool) g = replicate(False);
        Vector#(2, Maybe#(T)) d = replicate(Invalid);
        for (Integer o = 0; o < 2; o = o + 1) begin
            Integer p = (o == 0)? 1 : 0;
            Bool oMatches = isValid(reqs[o]) && fromMaybe(?, reqs[o]).dest == o;
            Bool pMatches = isValid(reqs[p]) && fromMaybe(?, reqs[p]).dest == o;
            Bool pHasPrio = pMatches && (prio == 1);
            if (oMatches && !pHasPrio) begin
                d[o] = Valid(fromMaybe(?, reqs[o]).data);
                g[o] = True;
            end else if (pMatches) begin
                d[o] = Valid(fromMaybe(?, reqs[p]).data);
                g[p] = True;
            end
        end
        outs <= d;
        grants <= g;
    endrule

    method Vector#(2, Maybe#(T)) getOuts = outs;
    method Vector#(2, Bool) getGrants = grants;
endmodule

/* Switch with input and output pipeline registers, and output feedback.
 * Output feedback avoids issuing a request from a source if its destination is
 * not ready. This improves throuhgput: while we could send all input
 * requests, requests whose destionation isn't ready can block other
 * requests from making progress. This implementation avoids this problem,
 * but note that this increases cobinational delay and requires the deq
 * signals to be early in the cycle.
 */
module PipelinedSwitch#(Integer n, type T);
    Switch#(n, T) s;

    Reg#(Vector#(n, Maybe#(SwitchReq#(n, T)))) reqsReg(replicate(Invalid));
    Reg#(Vector#(n, Maybe#(T))) outsReg(replicate(Invalid));

    Reg#(Bit#(log2(n))) prioCounter(0);
    rule tick;
        s.prio = prioCounter;
    endrule

    rule incPrio;
        prioCounter <= prioCounter + 1;
    endrule

    input Vector#(n, Maybe#(SwitchReq#(n, T))) reqs default = replicate(Invalid);
    method Vector#(n, Bool) reqsEnabled;
        Vector#(n, Bool) en;
        for (Integer i = 0; i < n; i = i + 1) en[i] = s.getGrants[i] || !isValid(reqsReg[i]);
        return en;
    endmethod

    method Vector#(n, Maybe#(T)) outs = outsReg;
    input Vector#(n, Bool) deqs default = replicate(False);

    // 1. Figure out which destinations are ready to receive
    BypassWire#(Vector#(n, Bool)) readyDests;
    rule findReadys;
        Vector#(n, Bool) r;
        for (Integer i = 0; i < n; i = i + 1) r[i] = deqs[i] || !isValid(outsReg[i]);
        readyDests <= r;
    endrule

    // 2. Put in requests, gated by readies
    rule setReqs;
        Vector#(n, Maybe#(SwitchReq#(n, T))) switchReqs;
        for (Integer i = 0; i < n; i = i + 1) begin
            // NOTE: isValid here is superfluous, but doesn't change synthesis
            switchReqs[i] = (isValid(reqsReg[i]) && readyDests[fromMaybe(?, reqsReg[i]).dest])? reqsReg[i] : Invalid;
        end
        s.reqs = switchReqs;
    endrule

    // 3. Get outputs and update registers
    rule writeOuts;
        let switchOuts = s.getOuts;
        let newOuts = outsReg;
        for (Integer i = 0; i < n; i = i + 1) begin
            if (deqs[i]) newOuts[i] = switchOuts[i];
        end
        outsReg <= newOuts;
    endrule

    // 4. Move input regs forward, and set enables
    rule takeReqs;
        let grants = s.getGrants;
        let newReqs = reqsReg;
        for (Integer i = 0; i < n; i = i + 1) begin
            if (grants[i] || !isValid(reqsReg[i])) newReqs[i] = reqs[i];
        end
        reqsReg <= newReqs;
    endrule
endmodule


bsvimport LFSR;
bsvimport FeedLFSR; 
bsvimport Assert;

module TestSwitch;
    Integer n = 8;
    Integer k = log2(n);
    Reg#(Bit#(20)) cycle(0);
    PipelinedSwitch#(n, Vector#(2, Bit#(k))) switch;
   
    Bit#(65) seed = 0;
    seed[64] = 1;
    seed[46] = 1;
    seed[0] = 1;
    FeedLFSR#(Bit#(65)) random(seed);

    Vector#(n, Reg#(Bit#(32))) srcSends(0);
    Vector#(n, Reg#(Bit#(32))) srcBlocks(0);

    Vector#(n, Vector#(n, Reg#(Bit#(32)))) dstRecvs(0);
    Vector#(n, Reg#(Bit#(32))) dstNoRecvs(0);

    rule deq;
        switch.deqs = replicate(True);
    endrule

    rule tick;
        cycle <= cycle + 1;
        if (cycle < 1024) begin
            let newrand = random.value;
            random.next;
        end else if (cycle + 8 > cycle) begin
            // This LFSR produces deficient randomness, use mod to try to even things out
            let rnd =  random.value % ((1 << 49) - 1);
            random.next;

            // Send side
            Vector#(n, Maybe#(SwitchReq#(n, Vector#(2, Bit#(k))))) reqs;
            for (Integer i = 0; i < n; i = i + 1) begin
                Bit#(k) dest = truncate(rnd >> 2*i*k);
                reqs[i] = Valid(SwitchReq#(n, Vector#(2, Bit#(k))){dest: dest, data: unpack({dest, i})});
                if (switch.reqsEnabled[i]) srcSends[i] <= srcSends[i] + 1;
                else srcBlocks[i] <= srcBlocks[i] + 1;
            end
            switch.reqs = reqs;
        end

        // Receive side
        for (Integer i = 0; i < n; i = i + 1) begin
            if (isValid(switch.outs[i])) begin
                let data = fromMaybe(?, switch.outs[i]);
                Bit#(k) src = data[0];
                Bit#(k) dest = data[1];
                if (dest != i) begin
                    $display("FAILED: Switch does not send data to the right destination, cycle=%d src=%d reqDest=%d actualDest=%d", cycle, src, dest, i);
                    $finish;
                end
                dstRecvs[i][src] <= dstRecvs[i][src] + 1;
            end else begin
                dstNoRecvs[i] <= dstNoRecvs[i] + 1;
            end
        end
        
        if (cycle == ~0) begin
            // If the switch is fair, you should see a reasonably uniform distribution of sends and receives by src/dst
            // The send vs send block tells you the injection rate that can be achieved at this radix
            // This should be close to the theoretical bound, e.g. 75/61/51/45% for radix 2/4/8/16
            $display("Simulation done");
            $display("Sends:        ", fshow(map(readReg, srcSends)));
            $display("Send blocks:  ", fshow(map(readReg, srcBlocks)));
            $display("NoRecvs:      ", fshow(map(readReg, dstNoRecvs)));
            for (Integer i = 0; i < n; i = i + 1) begin
                $display("Recvs[%d]    :  ", i, fshow(map(readReg, dstRecvs[i])));
            end
            Bit#(40) sends = zeroExtend(fold(add, map(readReg, srcSends)));
            Bit#(40) blocks = zeroExtend(fold(add, map(readReg, srcBlocks)));
            // Poor man's floating point :)
            $display("Injection rate: ", 100 * sends / (sends + blocks), ".", (10 * sends / (sends + blocks)) % 10, "%");
            $display("PASSED");
            $finish;
        end
    endrule
endmodule
