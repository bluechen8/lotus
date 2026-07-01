/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import Core;
import MainMemory;

Bit#(3) taskNumArgs =  'h5;

// Connect processor and single main memory
module Top;
    Core core;
    MainMemory mem;
    Reg#(Word) cycles(0);

    Reg#(Bit#(2)) unsupportedTermDelay(1);

    DWire#(Bool)   deqArgsDone(False);
    Reg#(Bit#(3)) deqArgNum(taskNumArgs);

    rule tick;
        // Request side
        mem.req = mem.reqEnabled? core.memReq : Invalid;
        core.memReqReady = mem.reqEnabled;

        // Response side
        core.rdResp = mem.data;
    endrule

    rule taskEnq;
        core.taskEnqReady = True;
        if (isValid(core.taskEnqData)) begin
            let taskEnqData = fromMaybe(?, core.taskEnqData);
            $display("Core Enq received: ", fshow(taskEnqData));
        end
    endrule

    rule taskDeq;
        core.taskDeqAck = True;

        deqArgsDone <= deqArgNum == (taskNumArgs - 1);
        if (deqArgNum != taskNumArgs) begin
            let r = Valid(TaskArgWrite {argNum: deqArgNum, argData: extend(deqArgNum)});
            core.taskArgWrite = r;
            $display("Arg Write = ", fshow(r));
            deqArgNum <= deqArgNum + 1;
        end else if (core.taskDeqReady) begin
            $display("##### TASK DEQ FROM CORE");
            deqArgNum   <= 0;
            core.taskArgWrite = Invalid;
        end else begin
            core.taskArgWrite = Invalid;
        end

    endrule

    rule exception;
        cycles <= cycles + 1;
        Maybe#(Word) clearEx = Invalid;
        if (isValid(core.getException)) begin
            let ex = fromMaybe(?, core.getException);
            case (ex.addr)
                0: begin
                    $display("Clearing initial exception");
                    clearEx = Valid(0);
                end
                'h4000_4242: begin
                    // We need to delay the finish here to keep the microtests working
                    // Can't rely on Processor.ms $finish because having a $finish there affects XRT emulation
                    if (unsupportedTermDelay != 0) begin
			$display("Exception due to unsupported instruction -- terminating in %d cycles", unsupportedTermDelay);
			unsupportedTermDelay <= unsupportedTermDelay - 1;
                    end else begin
			$finish;
                    end
                end
                'h4000_0000: begin
                    // Write character to stdout
                    $write("%c", ex.data[7:0]);
                    clearEx = Valid(ex.epc+4);
                end
                'h4000_0004: begin
                    // Write integer to stdout
                    $write("%0d", ex.data);
                    clearEx = Valid(ex.epc+4);
                end
                'h4000_0100: begin
                    if (deqArgsDone) begin
                        $display("The Core is waiting for a task pointer for a task!!!");
                        clearEx = Valid(ex.epc+4);
                    end
                end
                'h4000_1000: begin
                    // Exit simulation
                    $display("Total Clock Cycles = %d\n", cycles);
                    if (ex.data == 0) begin
                        $display("PASSED");
                    end else begin
                        $display("FAILED %0d", ex.data);
                    end
                    $finish;
                end
            endcase
        end
        core.clearException = clearEx;
    endrule
endmodule
