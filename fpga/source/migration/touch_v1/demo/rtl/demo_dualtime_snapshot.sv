// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/rtl/display_snapshot_buffer_status.sv.
`timescale 1ns/1ps
// Status-board build variant: explicit FF storage for two-entry descriptors.
// The original display_snapshot_buffer.sv remains the validated fallback source.
module demo_dualtime_snapshot #(
    parameter integer N=512
)(
    input wire wr_clk, pixel_clk, arst,
    input wire offer,
    output wire offer_ready,
    input wire [31:0] in_frame_id,
    input wire [15:0] in_epoch,
    input wire [9:0] in_time_count,
    input wire [511:0] in_status,
    input wire [287:0] in_config,
    input wire word_valid,
    input wire [9:0] word_index,
    input wire [31:0] word_data,
    input wire commit, abort_fill,
    output reg [31:0] dropped_offers, rejected_frames, published_frames,
    input wire vblank_start, freeze,
    output wire front_valid,
    output reg swapped,
    output reg [31:0] front_frame_id,
    output reg [15:0] front_epoch,
    output reg [9:0] front_time_count,
    output reg [511:0] front_status,
    output reg [287:0] front_config,
    input wire read_en,
    input wire [9:0] read_index,
    output wire read_valid,
    output reg [31:0] read_data
);
    localparam integer WORDS=N+N/2+1;
    reg read_valid_q;
    (* ASYNC_REG="TRUE" *) reg [2:0] wr_reset_pipe, rd_reset_pipe;
    always @(posedge wr_clk or posedge arst)
        if(arst) wr_reset_pipe<=3'b111; else wr_reset_pipe<={wr_reset_pipe[1:0],1'b0};
    always @(posedge pixel_clk or posedge arst)
        if(arst) rd_reset_pipe<=3'b111; else rd_reset_pipe<={rd_reset_pipe[1:0],1'b0};
    // Clock-only local reset stages keep RAM control assertion timed.
    reg wr_reset=1'b1, rd_reset=1'b1;
    always @(posedge wr_clk) wr_reset<=wr_reset_pipe[2];
    always @(posedge pixel_clk) rd_reset<=rd_reset_pipe[2];
    reg request_toggle, ack_toggle, ack_seen;
    (* ASYNC_REG="TRUE" *) reg ack_meta, ack_sync;
    (* ASYNC_REG="TRUE" *) reg req_meta, req_sync;
    reg filling, bad_frame, write_bank, front_bank, front_valid_q;
    reg [9:0] written, expected_words;
    (* ram_style="registers" *) reg [31:0] ids[0:1];
    (* ram_style="registers" *) reg [15:0] epochs[0:1];
    (* ram_style="registers" *) reg [9:0] counts[0:1];
    (* ram_style="registers" *) reg [511:0] statuses[0:1];
    (* ram_style="registers" *) reg [287:0] configs[0:1];
    (* ram_style="block" *) reg [31:0] memory[0:2*WORDS-1];
    assign offer_ready=!arst && !wr_reset_pipe[2] && !wr_reset && !filling && request_toggle==ack_sync && ack_seen==ack_sync;
    wire valid_count=in_time_count==N || in_time_count==N/2 || in_time_count==N/4;
    wire word_ok=filling && !bad_frame && word_index==written && written<expected_words;
    wire do_swap=!arst && !rd_reset_pipe[2] && !rd_reset && req_sync!=ack_toggle && vblank_start && !freeze;
    assign front_valid=!arst && !rd_reset_pipe[2] && !rd_reset && front_valid_q;
    assign read_valid=read_valid_q && !arst && !rd_reset && front_valid;

    // Use the locally synchronized reset on the reset pins. A synchronous
    // reset branch here inserts a LUT between the two ASYNC_REG stages.
    always @(posedge wr_clk or posedge wr_reset) begin
        if(wr_reset) begin ack_meta<=0; ack_sync<=0; end
        else begin ack_meta<=ack_toggle; ack_sync<=ack_meta; end
    end
    always @(posedge pixel_clk or posedge rd_reset) begin
        if(rd_reset) begin req_meta<=0; req_sync<=0; end
        else begin req_meta<=request_toggle; req_sync<=req_meta; end
    end
    // Toggle resets remain asynchronous so a stopped remote clock cannot
    // retain an old ownership transfer. RAM addresses/enables are clocked.
    always @(posedge wr_clk or posedge arst) begin
        if(arst) request_toggle<=0;
        else if(wr_reset_pipe[2] || wr_reset) request_toggle<=0;
        else if(filling && commit && !abort_fill &&
                written==expected_words && !bad_frame && !word_valid)
            request_toggle<=!request_toggle;
    end
    always @(posedge wr_clk) begin
        if(arst || wr_reset) begin
            ack_seen<=0; filling<=0; bad_frame<=0; write_bank<=1;
            written<=0; expected_words<=0; dropped_offers<=0; rejected_frames<=0; published_frames<=0;
        end else begin
            if(ack_sync!=ack_seen) begin ack_seen<=ack_sync; write_bank<=!write_bank; end
            if(offer && !offer_ready) dropped_offers<=dropped_offers+1'b1;
            if(offer && offer_ready) begin
                if(valid_count && !word_valid && !commit && !abort_fill) begin
                    filling<=1; bad_frame<=0; written<=0;
                    expected_words<=in_time_count+N/2+1;
                end else rejected_frames<=rejected_frames+1'b1;
            end
            if(filling) begin
                if(word_valid) begin
                    if(word_ok) written<=written+1'b1;
                    else bad_frame<=1;
                end
                if(abort_fill) begin filling<=0; bad_frame<=0; rejected_frames<=rejected_frames+1'b1; end
                else if(commit) begin
                    filling<=0; bad_frame<=0;
                    if(written==expected_words && !bad_frame && !word_valid) begin
                        published_frames<=published_frames+1'b1;
                    end else rejected_frames<=rejected_frames+1'b1;
                end
            end
        end
    end
    // Descriptor contents need no reset: ownership/valid control invalidates
    // them. Keep their synchronous writes out of the async-reset process.
    always @(posedge wr_clk)
        if(!arst && !wr_reset && offer && offer_ready &&
           valid_count && !word_valid && !commit && !abort_fill) begin
            ids[write_bank]<=in_frame_id; epochs[write_bank]<=in_epoch;
            counts[write_bank]<=in_time_count;
            statuses[write_bank]<=in_status; configs[write_bank]<=in_config;
        end
    // Simple dual-port RAM: no reset on storage, writer never owns front bank.
    always @(posedge wr_clk)
        if(!wr_reset && word_valid && word_ok && !abort_fill)
            memory[write_bank*WORDS+word_index]<=word_data;

    always @(posedge pixel_clk or posedge arst) begin
        if(arst) ack_toggle<=0;
        else if(rd_reset_pipe[2] || rd_reset) ack_toggle<=0;
        else if(do_swap) ack_toggle<=req_sync;
    end
    always @(posedge pixel_clk) begin
        if(arst || rd_reset) begin
            front_bank<=0; front_valid_q<=0; swapped<=0;
            front_frame_id<=0; front_epoch<=0; front_time_count<=0; front_status<=0; front_config<=0;
        end else begin
            swapped<=0;
            if(do_swap) begin
                front_bank<=!front_bank; front_valid_q<=1; swapped<=1;
                front_frame_id<=ids[!front_bank]; front_epoch<=epochs[!front_bank];
                front_time_count<=counts[!front_bank]; front_status<=statuses[!front_bank]; front_config<=configs[!front_bank];
            end
        end
    end
    always @(posedge pixel_clk) begin
        read_valid_q<=0;
        // Swapping may read the old bank, but that result is invalid.
        // Async-reset request/ack synchronizers must not drive BRAM enable.
        if(!rd_reset && front_valid_q && read_en && read_index<front_time_count+N/2+1) begin
            read_data<=memory[front_bank*WORDS+read_index]; read_valid_q<=!do_swap;
        end
    end
`ifndef SYNTHESIS
    initial if(N!=256 && N!=512) $fatal(1,"snapshot N must be 256 or 512");
`endif
endmodule
