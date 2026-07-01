/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

/* SIP clock domain crossing (CDC) modules
 *
 * These use an async FIFO to implement store-and-forward functionality, so
 * that clocks of arbitrarily different speeds can transmit each message in
 * contiguous cycles. Separate from other SIP components since these are very
 * Xilinx-specific and depend on XPM libraries.
 */

`timescale 1ps/1ps

`include "sip.vh";

module SIPFlitCDC #(
    parameter MAX_BYTES = 16
) (
    input srcClk,
    input dstClk,
    input SIPFlit srcFlit,
    output SIPFlit dstFlit
);

// Destination clock domain signals
reg dequeue_d = 0;
wire data_valid_d, empty_d, eot_d;

// Source clock domain signals
wire full_s;
wire prog_full_s;
reg eot_s = 0;

xpm_fifo_async #(
     // FIXME: Double the needed width because in simulation, I'm seeing that
     // when clock frequencies are off by a large ratio, the effective write
     // depth of the FIFO goes down to MAX_BYTES-1...
     // Example: with master clock period = 20, slave 14 or more gets
     // MAX_BYTES+1, but less than that and it's MAX_BYTES-1.
    .FIFO_WRITE_DEPTH(2*MAX_BYTES),
    .WRITE_DATA_WIDTH(8),
    .READ_DATA_WIDTH(8),
    .READ_MODE("fwft"),
    .FIFO_MEMORY_TYPE("distributed"),
    .USE_ADV_FEATURES("1000"), // only data_valid
    .SIM_ASSERT_CHK(1)
) msgFifo (
    .rst(1'b0), // NOTE: this has its own reset sequence, it can't receive immediately. This should be a non-issue in practice, since thousands of cycles pass between configuration and the host sending messages
    .sleep(1'b0),

    .rd_clk(dstClk),
    .rd_en(dequeue_d),
    .dout(dstFlit.data),
    .data_valid(data_valid_d),
    .empty(empty_d),

    .wr_clk(srcClk),
    .din(srcFlit.data),
    .wr_en(srcFlit.valid),
    .full(full_s)
);

xpm_cdc_single #(
   .DEST_SYNC_FF(6) // dsm: Just in case, choose a higher-than-usual latency to make sure we cover the FIFO latency
) eot_sync (
    .dest_clk(dstClk),
    .dest_out(eot_d),

    .src_clk(srcClk),
    .src_in(eot_s)
);

// At the source, signal each end of transmission by flipping eot_s (we use
// a differential encoding to minimize the number of transitions).
reg prevSrcValid_s = 0;
always_ff @(posedge srcClk) begin
    prevSrcValid_s <= srcFlit.valid;
    if (srcFlit.valid) assert(!full_s);
    if (prevSrcValid_s && !srcFlit.valid) eot_s <= !eot_s;
    //if (srcFlit.valid) $display("[%d] srcFlit=%x", $time, srcFlit.data);
end

// At the destination, dequeue from eot until FIFO goes empty
reg prevEot_d = 0;
always_ff @(posedge dstClk) begin
    //$display("eot_d = %x eot_s = %x", eot_d, eot_s);
    prevEot_d <= eot_d;
    if (prevEot_d != eot_d) dequeue_d <= 1;
    else if (dequeue_d && !data_valid_d) dequeue_d <= 0;

    //if (dstFlit.valid) $display("deq %x", dstFlit.data);
end

assign dstFlit.valid = dequeue_d && data_valid_d;

endmodule

module SIPIfcCDC #(
    parameter MAX_BYTES = 16
) (
    input mClk,
    input sClk,
    SIPIfc.master m,
    SIPIfc.slave s
);

SIPFlitCDC #(.MAX_BYTES(MAX_BYTES)) reqCdc (.srcClk(mClk), .srcFlit(m.req), .dstClk(sClk), .dstFlit(s.req));
SIPFlitCDC #(.MAX_BYTES(MAX_BYTES)) respCdc (.srcClk(sClk), .srcFlit(s.resp), .dstClk(mClk), .dstFlit(m.resp));

endmodule
