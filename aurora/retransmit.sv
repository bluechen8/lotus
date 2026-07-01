/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

`include "crc.vh"

`define M_AXIS_PORT(name, width) \
    input logic                   ``name``_tvalid, \
    input logic  [``width``-1:0]  ``name``_tdata, \
    output logic                  ``name``_tready, \

`define S_AXIS_PORT(name, width) \
    output logic                  ``name``_tvalid, \
    output logic [``width``-1:0]  ``name``_tdata, \
    input logic                   ``name``_tready, \


module retransmit #(
    parameter WIDTH = 64,
    parameter DEPTH = 512,
    parameter NAME = "" // For debugging purposes
) (
    input clk,
    input rstn,
    
    `M_AXIS_PORT(tx_in, WIDTH)
    `S_AXIS_PORT(rx_out, WIDTH)

    `S_AXIS_PORT(tx_out, WIDTH)
    output logic tx_out_tlast,
    `M_AXIS_PORT(rx_in, WIDTH)
    input logic rx_in_tlast,

    // Incremented for every data *word* we drop due to a full receiver queue
    output reg overflow_count_inc,

    // Incremented for every *frame* with a bad CRC (that's not due to overflow)
    output reg bad_crc_count_inc,

    // Incremented for every *frame* with a good CRC but a bad sequence
    // number. This should be rare, as it denotes drops of entire frames
    output reg bad_seq_count_inc
);

/* Transmit window */
(* ram_style = "block" *)
logic [WIDTH-1:0] txWin [DEPTH-1:0];

// Pointers have one extra bit to distinguish full vs empty
localparam PB = $clog2(DEPTH);
logic [PB:0] txwEnqPtr; // next to enq
logic [PB:0] txwDeqPtr; // next to deq
logic [PB:0] txwHeadPtr; // [head, enq) is valid; can go up to enq

wire txwCanEnq = (txwEnqPtr[PB-1:0] != txwHeadPtr[PB-1:0]) || (txwEnqPtr[PB] == txwHeadPtr[PB]);
wire txwCanDeq = txwDeqPtr != txwEnqPtr;

/* Receive window */
(* ram_style = "block" *)
logic [WIDTH-1:0] rxWin [DEPTH-1:0];

logic [PB:0] rxwEnqPtr; // next to enq
logic [PB:0] rxwCommitPtr; // [deq, commit) is committed and can be dequeued; [commit, enq) is speculative. commit can go up to enq
logic [PB:0] rxwDeqPtr; // next to deq

wire rxwCanEnq = (rxwEnqPtr[PB-1:0] != rxwDeqPtr[PB-1:0]) || (rxwEnqPtr[PB] == rxwDeqPtr[PB]);
wire rxwCanDeq = rxwDeqPtr != rxwCommitPtr;


/* Epochs */
localparam EB = 16 - (PB+1);
logic [EB-1:0] rxEpoch; // leads, incremented on every mispeculation (crc failure, seq mismatch, or buffer overflow)
logic [EB-1:0] txEpoch; // follows rxEpoch of receiver pair
logic [EB-1:0] txNextEpoch; // set by rx_in side, tx_out propagates to txEpoch

/* Datapath */

// tx_in
assign tx_in_tready = txwCanEnq;
always @(posedge clk) begin
    if (!rstn) begin
        txwEnqPtr <= 0;
    end else begin
        if (tx_in_tvalid && tx_in_tready) begin
            $display("%d: %s tx_in val=%x ptr=%d", $time, NAME, tx_in_tdata, txwEnqPtr);
            txWin[txwEnqPtr[PB-1:0]] <= tx_in_tdata;
            txwEnqPtr <= txwEnqPtr + 1;
        end
    end
end

// rx_out (pipeline reads)
logic rx_out_tvalid_r;
logic [WIDTH-1:0] rx_out_tdata_r;

assign rx_out_tvalid = rx_out_tvalid_r;
assign rx_out_tdata = rx_out_tdata_r;

wire doRxDeq = rxwCanDeq && ((!rx_out_tvalid_r) || (rx_out_tvalid && rx_out_tready));

always @(posedge clk) begin
    if (!rstn) begin
        rxwDeqPtr <= 0;
        rx_out_tvalid_r <= 0;
    end else begin
        if (doRxDeq) begin
            rx_out_tdata_r <= rxWin[rxwDeqPtr[PB-1:0]];
            rx_out_tvalid_r <= 1;
            rxwDeqPtr <= rxwDeqPtr + 1;
        end else if (rx_out_tvalid && rx_out_tready) begin
            rx_out_tvalid_r <= 0;
        end
    end
end

// It's 32 bits due to how EB and PB are computed
typedef struct packed {
    logic [PB:0] txSeqNum;
    logic [EB-1:0] txEpoch;
    logic [PB:0] rxSeqNum;
    logic [EB-1:0] rxEpoch;
} ControlWord_t;

// rx_in  (data and control words)
assign rx_in_tready = 1; // we're always ready, even if we drop. The expectation is that this signal will not even be used.

// Pipeline stage 1: CRC computation
// This stage, like the rx_in input, is non-blocking. It never stalls, and it keeps
// computing the CRC even if the next stage drops due to a full rxWin. This is
// OK, as it will cause a bad sequence error
logic [31:0] rxCrc_r;
logic rx_in_tvalid_r;
logic [WIDTH-1:0] rx_in_tdata_r;
logic rx_in_tlast_r;

always_ff @(posedge clk) begin
    if (!rstn) begin
        rx_in_tvalid_r <= 0;
        rx_in_tlast_r <= 0;
        rxCrc_r <= 0;
    end else begin
        rx_in_tvalid_r <= rx_in_tvalid;
        rx_in_tdata_r <= rx_in_tdata;
        // NOTE: Slight optimization, rx_in_tlast_r == 1 implies valid; this
        // simplifies the driving of several muxes
        rx_in_tlast_r <= rx_in_tlast && rx_in_tvalid;
        // CRC restarts after end of frame
        if (rx_in_tvalid) rxCrc_r <= crc(rx_in_tlast_r? 0 : rxCrc_r, {rx_in_tlast? 32'b0 : rx_in_tdata[63:32], rx_in_tdata[31:0]});
        else if (rx_in_tlast_r) rxCrc_r <= 0;
    end
end

// Pipeline stage 2: rx steering

// Track whether we couldn't take some word of the frame, used to disambiguate
// errors (for error counters)
logic rxCurFrameOverflowed = 0;

always @(posedge clk) begin
    // Combinagtional counter increment signals, used to drive registered ones
    automatic logic overflowCountInc = 0;
    automatic logic badCrcCountInc = 0;
    automatic logic badSeqCountInc = 0;

    if (!rstn) begin
        rxwEnqPtr <= 0;
        rxwCommitPtr <= 0;
        rxEpoch <= 0;

        txwHeadPtr <= 0;
        txNextEpoch <= 0;

	rxCurFrameOverflowed <= 0;
    end else begin
        if (rx_in_tvalid_r && !rx_in_tlast_r && rxwCanEnq) begin
            $display("%d: %s rx_in data val=%x ptr=%d", $time, NAME, rx_in_tdata_r, rxwEnqPtr);
            rxWin[rxwEnqPtr[PB-1:0]] <= rx_in_tdata_r;
            rxwEnqPtr <= rxwEnqPtr + 1;
        end else if (rx_in_tvalid_r && rx_in_tlast_r) begin
            automatic ControlWord_t cw = rx_in_tdata_r[31:0];
            automatic logic [31:0] recvCrc = rx_in_tdata_r[63:32];
            automatic logic goodEpoch = (cw.txEpoch == rxEpoch);
            automatic logic goodSeq = (cw.txSeqNum == rxwEnqPtr);
            automatic logic goodCrc = (recvCrc == rxCrc_r);

            $display("%d: %s rx_in control {%d, %d, %d, %d} crc=%x ptr=%d", $time, NAME,
                cw.txSeqNum, cw.txEpoch, cw.rxSeqNum, cw.rxEpoch, recvCrc, rxwEnqPtr);
            
            if (goodEpoch && goodSeq && goodCrc) begin
                // All checks pass: same epoch, count, and CRC. Take the frame!
                rxwCommitPtr <= rxwEnqPtr;
                $display("%d: %s rx_in frame OK", $time, NAME);
            end else begin
                // Some check has failed, discard frame
                rxwEnqPtr <= rxwCommitPtr;
                $display("%d: %s rx_in BAD FRAME rxEpoch=%d cw.txEpoch=%d | badSeq=%d badCrc=%d", $time, NAME,
                    rxEpoch, cw.txEpoch, !goodSeq, !goodCrc);

                // Increase rxEpoch to tell transmitter that it should
                // retransmit if either (1) the CRC fails, or (2) the seq
                // fails. Note if the CRC fails, goodSeq can be spurious
                // (because the error can be in cw.txEpoch). 
                //
                // NOTE(dsm): This has a very subtle but key tradeoff: we're
                // increasing rxEpoch EVEN IF THE CRC IS BAD. Note that this
                // makes the goodEpoch check unreliable, and it's possible that
                // this rxEpoch increase is spurious because the error bit is
                // in cw.txEpoch.
                //
                // An alternative would be to wait for a message with a good
                // CRC, but (1) this would delay the notification to the
                // transmitter, and (2) this would require computing the CRC
                // even for inputs we drop, which is currently not done
                // (otherwise, when we start dropping, the transmitter will
                // never retransmit).
                //
                // The reason this is OK is that it's exceedingly unlikely to
                // have a sequence of errors that make rxEpoch wrap around.
                // This would require 64 errors that hit just the right
                // patterns, while the transmitter has not yet synchronized
                // to the new rxEpochs. Note that this is why we can't use an
                // alternating-bit protocol. If the epochs were one bit,
                // two consecutive failures would cause a wrap-around.
                //
                // If errors are very frequent or bursty, to the point of
                // causing a wraparound, this can be avoided by clamping
                // epoch increases, e.g., don't let rxEpoch slip more than N
                // positions ahead from cw.txEpoch.
                if (!goodCrc || goodEpoch) rxEpoch <= rxEpoch + 1;

                // Increment error counters only if we haven't overflowed, as
                // that automatically causes crc and seq to go off
                if (!rxCurFrameOverflowed) begin
                    if (!goodCrc) badCrcCountInc = 1;
                    else if (!goodSeq && goodEpoch) badSeqCountInc = 1;
                end
            end

            rxCurFrameOverflowed <= 0;

            // If the CRC is good, then update our tx state, even if other
            // checks fail.
            if (goodCrc) begin
                txwHeadPtr <= cw.rxSeqNum;
                txNextEpoch <= cw.rxEpoch;
            end
        end else if (rx_in_tvalid_r && !rx_in_tlast_r && !rxwCanEnq) begin
            $display("%d: %s rx_in DROPPING DATA val=%x ptr=%d", $time, NAME, rx_in_tdata_r, rxwEnqPtr);
            overflowCountInc = 1;
            rxCurFrameOverflowed <= 1;
        end
    end

    overflow_count_inc <= overflowCountInc;
    bad_crc_count_inc <= badCrcCountInc;
    bad_seq_count_inc <= badSeqCountInc;
end


// tx_out (data and control words)

// Pipeline stage 1: txWin dequeues
logic tx_out_tvalid_r;
logic tx_out_tlast_r;
// tx_out_tdata uses either of these
logic [WIDTH-1:0] tx_out_data_r;
ControlWord_t tx_out_control_r;

// Pipeline stage 2: CRC computation
logic [WIDTH-1:0] tx_out_tdata_r2;
logic [31:0] txCrc_r2;
wire [31:0] txNextCrc = crc(txCrc_r2, tx_out_tdata_r2);

always @(posedge clk) begin
    if (!rstn) begin
        tx_out_tvalid <= 0;
        txCrc_r2 <= 0;
    end else if (!tx_out_tvalid || tx_out_tready) begin
        // Advance
        tx_out_tvalid <= tx_out_tvalid_r;
        tx_out_tdata_r2 <= tx_out_tlast_r? {32'b0, tx_out_control_r} : tx_out_data_r;
        tx_out_tlast <= tx_out_tlast_r;

        if (tx_out_tvalid)
            txCrc_r2 <= tx_out_tlast? 0 : txNextCrc;
    end
end

assign tx_out_tdata = {tx_out_tlast? txNextCrc : tx_out_tdata_r2[63:32], tx_out_tdata_r2[31:0]};


// We transmit a control word (and close the frame) every 64 data words, or
// whenever the tx queue is empty
logic [5:0] txFrameEndCounter_r;

wire mayDoTxDeq = (!tx_out_tvalid_r) || (!tx_out_tvalid) || tx_out_tready;
wire doTxControlDeq = ((txFrameEndCounter_r == 0) || (txNextEpoch != txEpoch) || (!txwCanDeq)) && mayDoTxDeq;

// This denotes whenever we can do a data dequeue, but doTxControlDeq takes
// priority over this
wire doTxDataDeq = txwCanDeq && mayDoTxDeq;

always @(posedge clk) begin
    if (!rstn) begin
        txwDeqPtr <= 0;
        tx_out_tvalid_r <= 0;
        txEpoch <= 0;
        txFrameEndCounter_r <= 0;
    end else begin
        if (doTxControlDeq) begin
            // txSeqNum and txEpoch are used by the peer *receiver* to check the
            // validity of our transmitted message.
            // rxSeqNum and rxEpoch are used to update the peer *transmitter*
            // about our onw receiver's state.
            automatic ControlWord_t cw;
            cw.txSeqNum = txwDeqPtr;
            cw.txEpoch = txEpoch;
            cw.rxSeqNum = rxwCommitPtr;
            cw.rxEpoch = rxEpoch;
            
            tx_out_control_r <= cw;
            tx_out_tvalid_r <= 1;
            tx_out_tlast_r <= 1;
            $display("%d: %s tx_out control {%d, %d, %d, %d} txNextEpoch=%d", $time, NAME,
                cw.txSeqNum, cw.txEpoch, cw.rxSeqNum, cw.rxEpoch, txNextEpoch);

            if (txNextEpoch != txEpoch) begin
                txEpoch <= txNextEpoch;
                // Reset tx-side pointer for a retransmit
                txwDeqPtr <= txwHeadPtr;
                $display("%d: %s tx_out handling epoch mismatch & retransmit", $time, NAME);
            end

            txFrameEndCounter_r <= ~0;

        end else if (doTxDataDeq) begin
            $display("%d: %s tx_out data val=%x ptr=%d", $time, NAME, txWin[txwDeqPtr[PB-1:0]], txwDeqPtr);
            tx_out_data_r <= txWin[txwDeqPtr[PB-1:0]];
            tx_out_tvalid_r <= 1;
            tx_out_tlast_r <= 0;
            txwDeqPtr <= txwDeqPtr + 1;
            txFrameEndCounter_r <= txFrameEndCounter_r - 1;
        end else if (mayDoTxDeq) begin
            tx_out_tvalid_r <= 0;
        end
    end
end

endmodule
