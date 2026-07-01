/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CoreTypes;

function Bit#(32) shifter(Bit#(32) in, Bit#(5) sftSz, Bool isLeft, Bool isArith);
    // NOTE: The standard 7-mux implementation (reverse, rightshift, reverse)
    // to do left and right shifts is slow on the FPGA. We use a wider right
    // shift instead. This design comes from Taiga/CVA5's barrel shifter.
    Bit#(63) sftIn = isLeft? {in, 31'b0} : (isArith? signExtend(in) : zeroExtend(in));
    Bit#(5) sftAmt = isLeft? ~sftSz : sftSz;
    return truncate(sftIn >> sftAmt);
endfunction

// Execute function
function ExecInst execute(DecodedInst dInst, Word rVal1, Word rVal2, Word pc);
    let imm = dInst.imm;
    let func = dInst.aluFunc;
    let funct3 = dInst.funct3;
    let aluVal2 = dInst.hasSrc2? rVal2 : imm;

    // Adder/subtractor, used for Add, Sub, and less-than comparisons (Slt + branches)
    Bit#(32) addSubRes = rVal1 + (func.isSub? ~aluVal2 : aluVal2) + (func.isSub? 1 : 0);

    // Branches: Leverage funct3 encoding, and use addSubRes for less-than comparator
    Bit#(1) negBit = funct3[0];
    // funct3[1] encodes signed/unsigned, but decoder already passes this in func.isSigned
    Bit#(1) lessThanBit = funct3[2];

    Bool lessThan = (rVal1[31] == aluVal2[31] && addSubRes[31] == 1) || (rVal1[31] == (func.isSigned? 1 : 0) && aluVal2[31] == (func.isSigned? 0 : 1));
    Bool eq = (rVal1 == aluVal2); // used only for branches, but using rVal2 instead of aluVal2 adds LUTs (this enables shaing with Xor/Xori)

    // Pick branch outcome using the other two bits
    Bool cmp = (lessThanBit == 1)? lessThan : eq;
    Bool brTaken = (negBit == 1)? !cmp : cmp;

    // Other arith ops
    Bit#(32) cmpRes = zeroExtend(lessThan? 1'b1 : 1'b0);
    Bit#(32) shiftRes = shifter(rVal1, aluVal2[4:0], func.isLeft, func.isArith); // ~100 LUTs

    // Compute addresses and jump/branch targets with a separate adder. These are timing-critical.
    let addrOrTgt = (dInst.pcRelativeAddr? pc : rVal1) + imm;
    let redirectPC = {addrOrTgt[31:2], 2'b0}; // Without C instructions, this is 4-byte aligned

    // NOTE: Enum encoding here is important for LUTs and performance; in particular, note
    // the last 4 operands hare aluVal2 (and LUI uses aluVal2, not imm)
    Bit#(32) aluRes = case (func.op)
        AddSub: addSubRes;
        Slt: cmpRes;
        Shift: shiftRes;
        Npc: pc + 4;
        TgtOrLui: dInst.isLui? aluVal2 : addrOrTgt;
        And: rVal1 & aluVal2;
        Or: rVal1 | aluVal2;
        Xor: rVal1 ^ aluVal2;
    endcase;

    Bool mispredict = dInst.isJump || (dInst.isBranch && brTaken);
    
    return ExecInst{data: aluRes, addr: addrOrTgt, mispredict: mispredict, redirectPC: redirectPC};
endfunction

/* Multiplier and Divider for RV32M instructions */

typedef struct {
    Word a;
    Word b;
    Bool aIsSigned;
    Bool bIsSigned;
} MulReq;

// Note that this is coded to use DSPs and pipeline well; this code is not idiomatic
module Multiplier;
    // Input pipeline registers
    RegU#(Bit#(33)) aIn;
    RegU#(Bit#(33)) bIn;
    Reg#(Bool) validIn(False);

    // Output pipeline. To be absorbed into DSPs, all pipe regs must be driven
    // with same enable signal. This means that the pipeline can't collapse bubbles.
    // There are two sensible choices for outPipeRegs: 
    // - 1 reg gives no mul stalls in a 4-stage pipe, but has a 2.2ns cycle
    //   time, uses some LUTs in addition to DSPs, and makes closing timing at
    //   2.5ns hard because DSPSs are often far from BRAMs.
    // - 3 regs cause 2 stalls per mul, but close timing at 1.5ns, the
    //   multiplier uses fewer LUTs, and it enalbes higher frequency.
    // 2 regs have no benefit, and 4+ don't seem to cause more pipelining than 3.
    Integer outPipeRegs = 1;
    Vector#(outPipeRegs, RegU#(Bit#(64))) dataPipe;
    Vector#(outPipeRegs, Reg#(Bool)) validPipe(False);

    input Maybe#(MulReq) req default = Invalid;
    
    method Maybe#(Bit#(64)) result = validPipe[outPipeRegs-1]? Valid(dataPipe[outPipeRegs-1]) : Invalid;
    input Bool popResult default = False;

    rule tick;
        // Output pipe
        Bool advanceOutPipe = !validPipe[outPipeRegs-1] || popResult;
        if (advanceOutPipe) begin
            for (Integer p = 1; p < outPipeRegs; p = p + 1) begin
                validPipe[p] <= validPipe[p-1];
                dataPipe[p] <= dataPipe[p-1];
            end

            validPipe[0] <= validIn;
            dataPipe[0] <= signExtend(aIn) * signExtend(bIn);
        end

        // Input pipe
        if (!validIn || advanceOutPipe) begin
            validIn <= isValid(req);
            let r = fromMaybe(?, req);
            aIn <= {r.aIsSigned? r.a[31] : 0, r.a};
            bIn <= {r.bIsSigned? r.b[31] : 0, r.b};
        end
    endrule
endmodule


typedef struct {
    Word dividend;
    Word divisor;
    Bool isSigned;
    Bool retRemainder;
} DivReq;

typedef enum { IDLE, COMPUTE, OUTPUT_RESULT } DivState;

module Divider;
    Reg#(DivState) state(IDLE);
    RegU#(Bit#(5)) counter;
    RegU#(Bit#(32)) rem;
    RegU#(Bit#(33)) quot;
    RegU#(Bit#(32)) divisor;
    Reg#(Bool) isSub(True);

    RegU#(Bool) invResult;
    RegU#(Bool) retRemainder;
    RegU#(Bit#(32)) resReg;

    input Maybe#(DivReq) req default = Invalid;
    
    method Bool reqEnabled = state != IDLE;

    rule tick;
        Word w1 = case (state)
            COMPUTE: {rem[30:0], quot[32]};
            default: 0;
        endcase;

        Word preRetVal = retRemainder? rem : quot[31:0];

        Word w2 = case (state)
            IDLE: fromMaybe(?, req).dividend;
            COMPUTE: divisor;
            OUTPUT_RESULT: preRetVal;
        endcase;

        Word addSubRes = w1 + (isSub? ~w2 : w2) + (isSub? 1 : 0);

        // We're interested in the sign bit of 33-bit subtraction of
        // {rem, quot[32]} - {1'b0, flippedDivisor. But 33-bit sub incurs an
        // extra carry chain and more LUTs. Instead, compute from addSubRes:
        // - rem[31] == 1 -> False
        // - Assuming rem[31] == 0:
        //   - rem[30] == 0 and fdiv[31] == 1 -> True
        //   - rem[30] == fdiv[31] -> addSubRes[31] == 1
        //   - But note that div here is the FLIPPED divisor. isSub is whether
        //     we flip, so we use this as the test condition.
        // NOTE: When divisor = 10.....0, it's not clear that this works:
        // -divisor == divisor in this case, so using isSub gets the sign off.
        // However, here isSub == False; if rem[30] == 1, then this can't be
        // negative, and if rem[30] == 0, then this matches the last condition
        // and addSubRes[31] == 1 always, catching this edge case.
        Bool lessThan = (rem[31] == 0) && ((rem[30] == 0 && divisor[31] == (isSub? 1 : 0)) || (rem[30] == (isSub? divisor[31] : ~divisor[31])) && addSubRes[31] == 1);
        
        if (state == IDLE && isValid(req)) begin
            let r = fromMaybe(?, req);
            Bool invDividend = (r.isSigned && r.dividend[31] == 1);
            isSub <= !(r.isSigned && r.divisor[31] == 1);
            rem <= 0;
            quot <= {invDividend? addSubRes : r.dividend, 1'b0};
            divisor <= r.divisor;

            invResult <= r.isSigned && (r.retRemainder? (r.dividend[31] == 1) :
                ((r.dividend[31] != r.divisor[31]) && (r.divisor != 0)));
            retRemainder <= r.retRemainder;

            counter <= 31;
            state <= COMPUTE;
        end else if (state == COMPUTE) begin
            quot <= {truncate(quot), lessThan? 1'b0 : 1'b1};
            rem <= lessThan? {truncate(rem) , quot[32]} : addSubRes;
            counter <= counter - 1;
            if (counter == 0) begin
                state <= OUTPUT_RESULT;
                isSub <= invResult;
            end
        end else if (state == OUTPUT_RESULT) begin
            rem <= addSubRes; // 0 +/- prevRetVal, so no need more muxing
            state <= IDLE;
            isSub <= True;
        end
    endrule

    method Maybe#(Bit#(32)) result = (state == IDLE)? Valid(rem) : Invalid;
endmodule
