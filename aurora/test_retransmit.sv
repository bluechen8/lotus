/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

`timescale 1ns/1ps

// Tests retransmit module under errors and drops due to full queues.
// If this works, you should see PASS messages till the end (indicating
// transmission has not stopped) and should not see FAIL at any point.
// This is meant mainly as a manual test, and I wrote/used it to debug the
// implementation. However, it could be automated.
`define AXIS_PORT_CONNECT(port, sig) \
    .``port``_tvalid(``sig``_tvalid), \
    .``port``_tdata(``sig``_tdata), \
    .``port``_tready(``sig``_tready), \

module TestRetransmit (input clk, input rstn);

logic txA_in_tvalid = 0;
logic [63:0] txA_in_tdata;
logic txA_in_tready;

logic txA_out_tvalid;
logic [63:0] txA_out_tdata;
logic txA_out_tready = 0;
logic txA_out_tlast;

logic rxA_out_tvalid;
logic [63:0] rxA_out_tdata;
logic rxA_out_tready = 0;

logic rxA_in_tvalid;
logic [63:0] rxA_in_tdata;
logic rxA_in_tready = 0;
logic rxA_in_tlast;

retransmit#(.NAME("A")) dutA (
    .clk(clk),
    .rstn(rstn),
    `AXIS_PORT_CONNECT(tx_in, txA_in)
    `AXIS_PORT_CONNECT(tx_out, txA_out)
    `AXIS_PORT_CONNECT(rx_in, rxA_in)
    `AXIS_PORT_CONNECT(rx_out, rxA_out)
    .tx_out_tlast(txA_out_tlast),
    .rx_in_tlast(rxA_in_tlast),
    .bad_seq_count_inc(),
    .bad_crc_count_inc(),
    .overflow_count_inc()
);


logic txB_in_tvalid = 0;
logic [63:0] txB_in_tdata;
logic txB_in_tready;

logic txB_out_tvalid;
logic [63:0] txB_out_tdata;
logic txB_out_tready = 0;
logic txB_out_tlast;

logic rxB_out_tvalid;
logic [63:0] rxB_out_tdata;
logic rxB_out_tready = 0;

logic rxB_in_tvalid;
logic [63:0] rxB_in_tdata;
logic rxB_in_tready = 0;
logic rxB_in_tlast;

retransmit#(.NAME("B")) dutB (
    .clk(clk),
    .rstn(rstn),
    `AXIS_PORT_CONNECT(tx_in, txB_in)
    `AXIS_PORT_CONNECT(tx_out, txB_out)
    `AXIS_PORT_CONNECT(rx_in, rxB_in)
    `AXIS_PORT_CONNECT(rx_out, rxB_out)
    .tx_out_tlast(txB_out_tlast),
    .rx_in_tlast(rxB_in_tlast),
    .bad_seq_count_inc(),
    .bad_crc_count_inc(),
    .overflow_count_inc()
);



logic [63:0] rxQ[$];
logic [65:0] channelQ[$];

always @(posedge clk) begin
    if (!rstn) begin
        txA_in_tvalid <= 0;
        txA_out_tready <= 0;
        rxA_in_tvalid <= 0;
        rxA_out_tready <= 0;
        txB_in_tvalid <= 0;
        txB_out_tready <= 0;
        rxB_in_tvalid <= 0;
        rxB_out_tready <= 0;
    end else begin

        if (txA_in_tvalid && txA_in_tready) rxQ.push_back(txA_in_tdata);

        txA_in_tvalid <= 1;
        txA_in_tdata <= {$urandom(), $urandom()};

        txA_out_tready <= 1;
        
        // For now, connect directly; no delay. Note we don't check
        // rx_in_tready, as the point is that the retransmit unit handles
        // backpressure internally.
        rxB_in_tvalid <= txA_out_tvalid;
        rxB_in_tdata <= (($urandom() & 127) != 0)? txA_out_tdata : txA_out_tdata ^ 64'b000000010000;
        rxB_in_tlast <= txA_out_tlast;

        // Throttle rxB so that we drop some data
        rxB_out_tready <= 1'($urandom() & 1);

        if (rxB_out_tvalid && rxB_out_tready) begin
            logic [63:0] expected = rxQ.pop_front();
            if (rxB_out_tdata != expected) begin
                $display("FAIL: wrong rx, %x != %x", rxB_out_tdata, expected);
            end else begin
                $display("%d: PASS, received %x", $time, rxB_out_tdata);
            end
        end

        // Finally, connect the other side; this is used just for control, not
        // data, in this test
        rxA_in_tvalid <= txB_out_tvalid;
        rxA_in_tdata <= (($urandom() & 127) != 0)? txB_out_tdata : txB_out_tdata ^ 64'b000000010000;
        rxA_in_tlast <= txB_out_tlast;

        txB_out_tready <= 1;

    end
end

endmodule
