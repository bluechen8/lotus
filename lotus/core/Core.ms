/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import CoreTypes;

import RegisterFile;
import Decode;
import Execute;

import ICache;
import DCache;
import FIFO2;

typedef struct {
  Word pc;
  DecodedInst dInst;
  Word rVal1;
  Word rVal2;
} D2E;

typedef struct {
  Word pc;
  DecodedInst dInst;
  Word data;
  Word dataAddr; // for debugging only
  Word storeVal; // for debugging only
} E2W;

D2E nopE = D2E{pc: ?, dInst: dNop, rVal1: ?, rVal2: ?};
E2W nopW = E2W{pc: ?, dInst: dNop, data: ?, dataAddr: ?, storeVal: ?};

typedef struct {
    Word epc;
    Bool isInitial;
} Exception;

typedef struct {
   RIndx   argNum;
   Word    argData;
} TaskArgWrite;

module Core;
    RegisterFile rf;

    // Caches (which use external memReq logic below)
    ICache iCache;  // holds pc
    DCache dCache;

    // Pipeline registers (no f2d; icache returns pc along with instruction)
    Reg#(D2E) d2e(nopE);
    Reg#(E2W) e2w(nopW);

    // Multiply and divide units. Fed in E, read in W
    Multiplier multiplier;
    Divider divider;

    // Argument enqueue interface
    Wire#(Maybe#(Vector#(2, Word))) enqArgPairInternal;
    method Maybe#(Vector#(2, Word)) enqArgPair = enqArgPairInternal;
    input Bool enqArgPairReady;

    // Task Deq Interface
    input Maybe#(TaskArgWrite) taskArgWrite;

    // Exception interface; start exceptioned
    Reg#(Maybe#(Exception)) exception(Valid(Exception{epc: 0, isInitial: True}));
    method Maybe#(Exception) getException = exception;
    input Maybe#(Word) clearException; // sets new PC

    // Main memory interface---pipelined
    // Loads reply with lines, stores (from DCache) do NOT reply. Store
    // write-throughs are ordered with loads, and the memory system must serve
    // each load with the latest data values, including all prior stores. The
    // core has no store buffer and the data cache is write-through and  NWA
    // (store misses do not fetch the line).
    method Maybe#(MemReq) memReq = isValid(dCache.memReq)? dCache.memReq : iCache.memReq;

    input Bool memReqReady;

    input Maybe#(Tuple2#(CoreRespId, Bit#(64))) rdResp;

    input Maybe#(Tuple2#(Word, TaskSize)) nextTaskPrefetchHint default = Invalid;

    DWire#(Bool) perf_instrsCommit(False);
    DWire#(Bool) perf_icacheStall(False);
    DWire#(Bool) perf_dcacheStall(False);
    DWire#(Bool) perf_dCacheReadReq(False);
    DWire#(Bool) perf_dCacheWriteReq(False);
    DWire#(Bool) perf_iL2Req(False);
    DWire#(Bool) perf_dL2ReadReq(False);
    DWire#(Bool) perf_dL2WriteReq(False);
    DWire#(Bool) perf_l2Stall(False);
    DWire#(Bool) perf_simHeartbeat(False);
    DWire#(Bool) perf_simFail(False);
    method Vector#(11, Bool) perfInc = cons(perf_instrsCommit, cons(perf_icacheStall, cons(perf_dcacheStall,
                                           cons(perf_dCacheReadReq, cons(perf_dCacheWriteReq, cons(perf_iL2Req,
                                               cons(perf_dL2ReadReq, cons(perf_dL2WriteReq, cons(perf_l2Stall, 
                                                   cons(perf_simHeartbeat, cons(perf_simFail, nil)))))))))));

    rule mem;
        // Request side
        if (memReqReady) begin
            if (isValid(dCache.memReq)) begin
                dCache.memReqReady = True;
                Bool isRead = fromMaybe(?, dCache.memReq).wrMask == 0;
                perf_dL2ReadReq  <=  isRead;
                perf_dL2WriteReq <= !isRead;
            end else if (isValid(iCache.memReq)) begin
                iCache.memReqReady = True;
                perf_iL2Req <= True;
            end 
        end else begin
            perf_l2Stall <= isValid(dCache.memReq) || isValid(iCache.memReq);
        end

        // Response side
        if (isValid(rdResp)) begin
            let coreRespId = tpl_1(fromMaybe(?, rdResp));
            let rdRespChunk = tpl_2(fromMaybe(?, rdResp));
            if (coreRespId.destCache == DCACHE) begin
                dCache.rdResp = Valid(rdRespChunk);
            end else begin
                iCache.rdResp = Valid(tuple2(coreRespId.icacheRespId, rdRespChunk));
            end
        end

        let tph = fromMaybe(?, nextTaskPrefetchHint);
        iCache.nextTaskPrefetchHint = isValid(nextTaskPrefetchHint)? 
            Valid(TaskPrefetchHint{wordAddr: tpl_1(tph)[31:2], size: tpl_2(tph)}) : Invalid;
    endrule

    // Debugging counters
    // NOTE(dsm): These are distinct from the 1-bit performance counter inc
    // signals; they are used just for debugging and optimized out in synthesis
    Reg#(Bit#(32)) cycle(0);
    Reg#(Bit#(32)) instrs(0);

    rule tick;
        //////////////////////
        // Debugging Helper //
        //////////////////////
        cycle <= cycle + 1;
        // Uncomment the code below to print pipeline state each cycle
        //if (!isValid(exception) || !fromMaybe(?, exception).isInitial) begin
        //    $write("[%d] %m D|E|W PCs: ", cycle);
        //    if (isValid(iCache.data)) $write("%x|", fromMaybe(?, iCache.data).pc); else $write("%8s|", "NOP");
        //    Bool isNopE = (d2e.dInst.iType == OP) && (d2e.dInst.dst == 0);
        //    Bool isNopW = (e2w.dInst.iType == OP) && (e2w.dInst.dst == 0);
        //    if (!isNopE) $write("%x|", d2e.pc); else $write("%8s|", "NOP");
        //    if (!isNopW) $write("%x", e2w.pc); else $write("%8s", "NOP");
        //    if (isValid(exception) || isValid(clearException)) $write("  [", fshow(exception), " | ", fshow(clearException), "]");
        //    //TaskEnqData ted = unpack(pack(taskEnqChunks));
        //    //if (taskEnqAvail) $write("    {", fshow(taskEnqAvail), "  |  ", fshow(ted), "  | ", fshow(taskEnqReady), "}");
        //    $display("  instrs: %d", instrs);
        //end

      /////////////////////
      // Writeback Stage //
      /////////////////////
      
      // Variables for bypassing / stalling
      // NOTE: stallX means that pipeline stage X is stalled. stallX forces all
      // earlier pipe stages to stall. These interlocks are combinational; this
      // is a small pipeline and skid buffers are expensive in an FPGA.
      RIndx dstW = e2w.dInst.dst;
      Word dataW = e2w.data;
      Bool stallW = False;
      
     if (e2w.dInst.isLoad) begin
          if (isValid(dCache.data)) begin
              dataW = fromMaybe(?, dCache.data);
          end else begin
              perf_dcacheStall <= True;
              dataW = ?;
              stallW = True;
          end
      end else if (e2w.dInst.isDiv) begin
          let res = divider.result;
          if (isValid(res)) dataW = fromMaybe(?, res);
          else begin
              dataW = ?;
              stallW = True;
          end
      end else if (e2w.dInst.isMul) begin
          let res = multiplier.result;
          if (isValid(res)) begin
              let m = fromMaybe(?, res);
              dataW = e2w.dInst.funct3[1:0] == 0? m[31:0] : m[63:32];
              multiplier.popResult = True;
          end else begin
              dataW = ?;
              stallW = True;
          end
      end
      
      // Put task arg loads in; this is done here instead of above to not affect bypass paths
      if (isValid(taskArgWrite)) begin
          // if (dstW != 0) begin
          //   $write($time, ": [%m] ABOUT TO ERROR pc = 0x%x", e2w.pc);
          //   $write(" type = ", fshow(e2w.dInst.iType));
          //   if (dstW != 0) $write(" rf[%d] <- 0x%x", dstW, dataW);
          //   if (e2w.dInst.iType == LOAD || e2w.dInst.iType == STORE) $write(" dataAddr = 0x%x", e2w.dataAddr);
          //   if (e2w.dInst.iType == STORE) $write(" storeVal = 0x%x", e2w.storeVal);
          //   $display("");
          // end
          dynamicAssert(dstW == 0, " %m task arg write while core has pending write!!");
          let taskArgWriteV = fromMaybe(?, taskArgWrite);
          rf.wr = Valid(RegWriteArgs{index: taskArgWriteV.argNum, data: taskArgWriteV.argData});
      end else begin
          // Since the regfile gates writes to dst=0, it's OK to write every cycle
          // (even invalid data). This is cheaper than writing selectively, e.g.,
          // when !stallW.
          rf.wr = Valid(RegWriteArgs{index: dstW, data: dataW});
      end

      // NOTE(dsm): Compiler-emitted NOPs are addi x0, x0, 0 (OPIMM), so this
      // should not overcount stall-induced NOPs.
      Bool isNopW = (e2w.dInst.iType == OP) && (e2w.dInst.dst == 0);
      perf_instrsCommit <= !stallW && !isNopW;

      if (!stallW) begin
          Bool isSimNop = (e2w.dInst.iType == OPIMM) && (e2w.dInst.dst == 0);
          if (isSimNop && e2w.dInst.imm[1:0] == 2) begin
              $display($time, ": %m Heartbeat");
              perf_simHeartbeat <= True;
          end
          if (isSimNop && e2w.dInst.imm[1:0] == 3) begin
              $display($time, ": %m simFail PC = 0x%x", e2w.pc);
              perf_simFail <= True;
          end

          // Count every instruction that leaves the writeback stage
          // (for debugging help)
          //if (!isNopW) begin
          //    instrs <= instrs + 1;
          //    // Commit trace
          //    $write($time, " %m: Instruction %d completed, pc = 0x%x", instrs, e2w.pc);
          //    $write(" type = ", fshow(e2w.dInst.iType));
          //    if (dstW != 0) $write(" rf[%d] <- 0x%x", dstW, dataW);
          //    if (e2w.dInst.iType == LOAD || e2w.dInst.iType == STORE) $write(" dataAddr = 0x%x", e2w.dataAddr);
          //    if (e2w.dInst.iType == STORE) $write(" storeVal = 0x%x", e2w.storeVal);
          //    $display("");
          //end

          // If unsupported instruction, stop simulation and print the state of the processor
          // IMPORTANT: Do not modify this code, the microtests rely on it.
          // FIXME(dsm): Update the microtests to use the simpler exception
          // mechanism, and do this in the handler outside the core
          // (just expose rf.fshow, it's fine, it's sim-only)
          //if (e2w.dInst.isUnsupported && fromMaybe(?, exception).addr == 'h4000_4242) begin
          //    $display("Reached unsupported instruction");
          //    $display("Dumping the state of the processor");
          //    $display("pc = 0x%x", e2w.pc);
          //    $display(rf.fshow);
          //    $display("Quitting simulation.");
          //    //$finish;  // can't do this with XRT, see Top.ms
          //end
      end

      ///////////////////
      // Execute Stage //
      ///////////////////
      
      ExecInst eInst = execute(d2e.dInst, d2e.rVal1, d2e.rVal2, d2e.pc);
     
      // Variables for bypassing
      RIndx dstE = d2e.dInst.dst;
      Word dataE = eInst.data;
      Bool stallE = stallW;

      Maybe#(Exception) nextEx = exception;

      // State updates
      Bool setTaskDeqAvail = False;
      if (!stallW) begin
          let dInst = d2e.dInst;
          // Detect all exception conditions (MMIO, Unsupported instr) here, and trigger exception
          if (isValid(exception)) begin
              // Turn following exceptions into nops
              dInst = dNop;
          end
          
          if (dInst.isUnsupported) begin
              // We interpret every unsupported instruction as a task end
              nextEx = Valid(Exception{epc: d2e.pc, isInitial: False});
              // $display($time, ": [%m] SETTING EXCEPTION -- ", fshow(nextEx));
              dCache.flushSMAddr = True;
          end
              
          if (dInst.isMem) begin
              if (dCache.reqEnabled) begin
                  perf_dCacheReadReq  <=  dInst.isLoad;
                  perf_dCacheWriteReq <= !dInst.isLoad;
                  // $display($time, " [%m] DCache = ", fshow(DCacheReq{addr: eInst.addr, op: (dInst.isLoad)? Ld : St, funct3: dInst.funct3, data: d2e.rVal2}), " -- PC: 0x%x", d2e.pc);
                  dCache.req = Valid(DCacheReq{addr: eInst.addr, op: (dInst.isLoad)? Ld : St, funct3: dInst.funct3, data: d2e.rVal2});
              end else
                  stallE = True;
          end

          if (dInst.isLotusEnq) begin
              let edata = cons(d2e.rVal1, cons(d2e.rVal2, nil));
              if (!enqArgPairReady || !dCache.reqEnabled /* waits for pending stores in the cache */) begin
                  stallE = True;
              end else begin
                  enqArgPairInternal <= Valid(edata);
                  // $display($time, " %m: enqArgPair: ", fshow(edata));
              end
          end
          
          // RV32M instructions
          // NOTE: We do not need to check whether these units can take a new
          // input; if they're busy, W stalls, so we never feed them
          // consecutive inputs
          if (dInst.isMul) multiplier.req = Valid(MulReq{a: d2e.rVal1, b: d2e.rVal2, aIsSigned: (dInst.funct3[1] & dInst.funct3[0]) == 0, bIsSigned: dInst.funct3[1] == 0});
          else if (dInst.isDiv) divider.req = Valid(DivReq{dividend: d2e.rVal1, divisor: d2e.rVal2, isSigned: dInst.funct3[0] == 0, retRemainder: dInst.funct3[1] == 1});

          if (!stallE) e2w <= E2W{pc: d2e.pc, dInst: dInst, data: eInst.data, dataAddr: eInst.addr, storeVal: d2e.rVal2};
          else e2w <= nopW;
      end

      //////////////////
      // Decode Stage //
      //////////////////
      if (!stallE && !eInst.mispredict && !isValid(exception) && isValid(iCache.data)) begin
          let d = fromMaybe(?, iCache.data);
          Word pc = d.pc;
          Word inst = d.inst;
          DecodedInst dInst = decode(inst);

          // Read the register values used by the instruction
          Word rVal1 = rf.rd1(dInst.src1);
          Word rVal2 = rf.rd2(dInst.src2);

          Bool bypassFromE = True;
          Bool bypassFromW = True;
          let rs1 = dInst.src1;
          let rs2 = dInst.src2;

          // Stall/bypass checks are inaccurate, but safe, if we don't check
          // hasSrc1/2 (ie, there are false positives but no false negatives).
          // On the test suite, adding these has no effect on CPI. On FPGA
          // synthesis, adding these reduces LUTs (!?), but adds delay.
          let check1 = /*dInst.hasSrc1 &&*/ (rs1 != 0);
          let check2 = /*dInst.hasSrc2 &&*/ (rs2 != 0);
          let match1 = check1 && (rs1 == dstW || rs1 == dstE);
          let match2 = check2 && (rs2 == dstW || rs2 == dstE);

          let resultAvailInE = !d2e.dInst.isLoad && !d2e.dInst.isMul && !d2e.dInst.isDiv;

          if (check1) begin
              if (bypassFromE && rs1 == dstE && resultAvailInE) begin
                  rVal1 = dataE;
                  match1 = False;
                  //$display("RS1 E bypass, PC: ", fshow(pc));
              end else if (bypassFromW && rs1 == dstW && rs1 != dstE) begin
                  rVal1 = dataW;
                  match1 = False;
              end
          end

          if (check2) begin
              if (bypassFromE && rs2 == dstE && resultAvailInE) begin
                  rVal2 = dataE;
                  match2 = False;
                  //$display("RS2 E bypass, PC: ", fshow(pc));
              end else if (bypassFromW && rs2 == dstW && rs2 != dstE) begin
                  rVal2 = dataW;
                  match2 = False;
              end
          end

          Bool stallD = (match1 || match2);

          if (!stallD) begin
              // $write($time, ": [%m] DECODED PC = 0x%x -- INST = 0x%x -- ", pc, inst);
              // $display("d2e <= ", fshow(D2E{pc: pc, dInst: dInst, rVal1: rVal1, rVal2: rVal2}));
              d2e <= D2E{pc: pc, dInst: dInst, rVal1: rVal1, rVal2: rVal2};
              iCache.popRead = True;
          end else d2e <= nopE;
      end else begin
          // NOTE: This is superfluous, but somewhat reduces LUTs over doing
          // nothing or doing other combinations (popRead is irrelevant on
          // redirects or while in an exception)
          if (eInst.mispredict) begin
              iCache.popRead = True;
          end 
          perf_icacheStall <= !stallE && !eInst.mispredict && !isValid(exception);
          if (!stallE) d2e <= nopE;
      end

      /////////////////
      // Fetch Stage //
      /////////////////

      iCache.redirectFetch = isValid(clearException)? Valid(fromMaybe(?, clearException)[31:2]) :
                             eInst.mispredict? Valid(eInst.redirectPC[31:2]) : Invalid;
      iCache.inException = isValid(exception);
      
      if (isValid(clearException)) nextEx = Invalid;
      exception <= nextEx;
    endrule
endmodule
