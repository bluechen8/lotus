/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// 2-element register-based FIFO; differs from Bluespec FIFOs in not having
// full/empty guards
module FIFO2#(type T);
    Reg#(Maybe#(T)) e0(Invalid);
    Reg#(Maybe#(T)) e1(Invalid);
    
    method Maybe#(T) first = e0;
    method Bool isFull = isValid(e0) && isValid(e1);
    input Bool dequeue default = False;
    input Maybe#(T) enqueue default = Invalid;
    
    rule tick; 
        let next0 = dequeue? e1 : e0;
        let next1 = (!dequeue)? e1 : Invalid;
        if (isValid(enqueue)) begin
            if (!isValid(next0)) next0 = enqueue;
            else if (!isValid(next1)) next1 = enqueue;
        end
        e0 <= next0;
        e1 <= next1;
    endrule
endmodule

module FIFO1#(type T);
    Reg#(Maybe#(T)) e0(Invalid);
    
    method Maybe#(T) first = e0;
    method Bool isFull = isValid(e0);
    input Bool dequeue default = False;
    input Maybe#(T) enqueue default = Invalid;
    
    rule tick; 
        if (!isValid(e0) || isValid(enqueue)) begin
            e0 <= enqueue;
        end else if (isValid(e0) && dequeue) begin
            e0 <= Invalid;
        end
    endrule
endmodule
