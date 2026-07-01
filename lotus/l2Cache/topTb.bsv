/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */



package topTb;

    import L2Cache::*;
    import Cntrs::*;
    import Assert::*;
    import FIFO::*;
    import SpecialFIFOs::*;
    import Vector::*;

    interface Ifc_Delay#(numeric type delayVal, type data_t);
        method Action put(data_t req);
        method ActionValue#(data_t) get;
    endinterface: Ifc_Delay

    module mkDelay(Ifc_Delay#(delayVal, data_t))
                                 provisos(Bits#(data_t, dataBits), Add#(xxx, 1, delayVal));

        Vector#(delayVal, FIFO#(Maybe#(data_t))) pipe <- replicateM(mkPipelineFIFO);

        for (Integer i = 1; i < valueOf(delayVal); i = i + 1) begin
            rule push;
                pipe[i].enq(pipe[i-1].first);
                pipe[i-1].deq;
            endrule
        end

        method Action put(data_t req);
            head(pipe).enq(tagged Valid req);
        endmethod

        method ActionValue#(data_t) get if (last(pipe).first matches tagged Valid .req);
            last(pipe).deq;
            return req;
        endmethod


    endmodule

    (* synthesize *)
    module mkTop (Empty);

        l2Cache::Ifc_Cache cache <- mkL2Cache;

        Count#(Bit#(32)) counter <- mkCount(0);
        Count#(Bit#(32)) cycle    <- mkCount(0);

        Reg#(Chunk) numRspns <- mkReg(1);
        //FIFO#(MemRsp)   rspns    <- mkFIFO;

        Ifc_Delay#(10, MemRsp) rspns <- mkDelay;
        FIFO#(MemRsp) rspnsSend <- mkFIFO;

        Reg#(Maybe#(Bit#(32))) currCount <- mkReg(tagged Invalid);

        Count#(ChunkSel) fillRspChunk <- mkCount(0);

        rule fillRsp;
            let r = rspnsSend.first;
            let cid = fillRspChunk;
            if (cid == fromInteger(valueOf(FinalChunkId))) begin
                fillRspChunk <= 0;
                rspnsSend.deq;
            end else begin
                fillRspChunk.incr(1);
            end
            $display($time, " MEM RSP <-<-<-<-<- ", fshow(r), "\tChunkIdx=", fshow(cid));
            cache.mem.rsp(r);
        endrule

        rule pipersp;
            let r <- rspns.get;
            rspnsSend.enq(r);
        endrule

        rule fillReq;
            let req <- cache.mem.req;
            $display($time, " MEM REQ -- ", fshow(req));
            case (req.act) matches
                tagged ReadAct: begin
                    rspns.put(MemRsp {
                       tag: req.meta.tag,
                       data: numRspns
                    });
                    numRspns <= numRspns + 1;
                end
                tagged WriteAct {data: .d, byteEn: .be}: begin
                    $display("TODO: MEM WRITE", fshow(req.act));
                end
            endcase
        endrule

        rule prime if (counter < 9);
            counter.incr(1);
        endrule

        rule readReq0 if (counter == 9);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack('h2000000),
                  tag : 1
                  },
               act: tagged ReadAct
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule
        rule readReq1 if (counter == 10);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack(0),
                  tag : 2
                  },
               act: tagged ReadAct
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule
        rule readReq2 if (counter == 11);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack(0),
                  tag : 0
                  },
               act: tagged WriteAct {
                        data: 'hdeadbeef,
                        byteEn: -1
                  }
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule

        rule readReq3 if (counter == 12);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack(0),
                  tag : 'hdeadbeef
                  },
               act: tagged ReadAct
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule
        rule readReq4 if (counter == 13);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack('h2000000),
                  tag : 1
                  },
               act: tagged ReadAct
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule

        rule readReq5 if (counter == 14);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack('h3300000),
                  tag : 3
                  },
               act: tagged ReadAct
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule

        rule readReq6 if (counter == 15);
            CoreReq r = CoreReq {
               meta: ReqMeta {
                  addr: unpack('h3400000),
                  tag : 4
                  },
               act: tagged ReadAct
               };
            counter.incr(1);
            $display($time, " [", fshow(counter), "] ->->->-> CORE REQ: ", fshow(r));
            cache.core.req(r);
        endrule

        rule readRsp;
            let rsp <- cache.core.rsp;
            let countId = case(currCount) matches
                              tagged Valid .count: return count;
                              tagged Invalid: return 0;
                          endcase;
            currCount <= (countId == unpack(fromInteger(valueOf(FinalChunkId)))) ? tagged Invalid : tagged Valid (countId+1);
            if (!isValid(currCount)) begin
                if (rsp.tag != truncate(rsp.data)) begin
                    $display("CORE readRsp ERROR!!!! ", fshow(rsp));
                    dynamicAssert(False, "readRsp ERROR ");
                end else begin
                    $display($time, " CORE readRsp <-<-<-<-<- ", fshow(rsp));
                end
            end
        endrule

        rule incrementing;
            `ifdef DEBUG_PRINTS
            $display($time, " Counter: ", fshow(counter), "\tcycle: ", fshow(cycle));
            `endif
            cycle.incr(1);
            if (cycle == 256) begin
                $display($time, " LAST Counter: ", fshow(counter), "\tLAST Cycle: ", fshow(cycle));
                $finish (0);
            end
        endrule

    endmodule: mkTop

endpackage: topTb

