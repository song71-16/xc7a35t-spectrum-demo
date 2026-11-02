// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/rtl/plot_column_buffer.sv.
`timescale 1ns/1ps
// Pixel-clock domain only. Two banks, three 768-column layers, 8-bit local Y spans.
// A complete RAW then FIR then SPEC frame is published atomically at vertical blank.
module demo_dualtime_columns(
    input wire pixel_clk,rst,
    input wire frame_begin,commit_frame,abort_frame,
    output wire frame_ready,
    input wire [31:0] in_frame_id,
    input wire [15:0] in_epoch,
    input wire [511:0] in_status,
    input wire [287:0] in_config,
    input wire span_valid,span_last,
    input wire [1:0] span_layer,
    input wire [9:0] span_index,
    input wire [7:0] span_min,span_max,
    output wire span_ready,
    input wire vblank_start,freeze,
    output reg front_valid,swapped,
    output reg [31:0] front_frame_id,dropped_frames,rejected_frames,
    output reg [15:0] front_epoch,
    output reg [511:0] front_status,
    output reg [287:0] front_config,
    input wire read_en,
    input wire [9:0] read_index,
    output reg read_valid,
    output wire [7:0] time_min,time_max,filtered_min,filtered_max,spec_min,spec_max,
    output reg [31:0] read_frame_id
);
    (* ram_style="block" *) reg [15:0] time_memory[0:1535];
    (* ram_style="block" *) reg [15:0] spec_memory[0:1535];
    reg [15:0] time_q,filtered_q,spec_q;
    (* ram_style="block" *) reg [15:0] filtered_memory[0:1535];
    reg front_bank,filling,pending,bad_frame;
    reg [11:0] written;
    reg [31:0] pending_id;
    reg [15:0] pending_epoch;
    reg [511:0] pending_status;
    reg [287:0] pending_config;
    wire [1:0] expected_layer=written>=1536 ? 2'd2 : written>=768 ? 2'd1 : 2'd0;
    wire [11:0] expected_index=written-expected_layer*12'd768;
    wire span_ok=written<2304 && span_layer==expected_layer &&
        {2'b0,span_index}==expected_index && span_index<768 &&
        span_min<=span_max && span_max<=191 && span_last==(span_index==767);
    wire do_swap=pending && vblank_start && !freeze && !abort_frame && !rst;
    wire [10:0] write_address=(front_bank ? 11'd0 : 11'd768)+{1'b0,span_index};
    wire [10:0] read_address=(front_bank ? 11'd768 : 11'd0)+{1'b0,read_index};
    wire write_span=span_valid && span_ready && span_ok && !bad_frame && !abort_frame && !commit_frame;
    wire do_read=read_en && read_index<768 && front_valid && !do_swap && !rst;
    assign frame_ready=!rst && !filling && !pending && !abort_frame;
    assign span_ready=!rst && filling && !abort_frame;
    assign {time_max,time_min}=time_q;
    assign {filtered_max,filtered_min}=filtered_q;
    assign {spec_max,spec_min}=spec_q;
    // No RAM reset; valid flags hide all unwritten/stale data.
    always @(posedge pixel_clk) begin
        if(write_span && span_layer==0) time_memory[write_address]<={span_max,span_min};
        if(do_read) time_q<=time_memory[read_address];
    end
    always @(posedge pixel_clk) begin
        if(write_span && span_layer==2) spec_memory[write_address]<={span_max,span_min};
        if(do_read) spec_q<=spec_memory[read_address];
    end
    always @(posedge pixel_clk) begin
        if(write_span && span_layer==1) filtered_memory[write_address]<={span_max,span_min};
        if(do_read) filtered_q<=filtered_memory[read_address];
    end
    always @(posedge pixel_clk) begin
        if(rst) begin
            front_bank<=0;front_valid<=0;swapped<=0;filling<=0;pending<=0;bad_frame<=0;written<=0;
            front_frame_id<=0;front_epoch<=0;front_status<=0;front_config<=0;
            pending_id<=0;pending_epoch<=0;pending_status<=0;pending_config<=0;
            dropped_frames<=0;rejected_frames<=0;read_valid<=0;read_frame_id<=0;
        end else begin
            swapped<=0;read_valid<=do_read;
            if(do_read) read_frame_id<=front_frame_id;
            if(frame_begin && !frame_ready) dropped_frames<=dropped_frames+1'b1;
            if(abort_frame) begin
                if(filling || pending) rejected_frames<=rejected_frames+1'b1;
                filling<=0;pending<=0;bad_frame<=0;
            end else begin
                if(frame_begin && frame_ready) begin
                    filling<=1;bad_frame<=0;written<=0;
                    pending_id<=in_frame_id;pending_epoch<=in_epoch;
                    pending_status<=in_status;pending_config<=in_config;
                end
                if(span_valid && span_ready) begin
                    if(!span_ok) bad_frame<=1;
                    else written<=written+1'b1;
                end
                if(commit_frame && filling) begin
                    filling<=0;
                    if(!bad_frame && written==2304 && !span_valid) pending<=1;
                    else rejected_frames<=rejected_frames+1'b1;
                end
                if(do_swap) begin
                    front_bank<=!front_bank;front_valid<=1;swapped<=1;pending<=0;
                    front_frame_id<=pending_id;front_epoch<=pending_epoch;
                    front_status<=pending_status;front_config<=pending_config;
                end
            end
        end
    end
endmodule
