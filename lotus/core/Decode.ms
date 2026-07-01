/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CoreTypes;

function DecodedInst decode(Bit#(32) inst);
    let opcode = inst[6:0];
    let funct3 = inst[14:12];
    let funct7 = inst[31:25];
    let dst    = inst[11:7];
    let src1   = inst[19:15];
    let src2   = inst[24:20];

    // To streamline the decoder, we now use an invalid IType defined as
    // don't-care. This means that the core will do whatever on malformed
    // instructions, but this reduces the critical path and improves synthesis
    // results. Uncomment the line below to flag all unsupported instrs as
    // Unsupported.
    //IType invIType = Unsupported;
    IType invIType = ?;

    DecodedInst dInst = ?;

    dInst.iType = case (opcode)
        opOp: case (funct7)
            7'b0000000: OP;
            7'b0100000: (funct3 == fnADD || funct3 == fnSR)? OP : invIType;
            7'b0000001: MUL;
            default: invIType;
        endcase;
        opOpImm: case (funct3)
                     fnSLL: (funct7 == 7'b0000000)? OPIMM : invIType;
                     fnSR:  ({funct7[6], funct7[4:0]} == 6'b000000)? OPIMM : invIType;
                     default: OPIMM;
                 endcase;
        opBranch: (funct3 == fnBEQ || funct3 == fnBNE || funct3 == fnBLT ||
                   funct3 == fnBGE || funct3 == fnBLTU || funct3 == fnBGEU)? BRANCH : invIType;
        opLui:  LUI;
        opJal:  JAL;
        opJalr: JALR;
        opLoad: (funct3 == fnLW || funct3 == fnLH || funct3 == fnLB || funct3 == fnLHU || funct3 == fnLBU)? LOAD : invIType;
        opStore: (funct3 == fnSW || funct3 == fnSH || funct3 == fnSB)? STORE : invIType;
        opAuipc: AUIPC;
        opLotus: LOTUS;
        default: Unsupported;
    endcase;

    dInst.aluFunc = case (funct3)
        fnADD:  (inst[30] == 1 && opcode == opOp)? aluFuncSub : aluFuncAdd;
        fnSLT:  aluFuncSlt;
        fnSLTU: aluFuncSltu;
        fnXOR:  aluFuncXor;
        fnOR:   aluFuncOr;
        fnAND:  aluFuncAnd;
        fnSLL:  aluFuncSll;
        fnSR:   (inst[30] == 0)? aluFuncSrl : aluFuncSra;
    endcase;
    dInst.aluFunc = case (opcode)
        opLui, opAuipc: aluFuncTgtOrLui;
        opJal, opJalr: aluFuncNpc;
        opBranch: funct3[1] == 1? aluFuncUnsignedBr : aluFuncSignedBr;
        default: dInst.aluFunc;
    endcase;

    dInst.funct3 = {funct3[2], (opcode == opLotus) ? funct7[1:0] : funct3[1:0]};

    dInst.src1 = src1;
    dInst.src2 = src2;
    dInst.dst = case (opcode)
        opBranch, opStore: 0;
        default: dst;
    endcase;

    // These can be approximate, so don't use iType
    dInst.hasSrc1 = case (opcode)
        opLui, opAuipc, opJal: False;
        default: True;
    endcase;
    dInst.hasSrc2 = case (opcode)
        opOp, opBranch, opStore: True;
        default: False;
    endcase;
    dInst.pcRelativeAddr = case (opcode) 
        opAuipc, opBranch, opJal: True;
        opLoad, opStore: False;
        default: ?;
    endcase;
    
    // To reduce delay, use opcode, not iType
    dInst.imm = case (opcode)
        /*I-type*/  opOpImm, opLoad, opJalr: signExtend(inst[31:20]); 
        /*S-type*/  opStore: signExtend({inst[31:25], inst[11:7]});
        /*SB-type*/ opBranch: signExtend({inst[31], inst[7], inst[30:25], inst[11:8], 1'b0});
        /*U-type*/  opLui, opAuipc: {inst[31:12], 12'b0};
        /*UJ-type*/ opJal: signExtend({inst[31], inst[19:12], inst[20], inst[30:21], 1'b0});
        default: ?;
    endcase;

    // NOTE: In principle, computing these from opcode rather tan iType should
    // be less logic.  But synthesis is unstable around this code, and core
    // LUTs grow in many cases (there's a change in the number of MUXF7s used).
    dInst.isLoad = (dInst.iType == LOAD);
    dInst.isMem = (dInst.iType == LOAD) || (dInst.iType == STORE);
    dInst.isBranch = (dInst.iType == BRANCH);
    dInst.isJal = (dInst.iType == JAL);
    dInst.isJump = (dInst.iType == JAL) || (dInst.iType == JALR);
    dInst.isAuipc = (dInst.iType == AUIPC);
    dInst.isLui = (dInst.iType == LUI);
    dInst.isMul = (dInst.iType == MUL && funct3[2] == 0);
    dInst.isDiv = (dInst.iType == MUL && funct3[2] == 1);
    dInst.isUnsupported = (dInst.iType == Unsupported);
    dInst.isLotusEnq = (dInst.iType == LOTUS); // NOTE: Enq is the only Lotus instr right now

    return dInst;
endfunction
