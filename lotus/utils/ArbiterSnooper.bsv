/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */


import Vector::*;
import Assert::*;
import Connectable::*;
import Arbiter::*;



interface ArbiterRequestSnooper_IFC;
    method Bool requested;
    method Bool granted;
endinterface

interface ArbiterSnooper_IFC#(numeric type count);
    method Vector#(count, Bool) requested;
    method Vector#(count, Bool) granted;
endinterface


module mkArbiterSnooperSingle#(ArbiterRequest_IFC req, ArbiterClient_IFC client)(ArbiterRequestSnooper_IFC);

    mkConnection(client, req);

    method Bool requested = req.request;
    method Bool granted   = client.grant;
endmodule


module mkArbiterSnooper#(Vector#(count, ArbiterRequest_IFC) reqs, Vector#(count, ArbiterClient_IFC) clients)(ArbiterSnooper_IFC#(count));

    Vector#(count, ArbiterRequestSnooper_IFC) snoopers <- zipWithM(mkArbiterSnooperSingle, reqs, clients);

    function Bool arbiterGetRequested(ArbiterRequestSnooper_IFC a);
        return a.requested;
    endfunction
    function Bool arbiterGetGranted(ArbiterRequestSnooper_IFC a);
        return a.granted;
    endfunction

    method Vector#(count, Bool) requested = map(arbiterGetRequested, snoopers);
    method Vector#(count, Bool) granted   = map(arbiterGetGranted  , snoopers);

endmodule



interface ArbiterQualifierSingle_IFC;
    interface ArbiterClient_IFC  client;
    interface ArbiterRequest_IFC request;
endinterface
module getQualifierSingleClient#(ArbiterQualifierSingle_IFC q)(ArbiterClient_IFC);
    return q.client;
endmodule
module getQualifierSingleRequest#(ArbiterQualifierSingle_IFC q)(ArbiterRequest_IFC);
    return q.request;
endmodule

interface ArbiterQualifier_IFC#(numeric type count);
    interface Vector#(count, ArbiterClient_IFC)  clients;
    interface Vector#(count, ArbiterRequest_IFC) requests;
endinterface

module mkArbiterQualifierSingle#(Bool qualifyWith)(ArbiterQualifierSingle_IFC);

    Wire#(Bool) request_ <- mkDWire(False);
    Wire#(Bool) lock_    <- mkDWire(False);
    Wire#(Bool) grant_   <- mkDWire(False);

    rule assertz;
        if (!qualifyWith) begin
            dynamicAssert(!grant_, "If not qualified, should not grant");
        end
    endrule

    interface ArbiterClient_IFC  client;
        method Action request;
            request_ <= qualifyWith;
        endmethod
        method Action lock;
            lock_ <= True;
        endmethod
        method Bool grant = grant_;
    endinterface

    interface ArbiterRequest_IFC request;
        method Bool request = request_;
        method Bool lock    = lock_;

        method Action grant;
            grant_ <= True;
        endmethod
    endinterface
endmodule

module mkArbiterQualifier#(Bool qualifyWith)(ArbiterQualifier_IFC#(count));

    Vector#(count, ArbiterQualifierSingle_IFC) qualifiers <- replicateM(mkArbiterQualifierSingle(qualifyWith));

    Vector#(count, ArbiterClient_IFC)  clients_  <- mapM(getQualifierSingleClient, qualifiers);
    Vector#(count, ArbiterRequest_IFC) requests_ <- mapM(getQualifierSingleRequest, qualifiers);

    interface Vector clients  = clients_;
    interface Vector requests = requests_;

endmodule





