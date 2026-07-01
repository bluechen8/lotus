/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Simple testbench around Top to enable simulation with xsim (Xilinx)
module xsim_tb;
    reg clk;
    reg rstn;
    mkTop dut(.CLK(clk), .RST_N(rstn));

    initial begin
        rstn = 1'b0;
        clk = 0;
        #50 rstn = 1'b1;
    end

    always #10 clk = ~clk;
endmodule
