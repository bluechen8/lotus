/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

typedef Bit#(32) Word;
typedef Bit#(64) DWord;

// Instruction types
typedef enum {OP, OPIMM, BRANCH, LUI, JAL, JALR, LOAD, STORE, AUIPC, MUL, LOTUS, Unsupported} IType;

// ALU function encoding -- used in execute()
// NOTE: This may seem like an odd encoding, but it's designed to minimize
// overall processor LUTs. For example, using seemingly redundant per-subop
// flags with a lot of don't cares seems to reduce fanout and produces circuits
// with fewer LUTs. As an example, isSigned and isSub could be packed into the
// same flag. But this somehow adds LUTs, which is a much more critical
// resource than regs.
typedef enum {AddSub, Slt, Shift, Npc, TgtOrLui, And, Or, Xor} AluOp;

typedef struct {
    // Subtype bits
    Bool isSub;
    Bool isLeft;
    Bool isArith;
    Bool isSigned;
    AluOp op;
} AluFunc;

AluFunc aluFuncAdd = AluFunc{isSub: False, isLeft: ?, isArith: ?, isSigned: ?, op: AddSub};
AluFunc aluFuncSub = AluFunc{isSub: True, isLeft: ?, isArith: ?, isSigned: ?, op: AddSub};
AluFunc aluFuncSll = AluFunc{isSub: ?, isLeft: True, isArith: ?, isSigned: ?, op: Shift};
AluFunc aluFuncSrl = AluFunc{isSub: ?, isLeft: False, isArith: False, isSigned: ?, op: Shift};
AluFunc aluFuncSra = AluFunc{isSub: ?, isLeft: False, isArith: True, isSigned: ?, op: Shift};
AluFunc aluFuncSlt = AluFunc{isSub: True, isLeft: ?, isArith: ?, isSigned: True, op: Slt};
AluFunc aluFuncSltu = AluFunc{isSub: True, isLeft: ?, isArith: ?, isSigned: False, op: Slt};
AluFunc aluFuncAnd = AluFunc{isSub: ?, isLeft: ?, isArith: ?, isSigned: ?, op: And};
AluFunc aluFuncOr = AluFunc{isSub: ?, isLeft: ?, isArith: ?, isSigned: ?, op: Or};
AluFunc aluFuncXor = AluFunc{isSub: ?, isLeft: ?, isArith: ?, isSigned: ?, op: Xor};
AluFunc aluFuncNpc = AluFunc{isSub: ?, isLeft: ?, isArith: ?, isSigned: ?, op: Npc};
AluFunc aluFuncTgtOrLui = AluFunc{isSub: ?, isLeft: ?, isArith: ?, isSigned: ?, op: TgtOrLui};
AluFunc aluFuncSignedBr = AluFunc{isSub: True, isLeft: ?, isArith: ?, isSigned: True, op: ?};
AluFunc aluFuncUnsignedBr = AluFunc{isSub: True, isLeft: ?, isArith: ?, isSigned: False, op: ?};

// Return type for Decode function
typedef struct {
    IType iType;
    AluFunc aluFunc;
    Bit#(3) funct3;
    RIndx dst;
    RIndx src1;
    RIndx src2;
    Bool hasSrc1;
    Bool hasSrc2;
    Bool pcRelativeAddr;
    Word imm;

    // Extra control signals for optimization
    Bool isLoad;
    Bool isMem; // isStore == isMem && !isLoad
    Bool isBranch;
    Bool isJal;
    Bool isJump; // Jal or Jalr
    Bool isAuipc;
    Bool isLui;
    Bool isMul;
    Bool isDiv;
    Bool isLotusEnq;
    Bool isUnsupported;
} DecodedInst;

DecodedInst dNop = DecodedInst{iType: OP, aluFunc: ?, funct3: ?, dst: 0,
    src1: ?, src2: ?, hasSrc1: ?, hasSrc2: ?,pcRelativeAddr: ?,  imm: ?, isLoad: False, isMem: False,
    isBranch: False, isJal: False, isJump: False, isAuipc: ?, isLui: ?, isMul: False, isDiv: False, isUnsupported: False, isLotusEnq: False};

// Return type for Execute function
typedef struct {
    Word data;
    Word addr;
    Word redirectPC;  // only used on mispredictions
    Bool mispredict;
} ExecInst;

// Register File
typedef Bit#(5) RIndx;

typedef struct {
    RIndx index;
    Word data;
} RegWriteArgs;

/* RISC-V opcode/fn constants */

// Opcode
Bit#(7) opOpImm  = 7'b0010011;
Bit#(7) opOp     = 7'b0110011;
Bit#(7) opLui    = 7'b0110111;
Bit#(7) opJal    = 7'b1101111;
Bit#(7) opJalr   = 7'b1100111;
Bit#(7) opBranch = 7'b1100011;
Bit#(7) opLoad   = 7'b0000011;
Bit#(7) opStore  = 7'b0100011;
Bit#(7) opAuipc  = 7'b0010111;
Bit#(7) opSystem = 7'b1110011;
Bit#(7) opLotus    = 7'b0001011;

// funct3 - ALU
Bit#(3) fnADD   = 3'b000;
Bit#(3) fnSLL   = 3'b001;
Bit#(3) fnSLT   = 3'b010;
Bit#(3) fnSLTU  = 3'b011;
Bit#(3) fnXOR   = 3'b100;
Bit#(3) fnSR    = 3'b101;
Bit#(3) fnOR    = 3'b110;
Bit#(3) fnAND   = 3'b111;
// funct3 - Branch
Bit#(3) fnBEQ   = 3'b000;
Bit#(3) fnBNE   = 3'b001;
Bit#(3) fnBLT   = 3'b100;
Bit#(3) fnBGE   = 3'b101;
Bit#(3) fnBLTU  = 3'b110;
Bit#(3) fnBGEU  = 3'b111;
// funct3 - Load
Bit#(3) fnLW    = 3'b010;
Bit#(3) fnLB    = 3'b000;
Bit#(3) fnLH    = 3'b001;
Bit#(3) fnLBU   = 3'b100;
Bit#(3) fnLHU   = 3'b101;
// funct3 - Store
Bit#(3) fnSW    = 3'b010;
Bit#(3) fnSB    = 3'b000;
Bit#(3) fnSH    = 3'b001;
// funct3 - Lotus
Bit#(3) fnDeq    = 3'b000;
Bit#(3) fnEnq    = 3'b001;


