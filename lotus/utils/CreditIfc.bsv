/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Credit-based analog of CommitIfc. Implements a valid-credit protocol, meant
// to achieve good synthesis results across long-distance paths:
// - dataout and datain have the same semantics as in Send/RecvCommit
// - creditin/out implement a return path of credits, which denote empty space
// - Transmission happens if either credits != 0 or creditin is set this cycle.
//   Send and Recv sides must always make the same determination independently,
//   based on dataout/creditin and datain/creditout + their internal credit
//   counters, to avoid a roundtrip path.
// - maxCredits denotes the maximum number of downstream credits the interface
//   can support. For SendCredit, this must be at least the number of empty
//   buffer slots in all downstream elements. For RecvCredit, it includes the
//   module's own number of slots.
// - Credit counters must start at zero, and are incremented to their right
//   values at initialization: each element must pass upstream as many credits
//   as it can support, on top of the credits it receives downstream. This
//   means that maxCredits can be an overestimate, e.g., we can connect
//   SendCredit#(X, 8) to RecvCredit#(X, 5). This is important to ease
//   configuration: we can build a design with interfaces supporting the
//   maximum number of credits expected, and then use shorter pipes on
//   instances that don't need them.
interface SendCredit#(type a_type, numeric type maxCredits);
    method a_type dataout;
    (*always_ready*)
    method Action creditin;
endinterface

interface RecvCredit#(type a_type, numeric type maxCredits);
    (*always_ready*)
    method Action datain(a_type din);
    (*always_ready*)
    method Bool creditout;
endinterface

import Connectable::*;

instance Connectable#(SendCredit#(t, maxSendCredits), RecvCredit#(t, maxRecvCredits))
    provisos (Add#(maxRecvCredits, __a, maxSendCredits)); // maxSendCredits >= maxRecvCredits
    module mkConnection#(SendCredit#(t, maxSendCredits) send, RecvCredit#(t, maxRecvCredits) recv)(Empty);
        mkConnection(send.dataout, recv.datain);
        //mkConnection(recv.creditout, send.creditin);
        rule passCredit if (recv.creditout); send.creditin; endrule
    endmodule
endinstance

instance Connectable#(RecvCredit#(t, maxRecvCredits), SendCredit#(t, maxSendCredits))
    provisos (Add#(maxRecvCredits, __a, maxSendCredits)); // maxSendCredits >= maxRecvCredits
    module mkConnection#(RecvCredit#(t, maxRecvCredits) recv, SendCredit#(t, maxSendCredits) send)(Empty);
        mkConnection(send.dataout, recv.datain);
        rule passCredit if (recv.creditout); send.creditin; endrule
    endmodule
endinstance

